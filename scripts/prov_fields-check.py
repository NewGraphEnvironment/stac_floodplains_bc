#!/usr/bin/env python3
"""prov_fields-check.py — prove item_validate.py's renamed-provenance arms fire (#74).

    uv run python scripts/prov_fields-check.py     # exit = number of failed assertions

#74 moved the twelve provenance fields off the `nge:` prefix onto `processing:datetime`,
`processing:software`, `link:*` and `landcover:*`, and stopped publishing an explicit null.
That retired the guard this repo leaned on hardest — set equality over the `nge:` key set —
and replaced it with a declared-key arm, a per-field census, a biconditional on the processing
extension, and a prefix table. None of those is reached by a normal build: the census and the
floor are release-only, and the COG-tag arms sit behind ~1.3 GB of real hashing.

Each case builds a tiny synthetic `data/stac`-shaped tree. The COG arms write real
single-pixel GeoTIFFs with real GDAL tags, because `check_cog_tags` opens the file.

Every assertion greps for ITS OWN message. A suite with N guards has N ways to return a
non-empty problem list, and every one of them looks the same to a check that counts.

Sibling of `year_sets-check.py` and `fp_provenance-check.R`; like them it is NOT wired into
`run_pipeline.sh`, because it exercises guards a normal build never trips.
"""

import ast
import hashlib
import json
import io
import pathlib
import re
import shutil
import sys
import tempfile

import numpy as np
import pystac
import rasterio

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import only_preflight as op  # noqa: E402
from item_validate import (  # noqa: E402
    METRIC_PROPERTIES as METRIC_PROPERTIES_V,
    METRIC_NET_TOLERANCE,
    METRIC_SCOPE_CENSUS, METRIC_SCOPE_PAIRS, PROV_CENSUS, PROV_FIELDS, PROV_PREFIXES,
    PROV_PROPERTIES, PROV_SOFTWARE, SOFTWARE_PROPERTY, SHARED_TAG_PROPERTIES, check_cog_tags,
    check_field_prefixes, check_metric_scopes, check_processing_stamp, check_provenance,
)

ROOT = pathlib.Path(__file__).resolve().parent.parent
FAILS = 0
N = 0


def ok(desc: str) -> None:
    global N
    N += 1
    print(f"  ok    {desc}")


def bad(desc: str, why: str) -> None:
    global N, FAILS
    N += 1
    FAILS += 1
    print(f"  FAIL  {desc} — {why}")


def expect_clean(desc: str, problems: list[str]) -> None:
    ok(desc) if not problems else bad(desc, f"{len(problems)} problem(s): {problems[0]}")


def expect_problem(desc: str, problems: list[str], needle: str) -> None:
    """A problem whose MESSAGE names the arm under test.

    Not `problems != []`: a fixture that trips the declared-key arm, the census and the
    prefix table at once reads identically to one that trips the arm being measured.
    """
    if not problems:
        bad(desc, "no problem reported")
    elif not any(needle in p for p in problems):
        bad(desc, f"a DIFFERENT arm fired: {problems[0][:160]}")
    else:
        ok(desc)


# --- fixtures --------------------------------------------------------------------------

# The staged values, by staged field name — what 01_stage.R writes into meta.json.
STAGED = {
    "link_run_uid": "20260901_234743-6628379d",
    "link_config_sha256": "sha256:19e3a0",
    "link_sha": "689146867a5f",
    "link_version": "0.50.0",
    "flooded_version": "0.5.0",
    "drift_version": "0.8.0",
    "produced_datetime": "2026-09-03T07:39:25Z",
    "landcover_source": "io-lulc",
    "landcover_collection": "io-lulc-annual-v02",
    "landcover_stac_url": "https://planetarycomputer.microsoft.com/api/stac/v1",
    "landcover_key": "sha256:97095d",
    "landcover_item_hash": "sha256:f83e23",
}
# The non-provenance half of every item: published as properties AND tagged into the COG, so
# this fixture has to cover SHARED_TAG_PROPERTIES exactly or check_cog_tags reports a missing
# property rather than the thing a case is testing. Pinned below rather than trusted, which is
# also what keeps the import of that name honest.
#
# The `*_footprint_*` values are deliberately LARGER than their unsuffixed siblings and the
# nets are consistent per scope, so this fixture satisfies check_metric_scopes and a case
# that breaks it has to say so.
SHARED = {
    "wsg": "aaaa", "species": "ch", "scenario": "ff04", "region": "Test",
    "floodplain_ff02_km2": 1.0, "floodplain_ff04_km2": 2.0, "floodplain_ff06_km2": 3.0,
    "gross_loss_ha": 1.5, "gross_gain_ha": 0.5, "net_ha": -1.0,
    "floodplain_ff02_footprint_km2": 1.2, "floodplain_ff04_footprint_km2": 2.2,
    "floodplain_ff06_footprint_km2": 3.2,
    "gross_loss_footprint_ha": 1.9, "gross_gain_footprint_ha": 0.7, "net_footprint_ha": -1.2,
}
assert set(SHARED) == SHARED_TAG_PROPERTIES, (
    "SHARED fixture and item_validate.SHARED_TAG_PROPERTIES disagree: "
    f"{sorted(set(SHARED) ^ SHARED_TAG_PROPERTIES)}")
PROCESSING_EXT = "https://stac-extensions.github.io/processing/v1.2.0/schema.json"
OTHER_EXTS = ["https://stac-extensions.github.io/projection/v1.1.0/schema.json",
              "https://stac-extensions.github.io/file/v2.1.0/schema.json",
              "https://stac-extensions.github.io/classification/v2.0.0/schema.json"]


def publish(staged: dict) -> dict:
    """What item_create.py would publish for these staged values.

    A deliberate mirror of the writer, not an import: importing item_create.py runs the whole
    build. The two are tied together statically by `the two copies of the map` case below,
    which parses both files rather than trusting this function.
    """
    props = {}
    for field, prop in PROV_PROPERTIES.items():
        if staged.get(field) is not None:
            props[prop] = staged[field]
    software = {}
    for entry, fields in PROV_SOFTWARE.items():
        values = [staged.get(f) for f in fields]
        if all(v is None for v in values):
            continue
        software[entry] = "+".join("" if v is None else str(v) for v in values)
    if software:
        props[SOFTWARE_PROPERTY] = software
    return props


def write_item(base: pathlib.Path, item_id: str, staged: dict | None = None, *,
               props_extra: dict = (), asset_extra: dict = (), cog: bool = False,
               tags_override: dict = (), tags_drop: tuple = (), exts: list | None = None,
               shared: bool = True) -> None:
    """One item, optionally with a real tagged GeoTIFF beside it."""
    staged = STAGED if staged is None else staged
    props = {"datetime": "2023-12-31T00:00:00Z"}
    if shared:
        props.update(SHARED)
    props.update(publish(staged))
    props.update(dict(props_extra))
    if exts is None:
        exts = list(OTHER_EXTS)
        if any(k.startswith("processing:") for k in props):
            exts.append(PROCESSING_EXT)
    assets = {}
    if cog:
        d = base / item_id
        d.mkdir(parents=True, exist_ok=True)
        name = "transition_2017_2023.tif"
        tags = {f"NGE_{f.upper()}": str(v) for f, v in staged.items() if v is not None}
        nulls = sorted(f for f in PROV_FIELDS if staged.get(f) is None)
        if nulls:
            tags["NGE_PROVENANCE_NULL"] = ",".join(nulls)
        if shared:
            tags.update({k.upper(): str(v) for k, v in SHARED.items()})
        tags.update(dict(tags_override))
        # Removal is by POPPING the key, never by writing None: measured 2026-10-13,
        # `update_tags(X=None)` writes the literal string "None", so a None override tests
        # the value-differs path and leaves the missing-tag direction uncovered. Only `""`
        # is dropped on write, which is the absence encoding 02_raster_tag.py relies on.
        for key in tags_drop:
            tags.pop(key, None)
        with rasterio.open(d / name, "w", driver="GTiff",
                           width=1, height=1, count=1, dtype="uint8") as ds:
            ds.write(np.zeros((1, 1), dtype="uint8"), 1)
            ds.update_tags(**tags)
        payload = (d / name).read_bytes()
        assets["transition_2017_2023"] = {
            "href": f"https://example.invalid/{item_id}/{name}",
            "type": pystac.MediaType.COG,
            "file:checksum": "1220" + hashlib.sha256(payload).hexdigest(),
            "file:size": len(payload),
            **dict(asset_extra),
        }
    (base / f"{item_id}.json").write_text(json.dumps(
        {"type": "Feature", "id": item_id, "stac_extensions": exts,
         "properties": props, "assets": assets}))


def tree(items) -> pathlib.Path:
    base = pathlib.Path(tempfile.mkdtemp(prefix="prov_fields_"))
    for kwargs in items:
        write_item(base, **kwargs)
    return base


def without(*fields) -> dict:
    return {f: (None if f in fields else v) for f, v in STAGED.items()}


NONE_STAGED = {f: None for f in PROV_FIELDS}
# The populations the catalogue carries, re-taken on the v2.0.0 build (#89): 18 items with all
# twelve, 5 missing only link_run_uid (kotl, larl, sloc, dunc, mcgr), and 0 with none. A
# fixture that covered only the first two would never reach the all-absent arms, which is where
# the NGE_PROVENANCE_NULL derivation and the conditional extension both live.
#
# WHEN THESE ARE RE-TAKEN (`prov_census-measure.R` prints them grouped and named), the
# all-absent population STAYS, whatever the measurement says — which is exactly what happened
# here: the live count went to zero when the whole-network runs gave mcgr and pine records, and
# the two fixture items stay anyway, because a literal re-take would delete the only fixture
# reaching those two arms. The populations exercise shapes the catalogue CAN hold; the live
# count of each is the reason the first two are sized as they are, not a reason to drop one to
# zero. So the fixture is 25 items and 23 traced, where the catalogue is 23 and 23.
def catalogue() -> list[dict]:
    items = [{"item_id": f"full{i:02d}_ch_ff04"} for i in range(18)]
    items += [{"item_id": f"part{i:02d}_bt_ff04", "staged": without("link_run_uid")}
              for i in range(5)]
    items += [{"item_id": f"none{i:02d}_ch_ff04", "staged": NONE_STAGED} for i in range(2)]
    return items


# --- the literals themselves -----------------------------------------------------------

print("the literals")
# Every case below reads the census, so what it says is asserted rather than assumed.
#
# These three numbers are PRODUCED by `scripts/prov_census-measure.R` (#82) — the one script in
# `scripts/` not named `-check`, because it makes an expectation rather than asserting one. Run it
# on the tree the release is cut from; it prints the floor, `PROV_CENSUS` and the populations
# below in one block. They are NOT derived from each other here on purpose: deriving the fixture
# from `PROV_CENSUS` would make the arm just below assert the literal against itself. The join is
# that one command prints all three, which the static arm further down holds in place.
expect_clean("PROV_CENSUS matches the live catalogue measured for this release",
             [] if (PROV_CENSUS["link_run_uid"] == 18
                    and {PROV_CENSUS[f] for f in PROV_FIELDS if f != "link_run_uid"} == {23})
             else [f"PROV_CENSUS is {PROV_CENSUS}"])


def _drift_msg(live_rescoped: bool = False):
    """`only_preflight.main`'s refusal message, or None — the arm, driven end to end.

    Through `main()` and not `metric_drift()` alone: the value arm is only a guard if main
    REACHES it before the provenance comparison, and that ordering is the thing that was
    missing. stdin is the live document, as the release pipes it.

    `live_rescoped` picks which side of the window the live item sits on. False is the real
    pre-v2.1.0 shape — measured 2026-10-19, 0 of the 23 live items carried a `*_footprint_*`
    key — and True is every item after that release, where a moved figure is an ordinary
    re-run and must NOT refuse.
    """
    item = {"type": "Feature", "id": "aaaa_ch_ff04",
            "properties": dict(SHARED, **{"datetime": "2023-12-31T00:00:00Z"})}
    live = json.loads(json.dumps(item))
    if not live_rescoped:
        for name in op.FOOTPRINT_PROPERTIES:
            live["properties"].pop(name, None)
    live["properties"]["floodplain_ff04_km2"] = SHARED["floodplain_ff04_km2"] + 1.0
    d = pathlib.Path(tempfile.mkdtemp(prefix="prov_fields_only_"))
    try:
        (d / "built.json").write_text(json.dumps(item))
        (d / "bucket.json").write_text(json.dumps(item))
        stdin = sys.stdin
        sys.stdin = io.StringIO(json.dumps(live))
        try:
            op.main(["only_preflight.py", str(d / "built.json"), str(d / "bucket.json")])
            return None
        except SystemExit as e:
            return e.code
        finally:
            sys.stdin = stdin
    finally:
        shutil.rmtree(d)


def literal(path: pathlib.Path, name: str):
    """A module-level literal, read statically — the two copies of the map cannot import."""
    for node in ast.parse(path.read_text()).body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, "id", None) == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise SystemExit(f"{path.name}: no module-level literal {name}")


# EVERY text-presence arm below reads R CODE with its comments removed, because the defect they
# all share is that the token being pinned also appears in prose — and the prose is usually a
# comment explaining why the code must stay as it is, so a regression deletes the code and
# leaves the explanation. Two instances were measured in review, one in each arm: the paste
# block passed with the `cat()` it pins deleted (this file's name sat in a nearby comment), and
# the mirror arm could not fire at all (`area[["targets"]]` is a comment in both files).
#
# Quote-aware rather than whole-line, which is the strictly harder half and was the second
# instance: a whole-line filter leaves `cat("x")  # for prov_fields-check.py` satisfying the
# arm, while a cut at the first `#` would destroy `cat("# scripts/...")`, which is the line the
# paste arm has to see. So the cut is at the first `#` OUTSIDE quotes, which keeps the one and
# removes the other.
def _code_only(text: str, word_start: bool = False) -> str:
    """Source with comments removed; a `#` inside a string literal is never a comment.

    `word_start` is the shell rule: a comment begins at an unquoted `#` only at the start of a
    word, so `${tag#v}` survives (seven of those in catalogue_release.sh, measured) while a
    trailing ` # note` does not. R has no such expansion, so there any unquoted `#` starts a
    comment.
    """
    out = []
    for line in text.splitlines():
        quote = None
        esc = False
        cut = len(line)
        for i, ch in enumerate(line):
            if esc:
                esc = False
            elif quote and ch == "\\" and quote == '"':
                esc = True
            elif quote:
                if ch == quote:
                    quote = None
            elif ch in "\"'":
                quote = ch
            elif ch == "#" and (not word_start or i == 0 or line[i - 1] in " \t"):
                cut = i
                break
        out.append(line[:cut])
    return "\n".join(out)


# The publish-side copies of the field list are deliberately not shared (a guard that imports
# the value it checks is x == x), so something has to join them. test_pipeline.R joins staging
# to the item, by reading the data; the assertions below join the writer, the COG tagger, this
# validator and the release preflight — the first two by parsing, the third by importing it. A
# field dropped from BOTH sides of a pair is invisible to every runtime arm.
_create_props = literal(ROOT / "scripts" / "item_create.py", "PROV_PROPERTIES")
_create_software = literal(ROOT / "scripts" / "item_create.py", "PROV_SOFTWARE")
_tag_fields = literal(ROOT / "scripts" / "02_raster_tag.py", "PROV_FIELDS")
expect_clean("item_create.py and item_validate.py publish the same map",
             [] if (_create_props == PROV_PROPERTIES
                    and {k: tuple(v) for k, v in _create_software.items()} == PROV_SOFTWARE)
             else [f"item_create.py says {_create_props} / {_create_software}"])
expect_clean("02_raster_tag.py tags exactly the fields the map publishes",
             [] if set(_tag_fields) == set(PROV_FIELDS)
             else [f"02_raster_tag.py tags {sorted(set(_tag_fields) ^ set(PROV_FIELDS))} "
                   f"differently"])
# The same join for the SHARED (non-provenance) half, which had none — and needs one more than
# the provenance half does, because check_cog_tags is asymmetric for these names. Its `managed`
# set is `want | {tags starting NGE_} - bridged`, and 02_raster_tag.py writes the shared fields
# UNPREFIXED (`f.upper()`), so a shared tag present in a COG with no entry in
# SHARED_TAG_PROPERTIES falls in neither half and is invisible at runtime. For the NGE_ family
# the union makes the check symmetric; here this static arm is the only thing watching the add
# direction.
_tag_shared = literal(ROOT / "scripts" / "02_raster_tag.py", "SHARED_FIELDS")
expect_clean("02_raster_tag.py tags exactly the shared properties item_validate declares",
             [] if set(_tag_shared) == SHARED_TAG_PROPERTIES
             else [f"02_raster_tag.py and item_validate.py disagree on "
                   f"{sorted(set(_tag_shared) ^ SHARED_TAG_PROPERTIES)}"])
# The net-identity tolerance, duplicated across the language boundary: `item_validate.py` names
# it METRIC_NET_TOLERANCE and `test_pipeline.R` can only hardcode the number, because R cannot
# import it. The R comment claims they are the same constant, so something has to hold them
# there. The direction that matters is silent both ways — a looser R arm passes a build the
# release then refuses, a tighter one fails a build that is fine.
#
# Read from R CODE with comments stripped, for the reason `_code_only` gives: the number also
# appears in the comment that explains why it must stay, so a regression that deletes the code
# and leaves the prose would still match a naive grep.
_tp_code = _code_only((ROOT / "scripts" / "test_pipeline.R").read_text())
# Both nets, so a change applied to one arm and not the other is caught too. The count is the
# assertion: any OTHER `<= <number>` in that file would have to be this same number to pass,
# and the two that are there are the net identities.
_tp_tols = re.findall(r"meta\$net[A-Za-z_]*\)\s*<=\s*([0-9]*\.?[0-9]+)\)", _tp_code)
expect_clean("test_pipeline.R's two net tolerances are item_validate.METRIC_NET_TOLERANCE",
             [] if _tp_tols == [str(METRIC_NET_TOLERANCE)] * 2
             else [f"test_pipeline.R's net arms read {_tp_tols}, expected two copies of "
                   f"{METRIC_NET_TOLERANCE} (item_validate.METRIC_NET_TOLERANCE)"])

# The fifth copy of the fact: `only_preflight.py`, which canonicalises a live item and a build
# into staged field names for `catalogue_release.sh --only`. IMPORTED, not parsed — until #74's
# round 4 it was an inline `python3 -c` program inside a double-quoted shell string and had to
# be sliced out of the script, which is how three separate shell-expansion defects reached it.
# Comparing two independently declared maps is the join; it is not the x == x hazard, which is
# a guard importing the value it asserts.
expect_clean("only_preflight.py canonicalises through the same map, inverted",
             [] if op.NEW == {v: k for k, v in PROV_PROPERTIES.items()}
             else [f"the preflight maps {op.NEW}"])
expect_clean("...and the same software entries",
             [] if {k: tuple(v) for k, v in op.SOFTWARE.items()} == PROV_SOFTWARE
             else [f"the preflight maps {op.SOFTWARE}"])
expect_clean("...over the published prefixes plus the retired one",
             [] if set(op.PREFIXES) == {f"{p}:" for p in PROV_PREFIXES} | {"nge:"}
             else [f"the preflight scans {sorted(op.PREFIXES)}"])
# The sixth copy, and the only one about the UNPREFIXED figures (#98): the preflight's own
# refusal arm, which the four prefixes above cannot reach.
expect_clean("...and refuses on exactly the metric properties item_validate guards",
             [] if set(op.METRIC_PROPERTIES) == set(METRIC_PROPERTIES_V)
             else [f"the preflight guards "
                   f"{sorted(set(op.METRIC_PROPERTIES) ^ set(METRIC_PROPERTIES_V))} "
                   f"differently"])
expect_clean("a build that does not move a figure is not refused",
             [] if not op.metric_drift({"floodplain_ff04_km2": 2.0, "net_ha": -1.0},
                                       {"floodplain_ff04_km2": 2, "net_ha": -1.0})
             else ["an unchanged pair read as drift"])
expect_problem("a redefined figure IS refused while the live item predates the contract",
               [str(e) for e in [_drift_msg()] if e], "floodplain_ff04_km2")
# The expiry, which is the half that stops this being over-refusal: once the live item carries
# the footprint siblings, a moved figure is an ordinary upstream re-run — the case --only
# exists for, and the case the `gained` arm cites by name.
expect_clean("...and goes quiet once the live item carries the footprint siblings",
             [] if _drift_msg(live_rescoped=True) is None
             else [f"refused a re-run: {_drift_msg(live_rescoped=True)}"])
# And that the release still CALLS it. Extracting the program removed a whole class of shell
# defect; reverting it to an inline `python3 -c` would bring the class back, and the three
# assertions above would keep passing against a module nothing runs.
_release = (ROOT / "scripts" / "catalogue_release.sh").read_text()
# Searched with COMMENTS removed, for the reason spelled out at `_code_only`: the token this
# pins is exactly the kind a comment quotes, and the 400-char window it searches already holds
# two comment lines. Measured in review, twice: a whole-line filter was the first fix and a
# TRAILING comment defeated it — `| python3 -c '...'  # was: | python3 scripts/only_preflight.py`
# passed an arm whose whole subject is which of those two the release runs.
_release_code = _code_only(_release, word_start=True)
expect_clean("the release path runs it rather than an inline program",
             [] if ("| python3 scripts/only_preflight.py"
                    in _release_code.split("only_prov=$(curl")[1][:400])
             else ["catalogue_release.sh does not call scripts/only_preflight.py for the "
                   "--only preflight — if the program moved back inline, bash is expanding it "
                   "again and these assertions are checking a module the release never runs"])

# --- the literals as a shape, before anything measures them (#82) ----------------------
# Two invariants over the three numbers themselves, which hold whatever build they came from —
# so they fail at PASTE time, in the commit that re-takes the census, rather than at the next
# release.
#
# The pairing is the one that matters, and it is the one way the pre-flight measurement and the
# published census can differ BY CONSTRUCTION. `link_version` and `link_sha` publish as one
# `processing:software` entry, so `prov_present()` above reads both from that single value and
# item_create.py REFUSES an item carrying one without the other rather than writing `+<sha>`
# or a bare version. A census with unequal counts for two fields of one entry therefore
# describes a tree whose build stops at item_create.py. DUNC was in exactly that state
# (`link_log: null`, `inputs.link.version` set; floodplains#133) from 2026-10-14 until the
# Columbia run of 2026-10-15T18:38Z wrote it a `link_log`, which is how this arm came to be
# written. It stays because the pair can empty again — the condition is BOTH sources empty, not
# an unresolved sha, since all 23 `all*` sections carry `inputs$link$sha: null` and publish
# because the log row supplies it — and a census taken inside one of those windows is what this
# stops being pasted as an expectation.
_uneven = [(entry, {f: PROV_CENSUS[f] for f in fields})
           for entry, fields in PROV_SOFTWARE.items()
           if len({PROV_CENSUS[f] for f in fields}) > 1]
expect_clean("fields sharing one processing:software entry carry equal census counts",
             [] if not _uneven
             else [f"{e} publishes as ONE entry but the census says {c} — item_create.py "
                   f"refuses a half-present entry, so no build can produce that pair"
                   for e, c in _uneven])

# And the floor bounds every field: it counts items carrying ANY field, so no field can be
# carried by more items than that. Not asserted as EQUALITY — a catalogue where every
# provenanced item is missing some different field has no field at the floor — but `<=` is a
# property of the two numbers, and it is the arm that catches a floor re-taken without the
# census or the reverse. Read from the release script by the same anchored pattern
# catalogue_release-check.sh uses, so an indented or overridable assignment fails here too.
_floor_m = re.search(r"^PROVENANCE_FLOOR=([0-9]+)$", _release, re.M)
expect_clean("PROVENANCE_FLOOR bounds every per-field census count",
             [] if _floor_m and max(PROV_CENSUS.values()) <= int(_floor_m.group(1))
             else ["catalogue_release.sh has no bare `PROVENANCE_FLOOR=<n>` line"]
             if not _floor_m
             else [f"the floor is {_floor_m.group(1)} and the census peaks at "
                   f"{max(PROV_CENSUS.values())} — one of the two was re-taken without the "
                   "other"])

# --- the producer of the three numbers above (#82) -------------------------------------
# A SIXTH place that has to agree about the field list, and the only one that is not a publish
# path: `prov_census-measure.R`, which produces the floor, `PROV_CENSUS` and the fixture
# populations this file hard-asserts. Text reads, because it is R and nothing here can import
# it.
#
# First, that it does not carry its own copy of either literal it reads out of 01_stage.R. A
# census taken over a copied field list would silently stop counting a field the build still
# publishes — the same defect the four arms above exist for, arriving from the one script whose
# output a human pastes into two literals.
_measure_path = ROOT / "scripts" / "prov_census-measure.R"
_measure = _measure_path.read_text() if _measure_path.exists() else ""
_measure_code = _code_only(_measure)

expect_clean("prov_census-measure.R parses its literals out of 01_stage.R rather than copying",
             [] if ('parse(file.path("scripts", "01_stage.R"))' in _measure_code
                    and 'stage_literal("PROV_FIELDS")' in _measure_code
                    and 'stage_literal("TRANSITION_SPAN")' in _measure_code
                    and "PROV_FIELDS <- c(" not in _measure_code)
             else [f"{_measure_path.name}: expected the parse-and-eval construction for both "
                   "PROV_FIELDS and TRANSITION_SPAN, and no `PROV_FIELDS <- c(` of its own"
                   if _measure
                   else "scripts/prov_census-measure.R is absent, so nothing produces the "
                        "numbers this file asserts"])


# Second, that it still PRINTS all three destinations. That one command prints them together is
# the whole join between this file's literals and `item_validate.py`'s: lose one from the block
# and a re-take moves two of three, which is the state #75 found them in.
_paste = (_measure_code.split("--- paste these")[-1]
          if "--- paste these" in _measure_code else "")
_missing_dest = [d for d in ("PROVENANCE_FLOOR", "PROV_CENSUS", "prov_fields-check.py")
                 if d not in _paste]
expect_clean("...and prints the floor, the census and this file's populations in one block",
             [] if _paste and not _missing_dest
             else ["prov_census-measure.R's paste block names none of them"] if not _paste
             else [f"prov_census-measure.R's paste block does not name {_missing_dest}"])

# Third, the weakest of the three and the only cover on a real duplication: that script MIRRORS
# 01_stage.R's roster walk rather than sharing one (#90 tracks extracting an `fp_roster.R`),
# and the three expressions below are where a divergence would change which items are counted —
# the `[[`-not-`$` target read, the anchored classified pattern, and the directory-only raster
# skip. Presence in both files' CODE, never absence: both files' comments quote `area$targets`
# while explaining why it must not be used, so an absence test would read the explanation as the
# defect. The target read is pinned as the whole assignment, because the subscript alone is what
# those comments quote — measured in review: with the arm reading the bare subscript, rewriting
# BOTH files' code to `area$targets` left 49 assertions and 0 failures.
_stage_code = _code_only((ROOT / "scripts" / "01_stage.R").read_text())
_mirror = ['targets <- area[["targets"]]', r"^classified_[0-9]{4}\\.tif$",
           "dir.exists(src_rasters)"]
_broken = [e for e in _mirror if e not in _stage_code or e not in _measure_code]
expect_clean("...and mirrors the three roster expressions that decide what is counted",
             [] if not _broken
             else [f"01_stage.R and prov_census-measure.R no longer share {_broken} — the walk "
                   "has diverged, so the census is of a different set than the build stages"])

# --- controls --------------------------------------------------------------------------

print("controls (a guard that has never passed is as untested as one that never fired)")
b = tree(catalogue())
problems, traced, seen, per_section, census = check_provenance(b, floor=23)
expect_clean("the three live populations pass the census and the floor", problems)
expect_clean("...with 23 of 25 carrying provenance",
             [] if (traced, seen) == (23, 25) else [f"traced={traced} seen={seen}"])
expect_clean("...and every section counted",
             [] if per_section == {"network": 23, "floodplain": 23, "landcover": 23}
             else [str(per_section)])
# The per-field counts come back whether or not they were asserted: they are what the next
# release reads PROV_CENSUS from, so a release that cannot see them cannot set it.
expect_clean("...and the per-field census is returned for the operator to read",
             [] if census == PROV_CENSUS else [str(census)])
expect_clean("...no undeclared prefixes", check_field_prefixes(b))
expect_clean("...and the processing extension paired on every item", check_processing_stamp(b))
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "cog": True},
          {"item_id": "none_ch_ff04", "staged": NONE_STAGED, "cog": True}])
expect_clean("COG tags agree with the item, with and without provenance", check_cog_tags(b))
shutil.rmtree(b)

# --- the declared-key arm --------------------------------------------------------------

print("declared keys: what survives of the retired key-set equality")
b = tree([{"item_id": "aaaa_ch_ff04", "props_extra": {"landcover:sourc": "io-lulc"}}])
problems, *_ = check_provenance(b)
expect_problem("a typo under an ALLOWED prefix is refused", problems,
               "does not declare")
expect_clean("...and the prefix table alone cannot see it", check_field_prefixes(b))
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "props_extra": {"processing:level": "L3"}}])
problems, *_ = check_provenance(b)
expect_problem("a processing: field this build does not publish is refused", problems,
               "does not declare")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04",
           "props_extra": {SOFTWARE_PROPERTY: {**publish(STAGED)[SOFTWARE_PROPERTY],
                                               "gdal": "3.12.0"}}}])
problems, *_ = check_provenance(b)
expect_problem("an undeclared software entry name is refused", problems,
               "undeclared entry name")
shutil.rmtree(b)

b = pathlib.Path(tempfile.mkdtemp(prefix="prov_fields_"))
problems, *_ = check_provenance(b, floor=23)
expect_problem("an empty tree is not a pass", problems, "was not actually checked against")
shutil.rmtree(b)

# --- the census ------------------------------------------------------------------------

print("the census: the arm that replaced set equality")
# The uniform loss #23 could not see and #74 would otherwise have re-opened: EVERY item loses
# the same field, so nothing is left to compare against.
b = tree([dict(kw, staged=without("link_run_uid", "landcover_key"))
          if "staged" not in kw else kw for kw in catalogue()])
problems, *_ = check_provenance(b, floor=23)
expect_problem("a field lost on every item is refused", problems,
               "PROV_CENSUS says 23")
expect_clean("...and NOT on a rebuild, where no release expectation applies",
             check_provenance(b, floor=None)[0])
shutil.rmtree(b)

# One item, one field: the shape the floor and the section counts both wave through.
items = catalogue()
items[0] = {"item_id": "full00_ch_ff04", "staged": without("landcover_key")}
b = tree(items)
problems, traced, *_ = check_provenance(b, floor=23)
expect_problem("one field lost on ONE item is refused", problems, "PROV_CENSUS says 23")
expect_clean("...which the item-level floor cannot see on its own",
             [] if traced == 23 else [f"traced={traced}"])
shutil.rmtree(b)

# A whole section lost on every item — passed every arm before #74, because the floor was
# still met by the surviving sections and the per-section counts were only printed.
b = tree([dict(kw, staged=without("landcover_source", "landcover_collection",
                                  "landcover_stac_url", "landcover_key",
                                  "landcover_item_hash", "drift_version",
                                  "produced_datetime"))
          if "staged" not in kw else kw for kw in catalogue()])
problems, *_ = check_provenance(b, floor=23)
expect_problem("a whole section lost on every item is refused", problems, "PROV_CENSUS says")
shutil.rmtree(b)

b = tree(catalogue() + [{"item_id": "zzzz_ch_ff04"}])
problems, *_ = check_provenance(b, floor=23)
expect_problem("a census behind the build is refused, naming the number to set", problems,
               "set it to 24")
shutil.rmtree(b)

print("the floor, beside the census rather than derived from it")
b = tree(catalogue())
expect_problem("a floor behind the build is refused", check_provenance(b, floor=22)[0],
               "the floor is behind the build")
expect_problem("a floor ahead of the build is refused", check_provenance(b, floor=24)[0],
               "the release floor is 24")
shutil.rmtree(b)

# --- the prefix table ------------------------------------------------------------------

print("the prefix table: a resurrected nge: key")
b = tree([{"item_id": "aaaa_ch_ff04", "props_extra": {"nge:link_run_uid": "u"}}])
expect_problem("an nge: property is refused", check_field_prefixes(b),
               "is not declared in FIELD_PREFIXES")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "cog": True, "asset_extra": {"nge:kept": "same"}}])
expect_problem("an nge: ASSET field is refused too", check_field_prefixes(b),
               "is not declared in FIELD_PREFIXES")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "exts": list(OTHER_EXTS)}])
expect_problem("a processing: field with the extension absent is refused",
               check_field_prefixes(b), "does not declare")
shutil.rmtree(b)

# --- the processing extension ----------------------------------------------------------

print("the processing extension, both directions")
b = tree([{"item_id": "aaaa_ch_ff04", "exts": list(OTHER_EXTS)}])
expect_problem("...and reported as half-applied", check_processing_stamp(b),
               "processing extension half-applied")
shutil.rmtree(b)

b = tree([{"item_id": "none_ch_ff04", "staged": NONE_STAGED,
           "exts": OTHER_EXTS + [PROCESSING_EXT]}])
expect_problem("the extension declared with no processing: field is refused",
               check_processing_stamp(b), "no processing: field")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "props_extra": {SOFTWARE_PROPERTY: {}}}])
expect_problem("an empty software map is refused", check_processing_stamp(b),
               "is empty")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04",
           "props_extra": {SOFTWARE_PROPERTY: {"link": "+689146867a5f",
                                               "flooded": "0.5.0", "drift": "0.8.0"}}}])
expect_problem("a half-present version+sha pair is refused", check_processing_stamp(b),
               "expected <version>+<sha>")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04",
           "props_extra": {SOFTWARE_PROPERTY: {"link": "0.50.0+abc", "flooded": 5,
                                               "drift": "0.8.0"}}}])
expect_problem("a non-string entry value is refused", check_processing_stamp(b),
               "expected a non-empty string")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04",
           "staged": {**STAGED, "produced_datetime": "2026-09-03T07:39:25"}}])
expect_problem("a datetime with no UTC designator is refused", check_processing_stamp(b),
               "pins a UTC designator")
shutil.rmtree(b)

# --- the COG tags ----------------------------------------------------------------------

print("the COG tags, bridged through the map")
for tag in ("NGE_LINK_VERSION", "NGE_LINK_SHA"):
    b = tree([{"item_id": "aaaa_ch_ff04", "cog": True, "tags_override": {tag: "tampered"}}])
    expect_problem(f"{tag} perturbed is caught by the reassembly", check_cog_tags(b),
                   "reassemble to")
    shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "cog": True,
           "tags_override": {"NGE_PRODUCED_DATETIME": "2020-01-01T00:00:00Z"}}])
expect_problem("a plain tag perturbed is caught by the diff", check_cog_tags(b),
               "GDAL tags disagree")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "cog": True,
           "tags_drop": ("NGE_LANDCOVER_KEY",)}])
# The "tag went missing" direction: the item publishes the property, the COG carries no tag.
# `want` holds it and `got` does not, so the diff reports it against a tag of None.
expect_problem("a tag missing from the COG is caught", check_cog_tags(b),
               "GDAL tags disagree")
shutil.rmtree(b)

b = tree([{"item_id": "none_ch_ff04", "staged": NONE_STAGED, "cog": True,
           "tags_drop": ("NGE_PROVENANCE_NULL",)}])
# And the other direction on the one tag the all-absent items carry: dropped entirely rather
# than overwritten, which is what a 02 that stopped writing it would produce.
expect_problem("NGE_PROVENANCE_NULL missing from an all-absent item is caught",
               check_cog_tags(b), "NGE_PROVENANCE_NULL")
shutil.rmtree(b)

# The arm that a mechanical port of the old `v is None` derivation silences: with no null
# properties left to find, NGE_PROVENANCE_NULL would never enter `want` and this tag could
# hold anything. It is also the only PROVENANCE tag those two items carry — the shared
# identity and metric tags are there as on any other item.
b = tree([{"item_id": "none_ch_ff04", "staged": NONE_STAGED, "cog": True,
           "tags_override": {"NGE_PROVENANCE_NULL": "garbage"}}])
expect_problem("NGE_PROVENANCE_NULL overwritten on an all-absent item is caught",
               check_cog_tags(b), "NGE_PROVENANCE_NULL")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "cog": True, "shared": False}])
expect_problem("a missing shared property is reported as unverifiable", check_cog_tags(b),
               "so its GDAL tag cannot be verified")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04"}])
expect_problem("a tree with no COG asset is not a pass", check_cog_tags(b),
               "no COG assets compared")
shutil.rmtree(b)

# --- the metric scopes (#98) -----------------------------------------------------------
#
# The SHARED fixture is built to SATISFY check_metric_scopes, so without these cases the
# newest guard in the release path would be the only one with no restore-the-bug proof —
# exactly what this file exists to prevent. `census=False` on the per-item cases so only the
# arm under test can speak; the census case needs the default.
print("\nthe metric scopes (#98)")

_inw, _fp = METRIC_SCOPE_PAIRS[1]   # floodplain_ff04_km2 / floodplain_ff04_footprint_km2
b = tree([{"item_id": "aaaa_ch_ff04",
           "props_extra": {_inw: SHARED[_fp], _fp: SHARED[_inw]}}])
expect_problem("a swapped scope pair is refused",
               check_metric_scopes(b, census=False)[0], "look swapped")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "props_extra": {"net_ha": SHARED["net_ha"] + 5}}])
expect_problem("a net inconsistent with its own scope is refused",
               check_metric_scopes(b, census=False)[0], "different row set")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "props_extra": {"gross_gain_footprint_ha": 99.0}}])
expect_problem("...and the footprint scope's net is checked too, not just the in_wsg one",
               check_metric_scopes(b, census=False)[0], "net_footprint_ha")
shutil.rmtree(b)

# The one that matters: an in_wsg filter dropped in staging publishes two IDENTICAL scopes on
# every item, which satisfies every per-item arm above. Only the census can see it.
b = tree([{"item_id": f"same{i:02d}_ch_ff04",
           "props_extra": {inw: SHARED[fp] for inw, fp in METRIC_SCOPE_PAIRS}}
          for i in range(3)])
expect_problem("two identical scopes on every item is refused by the census",
               check_metric_scopes(b)[0], "straddle their group line")
shutil.rmtree(b)

# And the measurement is returned whether or not it asserted, because that is what a release
# sets the literal from.
b = tree([{"item_id": "aaaa_ch_ff04"}])
_, _straddle, _seen = check_metric_scopes(b, census=False)
expect_clean("the straddle counts are returned even when not asserted",
             [] if (_seen == 1 and set(_straddle) == set(METRIC_SCOPE_CENSUS)
                    and set(_straddle.values()) == {1})
             else [f"straddle={_straddle} seen={_seen}"])
shutil.rmtree(b)

print(f"\n{N} assertions, {FAILS} failed")
sys.exit(FAILS)
