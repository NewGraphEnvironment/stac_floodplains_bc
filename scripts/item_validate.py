"""item_validate.py — QA gate: pystac-validate the STAC JSON that is about to ship.

Validates the bytes on disk, not in-memory objects, so what is checked is exactly
what gets synced and registered. Nonzero exit on any failure — catalogue_release.sh
runs this before a single byte reaches S3.

Usage:
    uv run python scripts/item_validate.py
    uv run python scripts/item_validate.py --base data/stac --expect 17

Two deliberate differences from the stac_uav_bc original, both closing a
silent-success hole:

  * `glob`, not `rglob`. Item + collection JSON live flat at the root of
    data/stac/ by construction, while the per-item subdirs hold assets. rglob would
    sweep up anything nested there — now or later — and then silently skip it (it is
    not a Feature), so the printed count would carry no completeness signal. This is
    structural, not a fact about today's tree: it used to be argued from 68 terra
    `.tif.aux.json` sidecars, which #34 retired along with terra.

  * `--expect N`. The original has no lower bound, so a wrong --base prints
    `valid: 0` and exits 0 — the gate opens on nothing. With --expect we require
    exactly N items + 1 collection. Default N is derived from the staged
    data/raw/*/meta.json count.
"""

import argparse
import hashlib
import json
import sqlite3
import re
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse

import pystac
import rasterio
from rio_cogeo.cogeo import cog_validate


MULTIHASH_SHA256 = "1220"

# Distinguishes "key absent" from "key present with a null value" — see check_deprecated.
_ABSENT = object()

VERSION_EXT = "https://stac-extensions.github.io/version/v1.2.0/schema.json"
_SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def check_version_stamp(doc: dict) -> "str | None":
    """`version` present iff the Version Extension is declared, and X.Y.Z if present.

    The build writes neither (item_create.py carries no version) and catalogue_release.sh
    stamps both, so this validator legitimately sees both states. Half a stamp is the
    defect, and pystac sees NEITHER half: a `version` with no extension is invisible
    because the schema that would check it is selected BY the extension list, and the
    extension with no `version` validates too, because the v1.2.0 schema lists `version`
    without requiring it (read 2026-09-02). The X.Y.Z shape is ours as well — the schema
    only says string.
    """
    has_ext = VERSION_EXT in (doc.get("stac_extensions") or [])
    version = doc.get("version")
    if has_ext != (version is not None):
        return ("version stamp half-applied: extension "
                f"{'declared' if has_ext else 'absent'}, version {version!r}")
    if version is not None and not _SEMVER.match(str(version)):
        return f"version {version!r} is not X.Y.Z"
    return None


# --- Licence and attribution (#47) -----------------------------------------------------
#
# ABSOLUTE expectations, duplicated from item_create.py rather than imported. Two reasons,
# and only the second is the one the REQUIRED_NGE_PROPERTIES block below gives:
#
#   * importing item_create.py runs the entire build — it raises SystemExit at module level
#     when nothing is staged, and writes 24 files as an import side effect; and
#   * a guard that reads the value it checks is a round-trip through our own assignment. It
#     returns identical, forever. That reason is decisive here in a way it is not for the
#     provenance set: these are literals, not values derived from the data, so "a value that
#     vanished would take the expectation with it" does not apply and the x == x hazard does.
#
# The duplication is only safe because every assertion below is FULL EQUALITY. Token
# containment would let the two copies drift arbitrarily far while still sharing enough
# words to pass — and for a citation, "contains the word Esri" is satisfied by a bag of
# words that attributes nothing to anybody.
#
# pystac's own validation covers exactly ONE of the four ways this can be wrong. Measured
# 2026-09-03 against the real collection, not reasoned from the schema:
#
#   extension declared + sci:citation present  -> passes    (correct)
#   extension declared, sci:citation dropped   -> REJECTED  (pystac gets there first)
#   sci:citation present, extension NOT declared -> passes  <- guarded here
#   neither present                            -> passes    <- guarded here
#   extension + a citation of "x"              -> passes    <- guarded here
#
# The extension's Collection branch is a `oneOf` -> `allOf` -> `anyOf` whose four arms want a
# top-level sci: field, or one in `assets`, `item_assets`, or `summaries` — and the summaries
# arm requires a sci: key INSIDE summaries, which ours (scenario/species/region/flood_factor)
# does not have. So the extension-without-a-field direction really is refused. The other
# three are not: the schema is selected BY the extension list, so it cannot see a field
# published without its extension; and where it does look, `sci:citation` is only `type:
# string`, so it can never tell the right attribution from the wrong one.
#
# An earlier version of this comment claimed all four passed, from a schema dump truncated
# mid-word. The restore-the-bug run is what caught it: that case fired pystac's schema error
# instead of this guard's message. Hence: measure, then write the comment.
SCIENTIFIC_EXT = "https://stac-extensions.github.io/scientific/v1.0.0/schema.json"
EXPECTED_LICENSE = "CC-BY-4.0"
EXPECTED_LICENSE_HREF = "https://creativecommons.org/licenses/by/4.0/"
EXPECTED_SOURCE_COLLECTION = "io-lulc-annual-v02"
# The other half of what the citation claims — "accessed via Microsoft Planetary
# Computer". A host move keeping the collection id would leave the id check green.
EXPECTED_SOURCE_STAC_URL = "https://planetarycomputer.microsoft.com/api/stac/v1"
EXPECTED_DERIVED_FROM_HREF = (
    "https://planetarycomputer.microsoft.com/api/stac/v1/collections/io-lulc-annual-v02")

EXPECTED_PROVIDERS = [
    {"name": "Impact Observatory", "roles": ["producer", "processor", "licensor"],
     "url": "https://www.impactobservatory.com/"},
    {"name": "Esri", "roles": ["licensor"],
     "url": "https://www.esri.com/"},
    {"name": "Microsoft", "roles": ["host"],
     "url": "https://planetarycomputer.microsoft.com"},
    {"name": "Natural Resources Canada", "roles": ["producer", "licensor"],
     "url": "https://natural-resources.canada.ca/"},
    {"name": "Province of British Columbia", "roles": ["producer", "licensor"],
     "url": "https://catalogue.data.gov.bc.ca/"},
    {"name": "New Graph Environment Ltd.", "roles": ["processor", "host"],
     "url": "https://www.newgraphenvironment.com"},
]

EXPECTED_CITATION = (
    "New Graph Environment Ltd. (2026). Floodplain Land-Cover Change in British Columbia "
    "[data set]. Derived from Impact Observatory, 10m Annual Land Use Land Cover (9-class) "
    "V2 (io-lulc-annual-v02), licensed under CC BY 4.0 "
    "(https://creativecommons.org/licenses/by/4.0/), accessed via Microsoft Planetary "
    "Computer; modified by clipping to modelled floodplain extents and cross-tabulating "
    "2017 against 2023 into land-cover transitions. Floodplain delineation contains "
    "information licensed under the Open Government Licence – Canada (MRDEM-30, Natural "
    "Resources Canada) and the Open Government Licence – British Columbia (Freshwater "
    "Atlas stream network, Province of British Columbia). Stream network built with the "
    "link package, reproducing the bcfishpass modelling approach."
)

# Asserted as a whole substring of the description, never as a marker word: a marker like
# "modif" is satisfied by a description that says UNmodified. This is a licence obligation
# (CC BY 4.0 §3(a)(1)(B)), not prose, which is why it is pinned as tightly as the citation.
EXPECTED_DERIVATION_STATEMENT = (
    "Land cover is derived from Impact Observatory's 10 m annual land use / land cover "
    "(io-lulc-annual-v02, CC BY 4.0, via Microsoft Planetary Computer) and is "
    "modified: clipped to the modelled floodplain extent and cross-tabulated between 2017 "
    "and 2023 into land-cover transitions. Every year is read from that one collection, "
    "recorded per item as nge:landcover_collection and fingerprinted as nge:landcover_key, "
    "so the series cannot silently mix releases and manufacture change."
)


def _provider_key(p: dict) -> tuple:
    """A provider compared WHOLE, with `roles` order-normalised.

    Deliberately not a (name, roles) projection. A projection is blind to a `url` that is
    missing or points at the wrong organisation — and CC BY 4.0 §3(a)(1)(A) obliges the URI
    when one is supplied — and it is blind to any field added later. Comparing the whole
    record means a surprise shows up as a difference rather than as silence.
    """
    return tuple(sorted(
        (k, frozenset(v) if k == "roles" else v) for k, v in p.items()))


def check_collection_metadata(doc: dict) -> list[str]:
    """The licence, attribution and citation the source licences oblige (#47).

    Returns EVERY problem, not the first. `check_version_stamp` returns `str | None`
    because it guards one field; this guards five, and a caller that reported one of them
    per run would cost a release round-trip per defect.

    Pure on the document — the premise that ties these literals to the data they describe
    lives in check_citation_premise(), which needs the items.
    """
    problems: list[str] = []

    license_ = doc.get("license")
    if license_ != EXPECTED_LICENSE:
        problems.append(
            f"collection license is {license_!r}, expected {EXPECTED_LICENSE!r}"
            + (" — 'proprietary' claims a restriction we do not hold, and the source"
               " licence obliges credit we would not be giving"
               if license_ == "proprietary" else ""))

    # `or []`, not `if "providers" in doc`: pystac omits the key ENTIRELY for an empty
    # list (collection.py `if self.providers:`), so a presence gate would skip the whole
    # comparison on exactly the input that has lost every provider.
    providers = doc.get("providers") or []
    if len(providers) != len(EXPECTED_PROVIDERS):
        problems.append(
            f"collection carries {len(providers)} provider(s), expected "
            f"{len(EXPECTED_PROVIDERS)}")
    # The count above is not redundant with the set compare below: a set cannot see a
    # duplicate, so six correct providers plus a repeat of one of them compares equal.
    got = {_provider_key(p) for p in providers}
    want = {_provider_key(p) for p in EXPECTED_PROVIDERS}
    if got != want:
        missing = sorted(dict(k).get("name", "?") for k in want - got)
        extra = sorted(dict(k).get("name", "?") for k in got - want)
        if missing:
            problems.append(f"providers missing or altered: {', '.join(missing)}")
        if extra:
            problems.append(f"providers not expected: {', '.join(extra)}")

    links = doc.get("links") or []
    for rel, href in (("license", EXPECTED_LICENSE_HREF),
                      ("derived_from", EXPECTED_DERIVED_FROM_HREF)):
        matching = [link for link in links if link.get("rel") == rel]
        if len(matching) != 1:
            problems.append(
                f"expected exactly 1 rel={rel!r} link, found {len(matching)}")
        elif matching[0].get("href") != href:
            problems.append(
                f"rel={rel!r} link points at {matching[0].get('href')!r}, expected {href!r}")

    # The biconditional check_version_stamp uses, but for only ONE of its two halves. The
    # extension declared with no field is refused by the schema before this runs (measured;
    # see the table above), so this arm is belt-and-braces there. The other half is the
    # load-bearing one: a sci: field published WITHOUT its extension is invisible to pystac,
    # because the schema that would check it is selected by the extension list.
    has_ext = SCIENTIFIC_EXT in (doc.get("stac_extensions") or [])
    citation = doc.get("sci:citation")
    if has_ext != (citation is not None):
        problems.append(
            "scientific extension half-applied: extension "
            f"{'declared' if has_ext else 'absent'}, sci:citation "
            f"{'present' if citation is not None else 'absent'}")
    elif citation is None:
        # Named separately from the verbatim mismatch below. Both states are detected either
        # way, but "does not match verbatim" points at a citation that is not there, and
        # acting on it lands you on the half-applied arm next run.
        problems.append(
            "the collection publishes no attribution at all — neither the scientific "
            "extension nor sci:citation. CC BY 4.0 obliges credit; add both")
    elif citation != EXPECTED_CITATION:
        problems.append("sci:citation does not match the expected attribution verbatim")

    if EXPECTED_DERIVATION_STATEMENT not in (doc.get("description") or ""):
        problems.append(
            "collection description is missing the derivation/modification statement "
            "CC BY 4.0 §3(a)(1)(B) obliges")

    return problems


# The items published as over-mapped (#26). Duplicated from item_create.py's DEPRECATED_ITEMS
# rather than imported, for the reasons given above REQUIRED_NGE_PROPERTIES: importing that
# module runs the whole build, and a guard that reads the value it checks is x == x.
EXPECTED_DEPRECATED = {"mcgr_ch_ff04", "pine_bt_ff04"}

# The `flooded` release that fixed the bankfull units defect. The guards below turn on whether
# an item was built at or above it — not on whether it carries a version at all, which is a
# PROXY: an item rebuilt on 0.4.0 carries a version, is still over-mapped, and would pass a
# presence check unmarked. Not live today (all 21 carry 0.5.0), which is exactly when a proxy
# is cheapest to replace with the property.
MIN_FLOODED_VERSION = (0, 5, 0)


def _corrected(fv: object) -> bool:
    """Was this item built on a `flooded` at or above the units fix?

    Anything unparseable is False — a version we cannot read is one we cannot vouch for, and
    the two states this feeds both fail toward refusing to publish rather than toward silence.
    """
    if not isinstance(fv, str) or not _SEMVER.match(fv):
        return False
    return tuple(int(part) for part in fv.split(".")) >= MIN_FLOODED_VERSION


def check_deprecated(base: Path, partial: bool = False) -> list[str]:
    """Exactly the items that could not be re-run are marked, and the marker self-clears (#26).

    `partial` drops exactly one arm: ids named in the literal but ABSENT from the tree, which
    is the normal state of a subset rather than a defect. Under `--only` the tree may hold a
    single group, and asserting the whole catalogue against it refuses every group but the
    marked two, killing the #36 single-group path. Same reasoning and the same shape as
    `--expect-provenance`, which the release also skips there.

    Everything else runs on any tree, because every other arm names an id the tree CONTAINS.

    pystac cannot help here at all. The Version Extension's Item branch is
    `properties: {"$ref": "#/definitions/fields"}` with NO `required`, and every field in
    `fields` is optional — so an item declaring the extension and carrying no `deprecated`
    validates clean, and one carrying `deprecated` without declaring the extension validates
    too, because the schema is selected BY the extension list. Both directions are ours.

    SET EQUALITY, not containment, and the literal's own ids checked against the build: a
    marker that spread, a marker that was dropped, and an id left behind by a rename are three
    different defects and only the first is visible to a containment check.

    The self-clearing arm is the one that matters over time. This is written data that
    outlives the fix (`code-check.md`, "Written data outlives the fix"): when floodplains#76
    unblocks and MCGR is rebuilt, nothing would remove it from the literal, and it would
    publish as deprecated forever while carrying corrected geometry — a lie in the opposite
    direction from the one #26 opened. So an item marked deprecated may not carry a non-null
    `nge:flooded_version`, and the first corrected build fails the release until the id is
    deleted from the literal.

    What that arm encodes is "deprecated HERE means not-rebuilt". True by construction today —
    both marked items have no upstream provenance.json at all — and it would misfire on an item
    deprecated for some other reason while carrying provenance. That is a deliberate coupling,
    not an oversight: the alternative is a marker with no expiry, and this repo has already
    published one forward-only field it could not take back.
    """
    problems: list[str] = []
    marked: set[str] = set()
    seen: set[str] = set()

    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc.get("id", path.stem)
        seen.add(item_id)
        # `or {}`, not a default: `"properties": null` returns None from .get with a default
        # and would raise AttributeError on the next line instead of being reported.
        props = doc.get("properties") or {}
        # A sentinel, because absent and an explicit JSON null are different states and this
        # guard's whole subject is that a published null is invisible from the API (#31/#36).
        flag = props.get("deprecated", _ABSENT)
        has_ext = VERSION_EXT in (doc.get("stac_extensions") or [])

        if flag is not _ABSENT and flag is not True:
            # `deprecated: false` is the extension's default and says nothing; publishing it
            # explicitly on some items and not others would make absence ambiguous. `null` is
            # worse still — the API would drop it, so it reads as absent to every consumer.
            problems.append(f"{item_id}: deprecated is {flag!r} — publish true or omit it")
        if has_ext != (flag is not _ABSENT):
            problems.append(
                f"{item_id}: version extension half-applied — extension "
                f"{'declared' if has_ext else 'absent'}, deprecated "
                f"{'present' if flag is not _ABSENT else 'absent'}")

        # BOTH directions. The self-clear alone is `marked -> not rebuilt`; the converse,
        # `not rebuilt -> marked`, is the one #26 exists to enforce, and nothing else covers
        # it: an unmarked item with no provenance adds zero to the provenance floor's count,
        # so an exact floor of 21 is satisfied by 21 provenanced items whatever ships beside
        # them. Without this, a 24th over-mapped item ships looking current and every guard
        # stays green.
        fv = props.get("nge:flooded_version")
        if flag is True:
            marked.add(item_id)
            if _corrected(fv):
                problems.append(
                    f"{item_id}: marked deprecated but carries nge:flooded_version {fv!r}. "
                    f"If it has been rebuilt, delete it from DEPRECATED_ITEMS in "
                    f"item_create.py and EXPECTED_DEPRECATED here. If it is deprecated for "
                    f"some other reason, this guard is the wrong one — it encodes "
                    f"'deprecated here means not-rebuilt' and needs widening, not silencing")
        elif not _corrected(fv):
            _v = "no nge:flooded_version" if fv is None else f"nge:flooded_version {fv!r}"
            problems.append(
                f"{item_id}: carries {_v}, so nothing here can vouch that it was built on "
                f"flooded >= {'.'.join(map(str, MIN_FLOODED_VERSION))}, and it publishes "
                f"unmarked. Rebuild it, or mark it. Do NOT mark it merely to clear this: if it "
                f"WAS built on a corrected flooded and only the upstream provenance.json is "
                f"missing or unreadable, the geometry is right and marking it publishes a false "
                f"claim — fix the provenance instead")

    # The line is not "set compare vs the rest" — it is whether an arm names an id the tree
    # CONTAINS. Both of these do (`marked` and `& seen` are subsets of `seen`), so both hold on
    # any tree and run even under --partial:
    #
    #   * a marker outside the literal would otherwise sail through an --only release and
    #     upsert a permanent false "stale" claim into pgstac — the direction with no rollback;
    #   * an item IN the literal, present, and unmarked is the state produced by editing
    #     item_create.py's literal and not this one. That is the documented future flow for
    #     #26 (mcgr is rebuilt, someone deletes it from one copy), and --only is exactly the
    #     path an operator would reach for. Step 5's read-back is inside `if [ -z "$ONLY" ]`,
    #     so nothing downstream would catch it either.
    for i in sorted(marked - EXPECTED_DEPRECATED):
        problems.append(f"{i}: marked deprecated but not in the expected set")
    for i in sorted((EXPECTED_DEPRECATED & seen) - marked):
        problems.append(f"{i}: expected deprecated: true, not marked")

    # Only this one genuinely needs the whole catalogue: it asks about ids ABSENT from the
    # tree, which is the normal state of a subset rather than a defect.
    if partial:
        return problems
    # A literal naming an item nothing publishes makes the compare above vacuous on that name.
    for i in sorted(EXPECTED_DEPRECATED - seen):
        problems.append(f"{i}: named in EXPECTED_DEPRECATED but absent from the build")
    return problems


def check_citation_premise(base: Path) -> list[str]:
    """Do the items still come from the collection the citation names? (#47)

    The licence, the providers and the citation are literals a human wrote. Nothing else
    here would notice if `drift` moved upstream to io-lulc-annual-v03 — the build would keep
    publishing an attribution that had quietly become false, with every other guard green.
    This is the premise those literals rest on, asserted beside them.

    BOTH halves of what the citation claims, because it makes two claims and they can move
    independently: the collection id (`io-lulc-annual-v02`) and where it was read from
    ("accessed via Microsoft Planetary Computer"). A move to the same collection id on a
    different host — an Esri-hosted variant on different terms — leaves the id untouched, so
    checking the id alone would let it through while the citation named the wrong licensor.

    A NULL value stays legal on either: the provenance floor (#32) is what governs how many
    items must carry one, and refusing here would be a guard failing toward abort on a build
    the floor deliberately permits.
    """
    problems: list[str] = []
    claims = (("nge:landcover_collection", EXPECTED_SOURCE_COLLECTION),
              ("nge:landcover_stac_url", EXPECTED_SOURCE_STAC_URL))
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        for prop, want in claims:
            got = doc.get("properties", {}).get(prop)
            if got is not None and got != want:
                problems.append(
                    f"{path.name}: {prop} is {got!r}, but the published citation "
                    f"attributes {want!r}")
    return problems

# Run provenance (#17). Declared here as an ABSOLUTE set, deliberately duplicating
# item_create.py's PROV_FIELDS rather than importing it — importing that module
# would run the entire build, since it is a script and not a library.
# The item properties that 02_raster_tag.py mirrors as UPPERCASE GDAL tags. Absolute and
# hardcoded, for the same reason as REQUIRED_NGE_PROPERTIES: derived from the data, a tag
# that vanished from every COG would take the expectation with it.
#
# Only the NGE_ half was guarded before #33. The other nine had no guard anywhere — and
# that reorder put terra between the tag write and the published bytes, so "the tags
# survive writeRaster" became a claim nothing checked. If terra ever drops them, every
# other gate still passes: checksums verify, cog_validate passes, and the COGs quietly
# lose their identity.
#
# flood_factor is deliberately absent: it is derived in item_create.py and has never been tagged.
SHARED_TAG_PROPERTIES = {
    "wsg", "species", "scenario", "region",
    "floodplain_ff02_km2", "floodplain_ff04_km2", "floodplain_ff06_km2",
    "gross_loss_ha", "gross_gain_ha", "net_ha",
}

REQUIRED_NGE_PROPERTIES = {
    "nge:link_run_uid", "nge:link_config_sha256", "nge:link_sha", "nge:link_version",
    "nge:flooded_version", "nge:drift_version", "nge:produced_datetime",
    "nge:landcover_source", "nge:landcover_collection", "nge:landcover_stac_url",
    "nge:landcover_key", "nge:landcover_item_hash",
}


# The three upstream steps that write provenance, by the fields each one owns. Printed per
# section so a partial reader — network found, landcover lost — is visible on screen even
# though the item-level floor counts it as carrying provenance.
PROV_SECTIONS = {
    "network": {"nge:link_run_uid", "nge:link_config_sha256", "nge:link_sha", "nge:link_version"},
    "floodplain": {"nge:flooded_version"},
}
PROV_SECTIONS["landcover"] = REQUIRED_NGE_PROPERTIES - PROV_SECTIONS["network"] - PROV_SECTIONS["floodplain"]


def check_provenance(base: Path, floor: int | None = None
                     ) -> tuple[list[str], int, int, dict[str, int]]:
    """Verify every item carries every `nge:` provenance KEY, and — when `floor` is given —
    that EXACTLY `floor` items carry a VALUE. Returns (problems, items carrying a value,
    items seen, items carrying a value per upstream section).

    Absolute, not comparative. The asset check below compares items against each other,
    which is structurally blind to a defect that hits all of them uniformly — the exact
    hole #23 fell into. If the staging reader silently found nothing and every item lost
    the same properties, a cross-item check sees no variance and passes, and pystac's
    schema validation cannot see custom properties at all. So the required set is named
    here rather than derived from the data.

    Set EQUALITY, not containment: a property added to item_create.py without being
    declared here fails too, which is what keeps the two lists in step now that they
    cannot import from one another.

    A null VALUE is expected and allowed — floodplains#33 is forward-only, so an area
    modelled before it lands has no provenance to carry, and publishing the null is the
    point of the issue. Only an absent KEY is a failure.

    The floor (#32) is the one guard on VALUES, and it is set by the operator, never
    derived: deriving it from the build reproduces #23 — the expectation comes from the
    data, so the data cannot contradict it. Once areas are re-modelled under provenance,
    "every item null" stops being the expected state and becomes the one failure this
    feature exists to make visible — a reader that silently found nothing produces exactly
    the all-null catalogue that every presence check waves through. "Carries a value" is
    the same predicate 01_stage.R (`has_prov`) and item_create.py (`_no_prov`) print, so the
    number on screen after a build is the number to set.

    EXACT, not a minimum. A minimum makes "raise it" a convention nobody enforces: coverage
    climbs from 1 to 20 across releases and the literal stays at 0, printing a number in a
    scrollback nobody reads. Exact means every release records the count as a fact beside
    its NEWS entry, and a build that disagrees with the record fails in either direction —
    below is a reader that found nothing, above is a floor nobody updated. None means no
    check: a rebuild is not a release.
    """
    problems: list[str] = []
    seen = 0
    traced = 0
    per_section = {s: 0 for s in PROV_SECTIONS}
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        seen += 1
        props = doc.get("properties", {})
        found = {k for k in props if k.startswith("nge:")}
        if found != REQUIRED_NGE_PROPERTIES:
            problems.append(
                f"{doc['id']}: nge: property set differs from the declared contract — "
                f"missing {sorted(REQUIRED_NGE_PROPERTIES - found) or 'none'}, "
                f"undeclared {sorted(found - REQUIRED_NGE_PROPERTIES) or 'none'}")
        if any(props.get(k) is not None for k in REQUIRED_NGE_PROPERTIES):
            traced += 1
        for sect, keys in PROV_SECTIONS.items():
            if any(props.get(k) is not None for k in keys):
                per_section[sect] += 1
    # Zero items is not a pass. The loop above would report nothing at all for an empty
    # or wrongly-pointed directory, which reads identically to "every item checked out".
    if seen == 0:
        problems.append(
            f"no items found under {base}/*.json — the provenance contract was not "
            f"actually checked against anything")
    if floor is not None and traced < floor:
        problems.append(
            f"{traced} of {seen} item(s) carry a non-null nge: value but the release floor is "
            f"{floor}. A reader that silently found nothing looks exactly like the expected "
            f"forward-only state; the floor is what tells them apart. If fewer areas genuinely "
            f"carry provenance now, lower PROVENANCE_FLOOR in catalogue_release.sh deliberately.")
    elif floor is not None and traced > floor:
        problems.append(
            f"{traced} of {seen} item(s) carry a non-null nge: value but the release floor is "
            f"{floor} — the floor is behind the build. Set PROVENANCE_FLOOR to {traced} in "
            f"catalogue_release.sh, in the same commit as this release's NEWS entry, so the "
            f"count is recorded rather than printed.")
    return problems, traced, seen, per_section


def check_cog_tags(base: Path) -> list[str]:
    """Verify each COG's NGE_ tags agree with its item's non-null `nge:` properties.

    02_raster_tag.py keeps its own copy of the field list, and nothing else in the repo reads
    a COG — so before this check, adding a twelfth field and forgetting that copy would
    ship silently incomplete COGs. Every other copy of the list is tied to another
    (fp_provenance.R stopifnot, item_create/item_validate set equality); this was the one with no
    guard in the add direction.

    Compares against the ITEM, not against a second hardcoded list, so the assertion
    cannot drift from what was published.
    """
    problems: list[str] = []
    compared = 0
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc["id"]
        props = doc.get("properties", {})
        # A null property is deliberately NOT tagged: GDAL metadata is string-only and has
        # no null, so 03 encodes absence as the empty string, which GDAL drops on read.
        want = {f"NGE_{k[len('nge:'):].upper()}": str(v)
                for k, v in props.items() if k.startswith("nge:") and v is not None}
        # NGE_PROVENANCE_NULL is included, not excluded. Until floodplains#33 lands it is
        # the ONLY NGE_ tag on a COG — every value tag is absent — so excluding it made
        # this check compare {} against {} for every item in exactly the state the repo
        # expects to be in. Measured: the tag could be overwritten with garbage and the
        # check still passed. It is derivable from the item for free.
        nulls = sorted(k[len("nge:"):] for k, v in props.items()
                       if k.startswith("nge:") and v is None)
        if nulls:
            want["NGE_PROVENANCE_NULL"] = ",".join(nulls)
        # The shared identity/metric tags, absent from the item is itself a failure.
        for prop in sorted(SHARED_TAG_PROPERTIES):
            if prop not in props:
                problems.append(f"{item_id}: item property {prop!r} is missing, so its "
                                f"GDAL tag cannot be verified")
                continue
            want[prop.upper()] = str(props[prop])
        for asset in doc.get("assets", {}).values():
            # Compare against pystac's own constant, the same one item_create.py
            # writes from. A duplicated media-type literal drifting by a single character
            # would silently match no assets and pass.
            if asset.get("type") != pystac.MediaType.COG:
                continue
            local = base / item_id / PurePosixPath(urlparse(asset["href"]).path).parts[-1]
            if not local.is_file():
                continue  # missing assets are already reported by check_checksums
            compared += 1
            with rasterio.open(local) as ds:
                tags = ds.tags()
            managed = {k for k in want} | {k for k in tags
                                            if k.startswith("NGE_")}
            got = {k: v for k, v in tags.items() if k in managed}

            def _same(a, b):
                # The tag is str(x) from Python and the property is a JSON number, so
                # '-738.20' and '-738.2' must compare equal while a real drift must not.
                if a == b:
                    return True
                try:
                    return a is not None and b is not None and float(a) == float(b)
                except (TypeError, ValueError):
                    return False

            # Compute the differences FIRST and gate on them. Gating on `got != want` and
            # diffing with _same() puts a numeric-formatting difference inside the block
            # with nothing to report — a failure with an empty message. Caught by feeding
            # the guard '-738.20' against a property of -738.2.
            changed = [f"{k}: tag {got.get(k)!r} vs property {want.get(k)!r}"
                       for k in sorted(set(got) | set(want))
                       if not _same(got.get(k), want.get(k))]
            if changed:
                problems.append(
                    f"{item_id}/{local.name}: GDAL tags disagree with the item's "
                    f"properties — {'; '.join(changed)}")
    # Zero comparisons is not a pass. Same reasoning as check_provenance's seen == 0: a
    # loop over nothing prints nothing and returns clean, which is indistinguishable from
    # every COG having checked out.
    if compared == 0:
        problems.append(
            f"no COG assets compared under {base} — the NGE_ tag contract was not "
            f"actually checked against anything")
    return problems


# TIFF tag 42112 is GDAL's own metadata tag, and since GDAL 3.12 it carries the Raster
# Attribute Table. This is where the class labels have to live for them to reach a consumer
# that only ever fetches the `.tif` — which is every consumer this collection has, because
# geoserv's titiler restricts fetches to `.tif` and would never see a `.aux.xml`.
GDAL_METADATA_TAG = 42112

# Absolute expected row counts, per asset kind. Named here rather than derived from
# classes.json or from the item, because a derived expectation cannot fire: if the class
# table went empty, the RAT, the STAC classes and the expectation would all go empty
# together and every comparison would pass. 9 land-cover classes; 9x9 transitions.
EXPECTED_RAT_ROWS = {"classified": 9, "transition": 81}

# The layer styles embedded by 04_gpkg_style.py (#46). Absolute, like the RAT rows above:
# an expectation derived from the file could not fire, because a GeoPackage that lost its
# style table would also report zero layers to compare against.
STYLED_GPKGS = ("floodplain.gpkg", "floodplain_landcover.gpkg", "transition_vector.gpkg")
STYLE_DIR = Path("styles")

# The style assets every item must publish. Absolute for the same reason as the RAT
# rows: `check_checksums` compares each item's asset keys against the LARGEST set it
# saw, so three keys lost from every item is uniform and invisible there (#23).
EXPECTED_STYLE_ASSETS = {
    "style_floodplain": "floodplain.qml",
    "style_classified": "classified.qml",
    "style_transition": "transition.qml",
}
EXPECTED_STYLE_CATEGORIES = {"classified": 9, "transition": 73}

# The classified year sets this collection publishes (#61). A LITERAL a human sets, the
# same shape and the same reason as DEPRECATED_ITEMS and PROVENANCE_FLOOR: the year set is
# now a property of the item — some areas are three-year, some annual since floodplains#79 —
# so the cross-item key check sees two populations and cannot be left to guess, and an
# expectation derived from the items cannot fire when the loss is uniform across all of
# them (#23).
#
# Delete the three-year tuple once every published area is annual, and the guard tightens
# back to one population on its own. An entry no item uses is a literal nobody updated, so
# that direction is checked too.
ALLOWED_YEAR_SETS = (
    (2017, 2020, 2023),                            # the span every area was built at until #79
    (2017, 2018, 2019, 2020, 2021, 2022, 2023),    # annual, floodplains#79
)

# The asset-key PARTITION, written down beside the guard because it is what the next person
# will get wrong (#26 cost three review rounds on exactly this):
#
#   fixed keys    identical across every item — `transition_<y1>_<y2>`, the three
#                 GeoPackages, the three `style_*`. A dropped one shows up as a difference
#                 from the other items, which is what the cross-item compare is for.
#   classified_*  PER ITEM, against ALLOWED_YEAR_SETS above. Comparing these across items
#                 is exactly the thing that broke once two populations existed.
#
# And which arms survive `--partial` (a one-item tree, `catalogue_release.sh --only`):
# an arm naming keys the subset CONTAINS stays on; an arm asking about members the subset
# does not have — "every allowed set is used by some item" — must be dropped, because the
# normal state of a subset is not to use them all.
CLASSIFIED_KEY_RE = re.compile(r"^classified_(\d{4})$")

# The producer writes the vector's `transition` column with an ASCII arrow and the RAT's
# titles with U+2192. Measured, and deliberate on both sides — so the comparison below has
# to translate rather than assume they match.
VECTOR_ARROW = " -> "
RASTER_ARROW = " \u2192 "


def _read_embedded_rat(path: Path) -> ET.Element | None:
    """Parse the RAT out of TIFF tag 42112, reading the FILE rather than asking GDAL.

    Asking GDAL is the one thing that cannot answer this question. GDAL loads a `.aux.xml`
    sidecar transparently, so `rasterio.open(...)` reports a RAT whether it is inside the
    file or beside it — and "beside it" is precisely the failure this guard exists to
    catch, because that file is excluded from the S3 sync. rasterio exposes no RAT API at
    all, so there is no higher-level route.

    Raises on anything it does not understand rather than returning None. Returning None
    for an unparseable header would let a BigTIFF, a big-endian file, or a future layout
    read as "no RAT", which is at best a false alarm and at worst — paired with a caller
    that treats absence as an empty set — a silent pass.
    """
    with path.open("rb") as fh:
        header = fh.read(8)
        if header[:2] != b"II":
            raise ValueError(f"not a little-endian TIFF (magic {header[:2]!r})")
        if header[2:4] == b"\x2b\x00":
            raise ValueError("BigTIFF: this parser reads classic TIFF offsets only")
        if header[2:4] != b"\x2a\x00":
            raise ValueError(f"not a TIFF (version {header[2:4]!r})")
        fh.seek(struct.unpack("<I", header[4:8])[0])
        (count,) = struct.unpack("<H", fh.read(2))
        entries = fh.read(count * 12)
    for i in range(count):
        tag, typ, n, value = struct.unpack("<HHII", entries[i * 12:(i + 1) * 12])
        if tag != GDAL_METADATA_TAG:
            continue
        if typ != 2:  # ASCII
            raise ValueError(f"tag 42112 has type {typ}, expected ASCII")
        if n <= 4:
            # Short values are stored inline in the entry rather than at an offset. Too
            # short to hold a RAT, but say so rather than silently reporting absence.
            raise ValueError("tag 42112 is stored inline and is too short to hold a RAT")
        with path.open("rb") as fh:
            fh.seek(value)
            blob = fh.read(n).rstrip(b"\x00")
        root = ET.fromstring(blob.decode("utf-8"))
        # GDAL nests the table inside an Item, not at the top level:
        #   <GDALMetadata>
        #     <Item name="DEFAULT_RASTER_ATTRIBUTE_TABLE" sample="0" role="rat">
        #       <GDALRasterAttributeTable ...>
        # `sample="0"` is band 1, the only band these rasters have. Matched on role rather
        # than on the name so a future GDAL renaming the item does not read as "no RAT".
        for item in root.findall("Item"):
            if item.get("role") == "rat" and item.get("sample", "0") == "0":
                return item.find("GDALRasterAttributeTable")
    return None


def check_cog_rat(base: Path) -> list[str]:
    """Verify every published COG carries its class labels INSIDE the file.

    Three separate failures, because they are genuinely different and only the first is
    obvious:

      * no RAT at all — the labels were never written, or the PAM sidecar carrying them was
        silently ignored (GDAL ignores a `.aux.xml` with an `<?xml ...?>` declaration);
      * a RAT that exists only as a sidecar next to the published COG — locally
        indistinguishable from success, because every reader loads PAM transparently, but
        the sidecar is excluded from the S3 sync and unfetchable by titiler;
      * a RAT whose rows disagree with the `classification:classes` the same build
        published in the item JSON.

    The third is checked against the ITEM rather than against a second copy of the table,
    so the assertion cannot drift from what shipped. The row COUNT is checked against an
    absolute, because the RAT and the STAC classes share a producer — one fact derived
    twice agrees with itself no matter how wrong it is.
    """
    problems: list[str] = []
    compared = 0
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc["id"]
        for key, asset in sorted(doc.get("assets", {}).items()):
            if asset.get("type") != pystac.MediaType.COG:
                continue
            local = base / item_id / PurePosixPath(urlparse(asset["href"]).path).parts[-1]
            if not local.is_file():
                continue  # missing assets are already reported by check_checksums
            compared += 1
            where = f"{item_id}/{local.name}"

            kind = "transition" if key.startswith("transition") else "classified"
            want_rows = EXPECTED_RAT_ROWS[kind]

            # A sidecar beside the PUBLISHED asset means the RAT did not make it in.
            sidecar = Path(str(local) + ".aux.xml")
            if sidecar.exists():
                problems.append(
                    f"{where}: a PAM sidecar sits beside the published COG, so the RAT is "
                    f"not embedded — it would be dropped by the S3 sync")

            try:
                rat = _read_embedded_rat(local)
            except (ValueError, ET.ParseError, UnicodeDecodeError, struct.error) as e:
                problems.append(f"{where}: cannot read TIFF tag 42112 — {e}")
                continue
            if rat is None:
                problems.append(
                    f"{where}: no raster attribute table embedded in the COG, so the "
                    f"published pixel values carry no labels")
                continue

            rows = rat.findall("Row")
            if len(rows) != want_rows:
                problems.append(
                    f"{where}: embedded RAT has {len(rows)} rows, expected {want_rows} "
                    f"for a {kind} raster")

            # Field usages, not just names: QGIS resolves a RAT by usage, so a table with
            # the right labels and no Name/colour usages renders as nothing while every
            # text-based check passes.
            usages = [f.findtext("Usage") for f in rat.findall("FieldDefn")]
            if usages != ["5", "2", "6", "7", "8", "9"]:
                problems.append(
                    f"{where}: embedded RAT field usages are {usages}, expected "
                    f"['5','2','6','7','8','9'] (MinMax/Name/Red/Green/Blue/Alpha)")

            # Agreement with what the item published for the same asset.
            classes = asset.get("classification:classes")
            if not classes:
                problems.append(
                    f"{where}: asset carries no classification:classes — the extension "
                    f"schema does not require them, so nothing else would report this")
                continue
            # Label AND colour. Comparing titles alone would leave the one value on
            # either side that is NOT derived from classes.json unguarded: the no-change
            # colour is a hand-typed literal in both producers (02_raster_tag.py's
            # NO_CHANGE_RGB and item_create.py's "D9D9D9"), and a drift between them
            # is invisible in every other gate while making a QGIS render and a web legend
            # disagree. The duplication is deliberate; this is what makes it safe.
            #
            # `.get()`, not `[]`: only `value` is required by the extension, so a class
            # missing `title` or `color_hint` must be REPORTED as a mismatch, not raise.
            # This function validates JSON on disk — the thing it exists to distrust — and
            # an uncaught KeyError here would discard every problem already collected,
            # including the one naming the real cause.
            try:
                want = {int(c["value"]): (c.get("title"),
                                          (c.get("color_hint") or "").upper())
                        for c in classes}
            except (KeyError, TypeError, ValueError) as e:
                problems.append(f"{where}: classification:classes is malformed — {e}")
                continue
            # Same for the RAT rows. The positional read below (value, name, r, g, b) is
            # only valid because the usages are the ones 02_raster_tag.py wrote — and a
            # table with a different layout is exactly what the usage check above is for,
            # so this parse must survive reaching one rather than taking the gate down
            # with a traceback.
            got = {}
            try:
                for row in rows:
                    cells = [f.text for f in row.findall("F")]
                    got[int(cells[0])] = (
                        cells[1], "".join(f"{int(x):02X}" for x in cells[2:5]))
            except (IndexError, TypeError, ValueError) as e:
                problems.append(
                    f"{where}: embedded RAT rows are not in the expected "
                    f"value/name/red/green/blue layout — {e}")
                continue
            # Differences first, then gate on them: gating on `got != want` and diffing
            # afterwards can produce a failure with an empty message.
            changed = [f"{v}: RAT {got.get(v)!r} vs item {want.get(v)!r}"
                       for v in sorted(set(got) | set(want)) if got.get(v) != want.get(v)]
            if changed:
                problems.append(
                    f"{where}: embedded RAT disagrees with classification:classes — "
                    f"{'; '.join(changed[:5])}"
                    f"{f' (+{len(changed) - 5} more)' if len(changed) > 5 else ''}")
    # Zero comparisons is not a pass — same reasoning as the sibling checks.
    if compared == 0:
        problems.append(
            f"no COG assets compared under {base} — the class-label contract was not "
            f"actually checked against anything")
    return problems


def check_pixel_values(base: Path) -> list[str]:
    """Every pixel value PRESENT in a raster must have a class.

    This is the check the uniform 81-row scheme cannot give us any other way. The RAT is
    identical on every item by design, so no cross-item comparison can notice that the
    raster contains a code the table does not describe — which is what an upstream change
    to drift's encoding, or a class this repo has never seen, would look like.

    Also asserts that overview values are a subset of the base values. Overviews must
    resample NEAREST or averaging invents codes that decode to transitions which did not
    happen there, and the RAT would then label them confidently. GDAL only WARNS on an
    unknown creation option, so `OVERVIEW_RESAMPLING=NEAREST` in 03_cog.py can fall back to
    the CUBIC default silently; this asserts the property rather than trusting the line.
    """
    import numpy as np

    problems: list[str] = []
    checked = 0
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc["id"]
        for key, asset in sorted(doc.get("assets", {}).items()):
            # Every COG, not only the transition. Restricting this to the transition
            # would be a scope that happens to fit today's data rather than a checked
            # property: 01_stage.R drops code 0 from drift's table, so a classified raster
            # carrying 0 — or any code a future drift adds — would ship with pixels
            # nothing describes, while the RAT still has its 9 rows and every title still
            # matches. The classified assets carry classification:classes too, so the same
            # comparison resolves for them unchanged.
            if asset.get("type") != pystac.MediaType.COG:
                continue
            local = base / item_id / PurePosixPath(urlparse(asset["href"]).path).parts[-1]
            if not local.is_file():
                continue
            checked += 1
            declared = {int(c["value"]) for c in asset.get("classification:classes", [])}
            # Block-windowed, not a single full-band read. Measured on one 11552x14651
            # int32 band: reading it whole peaks at 2.3 GB RSS — band, mask, compressed
            # copy and np.unique's sort copy all live at once. This runs inside
            # catalogue_release.sh's gate, which is meant to be runnable from a machine
            # that does not hold the source tree, so a hard 2 GB floor would OOM after the
            # entire build had already succeeded. Blockwise gives the identical answer
            # across all four COGs at 0.85 GB, and 0.34 GB under GDAL_CACHEMAX=64 — the
            # remainder is GDAL's own block cache, which sizes itself to a fraction of
            # available RAM rather than being a floor.
            with rasterio.open(local) as ds:
                base_vals: set[int] = set()
                for _, win in ds.block_windows(1):
                    block = ds.read(1, window=win, masked=True)
                    base_vals |= set(np.unique(block.compressed()).tolist())
                has_overviews = bool(ds.overviews(1))
                base_width, base_height = ds.width, ds.height
                # Read from the ARTIFACT, not hardcoded as GDAL's 512 default. The
                # threshold for building overviews IS the block size in force, and
                # 03_cog.py's creation options are a dict that already grew BIGTIFF "so
                # the choice is a decision rather than a default" — a BLOCKSIZE entry is
                # the obvious next edit and nothing would tie the two files together.
                # Measured with BLOCKSIZE=1024: a correct 600x600 COG legitimately has no
                # overviews, and a hardcoded 512 blocks the release over it.
                block_size = max(ds.block_shapes[0])
            # The FIRST overview, opened as its own dataset and read blockwise. A decimated
            # read of the base band (`out_shape=`) does not use the overviews — GDAL reads
            # full resolution and downsamples, which is the 677 MB this function exists to
            # avoid. Level 0 is the sensitive one: it is built directly from the base data,
            # so an interpolating resampler shows up there first.
            ov_vals: set[int] = set()
            # A flag, not a `continue`: `base_vals` and `declared` are already in hand, so
            # bailing out here would throw away the undescribed-pixel-value report — the
            # PRIMARY contract in this function's docstring — and send the operator to look
            # at a GDAL open option while the published pixels stay unlabelled. Only the
            # `invented` comparison genuinely cannot be computed without an overview.
            ov_checked = True
            if has_overviews:
                with rasterio.open(local, OVERVIEW_LEVEL=0) as ov:
                    # The premise, asserted rather than assumed. OVERVIEW_LEVEL is an open
                    # option, and GDAL only WARNS on one it does not recognise — so a
                    # renamed option or a driver change silently hands back the
                    # FULL-RESOLUTION dataset, `ov_vals` becomes `base_vals` by
                    # construction, and this guard reports success having compared a band
                    # against itself. Measured: a typo'd option name opens full res with
                    # no error and the subset test passes. That is the same
                    # silent-fallback failure this function exists to catch, so it gets
                    # the same treatment.
                    # NEITHER dimension shrank, not "the width did not". Measured: a
                    # 1x1024 raster's first overview is 1x512 — the width cannot halve
                    # below 1, so a width-only premise would falsely abort a release on a
                    # perfectly good narrow raster.
                    if ov.width >= base_width and ov.height >= base_height:
                        problems.append(
                            f"{item_id}/{local.name}: OVERVIEW_LEVEL=0 returned "
                            f"{ov.width}x{ov.height} against a "
                            f"{base_width}x{base_height} base — it did not select an "
                            f"overview, so the resampling contract was not checked")
                        ov_checked = False
                    else:
                        for _, win in ov.block_windows(1):
                            block = ov.read(1, window=win, masked=True)
                            ov_vals |= set(np.unique(block.compressed()).tolist())
            elif max(base_width, base_height) > block_size:
                # Only a blocker where overviews were warranted, and the threshold is
                # measured rather than assumed: the COG driver builds overviews when
                # EITHER dimension exceeds the block size (512x512 -> none, 513x513 -> one,
                # 400x600 -> one, 1024x100 -> one). Testing the width alone would let a
                # tall narrow raster lose its overviews unreported. An unconditional
                # failure would be worse still — it would abort a release, after the whole
                # build had succeeded, over a raster the driver built correctly.
                problems.append(
                    f"{item_id}/{local.name}: {base_width}x{base_height} COG has no "
                    f"overviews, so the resampling contract could not be checked")
                ov_checked = False
            else:
                # Small enough that the driver builds none — nothing to compare, and that
                # is correct rather than a failure.
                ov_checked = False
            undescribed = sorted(base_vals - declared)
            if undescribed:
                problems.append(
                    f"{item_id}/{local.name}: {len(undescribed)} pixel value(s) have no "
                    f"class: {undescribed[:10]} — the upstream encoding may have changed")
            invented = sorted(ov_vals - base_vals) if ov_checked else []
            if invented:
                problems.append(
                    f"{item_id}/{local.name}: overviews contain {len(invented)} value(s) "
                    f"absent from the full-resolution band: {invented[:10]} — overview "
                    f"resampling is interpolating class codes")
    if checked == 0:
        problems.append(
            f"no COG checked under {base} — the pixel-value contract was not actually "
            f"checked against anything")
    return problems


def check_cog_layout(base: Path) -> list[str]:
    """Verify every published COG actually has cloud-optimized layout.

    A COG's whole advantage is that a client reads a small header, then fetches only the
    tiles it needs. That depends on the main IFD sitting at the FRONT of the file — and
    an in-place metadata write moves it to the end, silently. Nothing else in this repo
    looks at layout: the bytes are a valid GeoTIFF, every `file:checksum` verifies against
    them, and the file opens correctly in QGIS. Only the range-request property is gone.

    Measured before this guard existed: the main IFD sat at byte 595,868 of a 602,582-byte
    classified COG and 1,330,104 of a 1,335,328-byte transition COG — 98.9% and 99.6% of
    each file had to be fetched to read a header.
    """
    problems: list[str] = []
    checked = 0
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc["id"]
        for asset in doc.get("assets", {}).values():
            if asset.get("type") != pystac.MediaType.COG:
                continue
            local = base / item_id / PurePosixPath(urlparse(asset["href"]).path).parts[-1]
            if not local.is_file():
                continue  # missing assets are already reported by check_checksums
            checked += 1
            # quiet=True: rio-cogeo prints its own coloured report to stderr via
            # click.secho, which would duplicate the message formatted below and
            # put ANSI codes in a release log.
            valid, errors, _warnings = cog_validate(local, quiet=True)
            if not valid:
                problems.append(
                    f"{item_id}/{local.name}: not a valid COG — "
                    f"{'; '.join(errors or ['no detail'])}")
    # Zero comparisons is not a pass, same reasoning as the sibling checks: a loop over
    # nothing returns clean, which reads identically to every COG having checked out.
    if checked == 0:
        problems.append(
            f"no COG assets found under {base} — the layout contract was not actually "
            f"checked against anything")
    return problems


def _qml_root(qml: str | None) -> ET.Element | None:
    """Parse a styleQML blob once. None when it is NULL or not XML."""
    if not qml:
        return None
    try:
        return ET.fromstring(qml)
    except ET.ParseError:
        return None


def _renderer(root: ET.Element) -> tuple[str, str]:
    rend = root.find("renderer-v2")
    if rend is None:
        return ("", "")
    return (rend.get("type") or "", rend.get("attr") or "")


def _categories(root: ET.Element) -> dict[str, tuple[str, bool]]:
    """{category value: ('#rrggbb', drawn)} for a categorized renderer.

    Colour is read from the symbol QGIS will paint, and `drawn` is the category's
    own render state — the 64 non-Trees transition categories ship `render="false"`
    by design, so the two have to be distinguishable.
    """
    rend = root.find("renderer-v2")
    if rend is None:
        return {}
    colours, visible = {}, {}
    syms = rend.find("symbols")
    for sym in ([] if syms is None else list(syms)):
        # A symbol drawn at zero opacity, or whose only layer is disabled, paints
        # nothing however right its colour is.
        try:
            alpha = float(sym.get("alpha") or "1")
        except ValueError:
            alpha = 0.0
        painted = alpha > 0
        colour = ""
        for layer in sym.findall("layer"):
            if (layer.get("enabled") or "1") != "1":
                continue
            opt = layer.find("Option")
            vals = {o.get("name"): o.get("value", "")
                    for o in ([] if opt is None else list(opt))}
            if vals.get("style") == "no" and vals.get("outline_style") == "no":
                continue
            if not colour:
                rgb = vals.get("color", "").split(",")[:3]
                if len(rgb) == 3:
                    colour = "#%02x%02x%02x" % tuple(int(v) for v in rgb)
            break
        else:
            painted = False
        colours[sym.get("name")] = colour
        visible[sym.get("name")] = painted
    out = {}
    cats = rend.find("categories")
    for cat in ([] if cats is None else list(cats)):
        sym = cat.get("symbol")
        drawn = (cat.get("render") or "true") != "false" and visible.get(sym, False)
        out[cat.get("value")] = (colours.get(sym, ""), drawn)
    return out


def _single_symbol_paints(root: ET.Element) -> bool:
    """Does a single-symbol renderer actually paint anything?

    The floodplain delineations get no palette comparison — there is no attribute to
    categorize on — so this is the only thing standing between a hand-edit and nine
    invisible layers per item.
    """
    rend = root.find("renderer-v2")
    if rend is None:
        return False
    syms = rend.find("symbols")
    for sym in ([] if syms is None else list(syms)):
        try:
            if float(sym.get("alpha") or "1") <= 0:
                continue
        except ValueError:
            continue
        for layer in sym.findall("layer"):
            if (layer.get("enabled") or "1") != "1":
                continue
            opt = layer.find("Option")
            vals = {o.get("name"): o.get("value", "")
                    for o in ([] if opt is None else list(opt))}
            if vals.get("style") != "no" or vals.get("outline_style") != "no":
                return True
    return False


def check_layer_styles(base: Path) -> list[str]:
    """Every GeoPackage opens styled, and that style agrees with the raster palette.

    Note on what the palette arm can and cannot prove. Both sides descend from one
    `data/raw/classes.json`: `classification:classes` through `item_create.py`, the
    embedded QML through `styles/*.qml`. So this catches a `styles/` tree that has gone
    stale against the class table, and a style embedded against the wrong layer — it
    does NOT independently verify the colours are the ones drift intends. Nothing here
    can; that is what `classes.json` being ferried from `drift::dft_class_table()`
    rather than retyped is for.

    What it does prove independently: the style loads (the rfp#17 NULL trap), it is the
    renderer that style is supposed to be, it paints something, and every value the
    layer actually holds has a category.
    """
    problems: list[str] = []
    checked_files = 0
    # Which renderer each style must be. An implicit "not categorized, therefore fine"
    # is a guard failing toward pass: `nullSymbol` is a legitimate QGIS renderer that
    # draws absolutely nothing, and it would sail through a check keyed on categories.
    EXPECT_RENDERER = {"floodplain": "singleSymbol",
                       "classified": "categorizedSymbol",
                       "transition": "categorizedSymbol"}

    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc["id"]
        item_dir = base / item_id

        # --- the three style ASSETS: absolute, because the cross-item key check
        # --- cannot see a loss that hits every item identically (#23).
        assets = doc.get("assets", {})
        for key, fname in sorted(EXPECTED_STYLE_ASSETS.items()):
            asset = assets.get(key)
            if asset is None:
                problems.append(
                    f"{item_id} publishes no '{key}' asset — every item losing it "
                    f"looks uniform to the cross-item key check, so this literal is "
                    f"the only thing that fires")
                continue
            if asset.get("roles") != ["style"]:
                problems.append(
                    f"{item_id} asset '{key}' has roles {asset.get('roles')!r}, "
                    f"expected ['style']")
            if not str(asset.get("href", "")).endswith("/" + fname):
                problems.append(
                    f"{item_id} asset '{key}' points at {asset.get('href')!r}, which "
                    f"does not end in {fname} — the key and the file it publishes have "
                    f"come apart, and href, checksum and size would all still agree")
            # Three copies of one artifact exist: the repo's, the one beside the
            # assets, and the blob inside the GeoPackage. Tie the first two together
            # here; the third is tied below.
            local, repo_copy = item_dir / fname, STYLE_DIR / fname
            if local.exists() and repo_copy.exists() and \
                    local.read_bytes() != repo_copy.read_bytes():
                problems.append(
                    f"{item_id}/{fname} differs from {repo_copy} — the published style "
                    f"is not the reviewed one")

        # The raster palette this item published. Every classified asset must carry the
        # same table, so a per-year palette bug cannot hide behind a merge.
        raster: dict[str, dict[str, str]] = {}
        per_year: list[tuple[str, dict[str, str]]] = []
        for key, asset in assets.items():
            entries = asset.get("classification:classes")
            if not entries:
                continue
            kind = "transition" if key.startswith("transition") else "classified"
            table = {e["title"]: "#" + e["color_hint"].lower() for e in entries}
            if kind == "classified":
                per_year.append((key, table))
            raster.setdefault(kind, {}).update(table)
        for key, table in per_year[1:]:
            if table != per_year[0][1]:
                problems.append(
                    f"{item_id} asset '{key}' publishes a different class table from "
                    f"'{per_year[0][0]}' — the years disagree about the palette")

        for gname in STYLED_GPKGS:
            gpkg = item_dir / gname
            if not gpkg.exists():
                problems.append(f"{item_id}: {gname} is absent")
                continue
            checked_files += 1
            con = sqlite3.connect(f"file:{gpkg}?mode=ro", uri=True)
            try:
                if not con.execute("SELECT 1 FROM sqlite_master WHERE type='table' "
                                   "AND name='layer_styles'").fetchone():
                    problems.append(
                        f"{item_id}/{gname} has no layer_styles table — it will open "
                        f"unstyled in QGIS (04_gpkg_style.py did not run)")
                    continue
                layers = [r[0] for r in con.execute(
                    "SELECT table_name FROM gpkg_contents WHERE data_type='features'")]
                geom_of = dict(con.execute(
                    "SELECT table_name, column_name FROM gpkg_geometry_columns"))
                rows = con.execute(
                    "SELECT f_table_name, f_table_schema, useAsDefault, styleName, "
                    "f_geometry_column, styleQML FROM layer_styles").fetchall()
                cols_of = {lyr: {r[1] for r in con.execute(
                    f'PRAGMA table_info("{lyr}")')} for lyr in layers}

                def distinct(lyr: str, attr: str, _c=con) -> set[str]:
                    return {str(r[0]) for r in _c.execute(
                        f'SELECT DISTINCT "{attr}" FROM "{lyr}"') if r[0] is not None}

                styled = {r[0] for r in rows}
                for missing in sorted(set(layers) - styled):
                    problems.append(
                        f"{item_id}/{gname} layer '{missing}' has no style row — it "
                        f"opens unstyled while every other layer looks correct")
                for extra in sorted(styled - set(layers)):
                    problems.append(
                        f"{item_id}/{gname} has a style row for '{extra}', which is "
                        f"not a feature layer in this file")

                for table, schema, use_default, style_name, geom, qml in rows:
                    where = f"{item_id}/{gname} style for '{table}'"
                    # NULL here is written successfully, logs nothing, and makes QGIS
                    # fall back to a single symbol: it matches with `= ''` and NULL
                    # never equals. The failure this check exists to catch (rfp#17).
                    if schema != "":
                        problems.append(
                            f"{where} has f_table_schema={schema!r}, expected '' — "
                            f"QGIS matches with = '' and NULL never equals, so this "
                            f"layer opens unstyled with nothing logged")
                    if use_default != 1:
                        problems.append(
                            f"{where} has useAsDefault={use_default!r}, expected 1 — "
                            f"it will not load automatically")
                    # Same silent-unstyled signature as the NULL schema above: QGIS
                    # matches the row on this column too, and the writer fills it from
                    # a `or "geom"` fallback that nothing else validates.
                    if table in geom_of and geom != geom_of[table]:
                        problems.append(
                            f"{where} has f_geometry_column={geom!r} but the layer's "
                            f"geometry column is {geom_of[table]!r}")

                    root = _qml_root(qml)
                    if root is None:
                        # Named, rather than an uncaught ParseError out of this
                        # function — a half-written style row is exactly what this
                        # check exists to report, and a traceback points at Python.
                        problems.append(
                            f"{where} has a NULL or unparseable styleQML — the row "
                            f"exists, so every presence check passes, and the layer "
                            f"opens unstyled")
                        continue
                    # Tie the third copy of the artifact to the other two.
                    kind = style_name if style_name in EXPECT_RENDERER else None
                    if kind is None:
                        problems.append(
                            f"{where} has styleName={style_name!r}, which names none "
                            f"of {sorted(EXPECT_RENDERER)}")
                        continue
                    repo_copy = STYLE_DIR / f"{kind}.qml"
                    if repo_copy.exists() and qml != repo_copy.read_text(encoding="utf-8"):
                        problems.append(
                            f"{where} embeds a style that is not {repo_copy} — the "
                            f"GeoPackage carries something no one reviewed")

                    rtype, attr = _renderer(root)
                    if rtype != EXPECT_RENDERER[kind]:
                        problems.append(
                            f"{where} uses renderer {rtype!r}, expected "
                            f"{EXPECT_RENDERER[kind]!r} — a nullSymbol or singleSymbol "
                            f"style loads cleanly and paints nothing or one colour, "
                            f"and a check keyed on categories would skip it")
                        continue

                    if rtype == "singleSymbol":
                        if not _single_symbol_paints(root):
                            problems.append(
                                f"{where} is a single symbol that paints nothing — "
                                f"zero opacity, no enabled layer, or no fill and no "
                                f"outline")
                        continue

                    if attr not in cols_of.get(table, set()):
                        problems.append(
                            f"{where} categorizes on {attr!r}, which is not a column "
                            f"of that layer — it loads styled and renders nothing")
                        continue

                    cats = _categories(root)
                    if len(cats) != EXPECTED_STYLE_CATEGORIES[kind]:
                        problems.append(
                            f"{where} has {len(cats)} categories, expected "
                            f"{EXPECTED_STYLE_CATEGORIES[kind]}")
                    present = distinct(table, attr)
                    # Coverage, not intersection: a single renamed class leaves eight
                    # others matching, so "any value is drawn" stays green while one
                    # class is uncategorized and invisible.
                    uncategorized = sorted(present - set(cats))
                    if uncategorized:
                        problems.append(
                            f"{where} has no category for {len(uncategorized)} value(s) "
                            f"the layer holds ({', '.join(uncategorized[:3])}"
                            f"{', ...' if len(uncategorized) > 3 else ''}) — those "
                            f"features draw with no symbol")
                    # "At least one category is switched on" is a STYLE property only
                    # where every category ships on. For `transition` 64 of 72 ship
                    # off by design, so requiring a drawn value there would assert a
                    # DATA property — that this watershed happened to lose trees — and
                    # refuse a correct release on a correct dataset.
                    if kind == "classified" and present and not any(
                            cats[v][1] for v in present if v in cats):
                        problems.append(
                            f"{where} draws none of the {len(present)} value(s) the "
                            f"layer holds — it renders blank")
                    for value, (colour, _drawn) in sorted(cats.items()):
                        if value == "NULL":
                            continue
                        title = value.replace(VECTOR_ARROW, RASTER_ARROW)
                        want = raster.get(kind, {}).get(title)
                        if want is None:
                            problems.append(
                                f"{where} draws category {value!r}, which is not in "
                                f"this item's classification:classes — the vector "
                                f"legend names something the raster does not")
                        elif want != colour:
                            problems.append(
                                f"{where} draws {value!r} as {colour or 'nothing'} but "
                                f"the raster publishes {want} — the vector and raster "
                                f"views of the same ground would disagree")
            finally:
                con.close()

    # A check that opened nothing is not a pass.
    if checked_files == 0:
        problems.append(
            f"no GeoPackages were style-checked under {base} — the style contract was "
            f"not actually checked against anything")
    return problems


def check_checksums(base: Path, partial: bool = False) -> tuple[list[str], dict[tuple, list[str]]]:
    """Verify every asset's `file:checksum` and `file:size` against the file on disk.

    Assets live at `<base>/<item_id>/<name>`, and the S3 href's basename is that
    same name — so the local path is derivable from the href without extra state.

    Returns the problems (empty when everything matches) and, beside them, which items
    published which sanctioned year set — a number on screen rather than a silence, the
    same shape as check_provenance's per-section counts. Two populations is a state
    somebody has to be able to see without reading 23 JSON files.
    """
    problems: list[str] = []
    used: dict[tuple, list[str]] = {tuple(sorted(y)): [] for y in ALLOWED_YEAR_SETS}
    asset_keys: dict[str, set] = {}
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc["id"]
        asset_keys[item_id] = set(doc.get("assets", {}))

        # The release syncs the DIRECTORY, not the asset list (`aws s3 sync "$STAC_DIR"`),
        # so any file sitting beside the assets reaches the public bucket described by
        # nothing — and no other guard in this repo enumerates an item directory.
        #
        # Compared WHOLE, deliberately. Scoping it to the classified COGs would leave a
        # stray transition COG, GeoPackage or .qml uncovered while reading, to the next
        # person, as "the directory is guarded" — a guard's scope is usually a coincidence
        # and it will not announce itself. The other direction (an asset with no file) is
        # already the per-asset loop's `asset not on disk`, so only strays are reported.
        #
        # Names only files this tree HAS, so it survives --partial.
        item_dir = base / item_id
        if item_dir.is_dir():
            on_disk = {p.name for p in item_dir.iterdir() if p.is_file()}
            published = {PurePosixPath(urlparse(a["href"]).path).name
                         for a in doc.get("assets", {}).values() if a.get("href")}
            stray = on_disk - published
            if stray:
                problems.append(
                    f"{item_id}: {len(stray)} file(s) in {item_dir} that no asset describes "
                    f"({sorted(stray)}) — the release syncs the directory, so these would "
                    f"reach the public bucket with nothing pointing at them")

        for key, asset in sorted(doc.get("assets", {}).items()):
            where = f"{item_id}/{key}"
            checksum = asset.get("file:checksum")
            size = asset.get("file:size")
            if checksum is None or size is None:
                problems.append(f"{where}: missing file:checksum or file:size")
                continue
            # Structural: catches the mistake the JSON schema cannot see.
            if not checksum.startswith(MULTIHASH_SHA256) or len(checksum) != 68:
                problems.append(
                    f"{where}: not a sha256 multihash (want '1220' + 64 hex, got "
                    f"{len(checksum)} chars starting {checksum[:6]!r})")
                continue
            if checksum != checksum.lower():
                problems.append(f"{where}: checksum must be lowercase hex")
                continue

            # Resolve the local file from the LAST TWO href segments, not from
            # item_id + basename. Deriving the directory ourselves would verify the
            # right bytes for a wrong href — a published prefix typo would point S3
            # consumers at a 404 while this guard passed against the correct local
            # file. The href is the thing that ships, so the href is what we check.
            href_parts = PurePosixPath(urlparse(asset["href"]).path).parts
            if len(href_parts) < 2 or href_parts[-2] != item_id:
                problems.append(
                    f"{where}: href does not sit under '{item_id}/' — {asset['href']}")
                continue
            local = base / href_parts[-2] / href_parts[-1]
            if not local.is_file():
                problems.append(f"{where}: asset not on disk at {local}")
                continue
            actual_size = local.stat().st_size
            if actual_size != size:
                problems.append(
                    f"{where}: file:size {size} but file is {actual_size} bytes")
            h = hashlib.sha256()
            with local.open("rb") as fh:
                for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                    h.update(chunk)
            actual = MULTIHASH_SHA256 + h.hexdigest()
            if actual != checksum:
                problems.append(
                    f"{where}: file:checksum does not match the bytes on disk "
                    f"(published {checksum[:16]}…, actual {actual[:16]}…)")

    # An item that lost an asset would otherwise pass by iterating nothing —
    # "no assets to check" and "all assets checked out" produce identical output.
    # See the ALLOWED_YEAR_SETS block for the partition this implements and why.
    if asset_keys:
        fixed_keys = {i: {k for k in ks if not CLASSIFIED_KEY_RE.match(k)}
                      for i, ks in asset_keys.items()}
        year_keys = {i: {k for k in ks if CLASSIFIED_KEY_RE.match(k)}
                     for i, ks in asset_keys.items()}

        # Fixed half: every item is built from the same template, so these must be
        # identical. Derived from the largest set seen, which is blind to a loss that hits
        # every item — paired with EXPECTED_STYLE_ASSETS above, which is the absolute.
        expected_fixed = max(fixed_keys.values(), key=len)
        if not expected_fixed:
            problems.append("no non-classified assets on any item — nothing was verified")
        for item_id, keys in sorted(fixed_keys.items()):
            if keys != expected_fixed:
                problems.append(
                    f"{item_id}: non-classified asset set differs from the other items — "
                    f"missing {sorted(expected_fixed - keys) or 'none'}, "
                    f"unexpected {sorted(keys - expected_fixed) or 'none'}")

        # Year half, arm (a): per item, against the literal. Names keys the item HAS, so
        # it runs under --partial too.
        allowed = {tuple(sorted(y)): {f"classified_{y_}" for y_ in y}
                   for y in ALLOWED_YEAR_SETS}
        for item_id, keys in sorted(year_keys.items()):
            match = next((y for y, exp in allowed.items() if keys == exp), None)
            if match is None:
                problems.append(
                    f"{item_id}: classified asset keys {sorted(keys) or 'none'} are not "
                    f"any sanctioned year set. ALLOWED_YEAR_SETS names "
                    + "; ".join("/".join(str(v) for v in y) for y in allowed)
                    + ". A year set nobody sanctioned is either an upstream span this "
                    f"collection has not decided to publish, or a lost asset that looks "
                    f"uniform to the cross-item compare above")
                continue
            used[match].append(item_id)

        # Arm (b): every sanctioned set is actually used. Asks about items the tree may
        # legitimately not contain, so it is the one arm --partial drops.
        if not partial:
            for y, ids in sorted(used.items()):
                if not ids:
                    # TWO directions, and the remedy has to name both. A set that has
                    # BECOME unused should be deleted. A set added AHEAD of its data — the
                    # live state of floodplains#79 — must not be: deleting it would make
                    # arm (a) refuse the first item that arrives on it, so the remedy would
                    # walk the operator back through the guard. The likeliest trigger is
                    # not a stale literal at all but a group that failed to stage.
                    problems.append(
                        "no item publishes the year set "
                        + "/".join(str(v) for v in y)
                        + " — an entry in ALLOWED_YEAR_SETS that no item in this build "
                        "uses. If the rollout that made it obsolete has finished, delete "
                        "it. If the rollout that will USE it has not reached this build "
                        "yet, do NOT delete it — check that the groups you expected to "
                        "supply it actually staged (data/raw/PARTIAL_STAGE names any that "
                        "did not)")
    return problems, used


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base", default="data/stac", type=Path,
                   help="directory holding <item_id>.json + collection.json")
    p.add_argument("--raw", default="data/raw", type=Path,
                   help="staging dir used to derive the expected item count")
    p.add_argument("--expect", type=int, default=None,
                   help="expected item count (default: number of data/raw/*/meta.json)")
    p.add_argument("--expect-provenance", type=int, default=None,
                   help="EXACT number of items carrying a non-null nge: value (#32). Set by the "
                        "release from a human-chosen literal, never derived from the build; "
                        "omitted (a rebuild) means no check")
    p.add_argument("--partial", action="store_true",
                   help="the tree holds a SUBSET of the catalogue (catalogue_release.sh --only). "
                        "Drops the whole-catalogue arms of the deprecation check (#26); every "
                        "per-item arm still runs. Default is strict, so a forgotten flag refuses "
                        "rather than waves through")
    args = p.parse_args()
    if args.expect_provenance is not None and args.expect_provenance < 0:
        print("FAILED: --expect-provenance must be >= 0", file=sys.stderr)
        return 1

    if not args.base.is_dir():
        print(f"FAILED: --base {args.base} is not a directory", file=sys.stderr)
        return 1

    expected = args.expect
    if expected is None:
        expected = len(list(args.raw.glob("*/meta.json")))
    if expected < 1:
        print(f"FAILED: expected item count is {expected} — nothing staged under "
              f"{args.raw}/*/meta.json, so there is nothing to validate",
              file=sys.stderr)
        return 1

    items = 0
    collections = 0
    collection_version = None
    failed: list[tuple[str, str]] = []

    for path in sorted(args.base.glob("*.json")):
        try:
            doc = json.loads(path.read_text())
        except Exception as e:  # noqa: BLE001 — a malformed file is a gate failure
            failed.append((path.name, f"unreadable: {e}"))
            continue

        try:
            if doc.get("type") == "Collection":
                pystac.Collection.from_dict(doc).validate()
                # Both checks run before either can `continue`, so a wrong licence and a
                # half-applied version stamp are reported together rather than one release
                # apart. And both run HERE rather than after the count check below: that
                # would put them behind check_checksums' ~670 MB re-read, which
                # short-circuits on any asset drift and would make a restore-the-bug proof
                # for these guards meaningless (#46).
                coll_problems = check_collection_metadata(doc)
                stamp_problem = check_version_stamp(doc)
                if stamp_problem:
                    coll_problems.append(stamp_problem)
                if coll_problems:
                    failed.extend((path.name, p) for p in coll_problems)
                    continue
                collections += 1
                collection_version = doc.get("version")
            elif doc.get("type") == "Feature":
                pystac.Item.from_dict(doc).validate()
                items += 1
            else:
                failed.append((path.name, f"unexpected type: {doc.get('type')!r}"))
        except Exception as e:  # noqa: BLE001 — collect all failures, report once
            failed.append((path.name, str(e).splitlines()[0][:200]))

    print(f"valid: {items} item(s) + {collections} collection(s)")

    if failed:
        print(f"FAILED: {len(failed)} document(s) did not validate", file=sys.stderr)
        for name, err in failed:
            print(f"  {name}: {err}", file=sys.stderr)
        return 1

    # Count check last, so a genuine validation error is reported in preference to
    # the count symptom it would also cause.
    if items != expected:
        print(f"FAILED: validated {items} item(s) but expected {expected} "
              f"(from {args.raw}/*/meta.json). A short build must not be published — "
              f"it would overwrite the live collection.", file=sys.stderr)
        return 1
    if collections != 1:
        print(f"FAILED: expected exactly 1 collection.json, found {collections}",
              file=sys.stderr)
        return 1
    print("collection version: " + (collection_version
          or "unstamped (a build; catalogue_release.sh stamps the tag on release)"))

    # --- licence: does the collection say what a consumer may do, and credit whom? ---
    #
    # The document half ran in the loop above. This is the premise it rests on: the
    # attribution names a source collection, and the items have to still be built from it.
    bad_premise = check_citation_premise(args.base)
    if bad_premise:
        print(f"FAILED: {len(bad_premise)} citation-premise problem(s)", file=sys.stderr)
        for msg in bad_premise:
            print(f"  {msg}", file=sys.stderr)
        return 1

    # --- deprecation: are the over-mapped items marked, and only them? (#26) ---
    # Here rather than after check_checksums, for the same reason as the premise check above:
    # behind the 670 MB re-read, any asset drift short-circuits it and a restore-the-bug proof
    # for this guard proves nothing (#46).
    bad_dep = check_deprecated(args.base, partial=args.partial)
    if bad_dep:
        print(f"FAILED: {len(bad_dep)} deprecation-marker problem(s)", file=sys.stderr)
        for msg in bad_dep:
            print(f"  {msg}", file=sys.stderr)
        return 1
    if args.partial:
        print("deprecation: --partial, so ids named in the literal but absent from this tree "
              "are not asserted; every other arm ran, including marked iff not built on "
              f"flooded >= {'.'.join(map(str, MIN_FLOODED_VERSION))}")
    else:
        print(f"deprecation: exactly {len(EXPECTED_DEPRECATED)} item(s) published "
              f"deprecated ({', '.join(sorted(EXPECTED_DEPRECATED))}), each declaring the "
              f"version extension, and every item is marked iff its nge:flooded_version is "
              f"below {'.'.join(map(str, MIN_FLOODED_VERSION))} or unreadable")
    print(f"licence: {EXPECTED_LICENSE} with rel=license + rel=derived_from links, "
          f"{len(EXPECTED_PROVIDERS)} providers, sci:citation verbatim; no item's "
          f"nge:landcover_collection or nge:landcover_stac_url contradicts the "
          f"citation (each is {EXPECTED_SOURCE_COLLECTION} / the Planetary Computer, "
          f"or null, independently)")

    # --- file extension: do the published checksums describe the bytes we ship? ---
    #
    # This re-reads every asset (~670 MB, ~2.5s). That cost buys the only thing the
    # schema cannot give us: the file extension's pattern is `^[a-f0-9]+$`, so a bare
    # sha256 with no multihash prefix validates cleanly, and so does a well-formed
    # checksum of the wrong bytes. A guard that only checked the field was present
    # would be decoration on an issue whose entire subject is byte integrity.
    bad, year_sets = check_checksums(args.base, partial=args.partial)
    if bad:
        print(f"FAILED: {len(bad)} asset checksum/size problem(s)", file=sys.stderr)
        for msg in bad:
            print(f"  {msg}", file=sys.stderr)
        return 1
    print("classified year sets: "
          + "; ".join(f"{'/'.join(str(v) for v in y)} on {len(ids)} item(s)"
                      for y, ids in sorted(year_sets.items()))
          + (" (--partial: unused sets not checked)" if args.partial else ""))

    # --- run provenance: does every item carry the declared nge: contract? ---
    missing_prov, traced, n_items, per_section = check_provenance(args.base, args.expect_provenance)
    if missing_prov:
        print(f"FAILED: {len(missing_prov)} provenance contract problem(s)",
              file=sys.stderr)
        for msg in missing_prov:
            print(f"  {msg}", file=sys.stderr)
        return 1
    bad_tags = check_cog_tags(args.base)
    if bad_tags:
        print(f"FAILED: {len(bad_tags)} COG provenance-tag problem(s)", file=sys.stderr)
        for msg in bad_tags:
            print(f"  {msg}", file=sys.stderr)
        return 1
    print(f"provenance: {len(REQUIRED_NGE_PROPERTIES)} nge: properties on every item "
          f"({traced} of {n_items} carry values — "
          + ", ".join(f"{s} {n}" for s, n in per_section.items())
          + f"; floor {'none' if args.expect_provenance is None else args.expect_provenance}), "
          f"COG tags agree")

    # --- layer styles: do the GeoPackages open styled, and does that style agree
    # --- with the raster palette for the same ground? (#46)
    bad_styles = check_layer_styles(args.base)
    if bad_styles:
        print(f"FAILED: {len(bad_styles)} layer-style problem(s)", file=sys.stderr)
        for msg in bad_styles:
            print(f"  {msg}", file=sys.stderr)
        return 1
    print(f"layer styles: every feature layer in {len(STYLED_GPKGS)} GeoPackages carries "
          f"the expected renderer, paints something, has a category for every value it "
          f"holds, and agrees with classification:classes; "
          f"{len(EXPECTED_STYLE_ASSETS)} style assets published per item")

    # --- COG layout: is the range-request property the format promises actually there? ---
    bad_layout = check_cog_layout(args.base)
    if bad_layout:
        print(f"FAILED: {len(bad_layout)} COG layout problem(s)", file=sys.stderr)
        for msg in bad_layout:
            print(f"  {msg}", file=sys.stderr)
        return 1
    print("cog layout: valid on every COG")

    # --- class labels: do the published pixels say what they mean? ---
    bad_rat = check_cog_rat(args.base)
    if bad_rat:
        print(f"FAILED: {len(bad_rat)} class-label problem(s)", file=sys.stderr)
        for msg in bad_rat:
            print(f"  {msg}", file=sys.stderr)
        return 1
    bad_codes = check_pixel_values(args.base)
    if bad_codes:
        print(f"FAILED: {len(bad_codes)} pixel-value problem(s)", file=sys.stderr)
        for msg in bad_codes:
            print(f"  {msg}", file=sys.stderr)
        return 1
    print(f"class labels: RAT embedded in every COG "
          f"({EXPECTED_RAT_ROWS['classified']} classes / "
          f"{EXPECTED_RAT_ROWS['transition']} transitions), agrees with "
          f"classification:classes, every pixel value described")

    return 0


if __name__ == "__main__":
    sys.exit(main())
