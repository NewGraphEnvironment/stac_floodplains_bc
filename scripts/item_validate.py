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


def check_provenance(base: Path) -> list[str]:
    """Verify every item carries every `nge:` provenance KEY. Null values are fine.

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
    """
    problems: list[str] = []
    seen = 0
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        seen += 1
        found = {k for k in doc.get("properties", {}) if k.startswith("nge:")}
        if found != REQUIRED_NGE_PROPERTIES:
            problems.append(
                f"{doc['id']}: nge: property set differs from the declared contract — "
                f"missing {sorted(REQUIRED_NGE_PROPERTIES - found) or 'none'}, "
                f"undeclared {sorted(found - REQUIRED_NGE_PROPERTIES) or 'none'}")
    # Zero items is not a pass. The loop above would report nothing at all for an empty
    # or wrongly-pointed directory, which reads identically to "every item checked out".
    if seen == 0:
        problems.append(
            f"no items found under {base}/*.json — the provenance contract was not "
            f"actually checked against anything")
    return problems


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


def check_checksums(base: Path) -> list[str]:
    """Verify every asset's `file:checksum` and `file:size` against the file on disk.

    Assets live at `<base>/<item_id>/<name>`, and the S3 href's basename is that
    same name — so the local path is derivable from the href without extra state.

    Returns a list of human-readable problems (empty when everything matches).
    """
    problems: list[str] = []
    asset_keys: dict[str, set] = {}
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc["id"]
        asset_keys[item_id] = set(doc.get("assets", {}))
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
    # Every item is built from the same template, so the key sets must be identical;
    # comparing them catches a dropped asset without hardcoding a count here.
    if asset_keys:
        expected_keys = max(asset_keys.values(), key=len)
        if not expected_keys:
            problems.append("no assets on any item — nothing was actually verified")
        for item_id, keys in sorted(asset_keys.items()):
            if keys != expected_keys:
                problems.append(
                    f"{item_id}: asset set differs from the other items — missing "
                    f"{sorted(expected_keys - keys) or 'none'}, "
                    f"unexpected {sorted(keys - expected_keys) or 'none'}")
    return problems


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base", default="data/stac", type=Path,
                   help="directory holding <item_id>.json + collection.json")
    p.add_argument("--raw", default="data/raw", type=Path,
                   help="staging dir used to derive the expected item count")
    p.add_argument("--expect", type=int, default=None,
                   help="expected item count (default: number of data/raw/*/meta.json)")
    args = p.parse_args()

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
                stamp_problem = check_version_stamp(doc)
                if stamp_problem:
                    failed.append((path.name, stamp_problem))
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

    # --- file extension: do the published checksums describe the bytes we ship? ---
    #
    # This re-reads every asset (~670 MB, ~2.5s). That cost buys the only thing the
    # schema cannot give us: the file extension's pattern is `^[a-f0-9]+$`, so a bare
    # sha256 with no multihash prefix validates cleanly, and so does a well-formed
    # checksum of the wrong bytes. A guard that only checked the field was present
    # would be decoration on an issue whose entire subject is byte integrity.
    bad = check_checksums(args.base)
    if bad:
        print(f"FAILED: {len(bad)} asset checksum/size problem(s)", file=sys.stderr)
        for msg in bad:
            print(f"  {msg}", file=sys.stderr)
        return 1

    # --- run provenance: does every item carry the declared nge: contract? ---
    missing_prov = check_provenance(args.base)
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
    print(f"provenance: {len(REQUIRED_NGE_PROPERTIES)} nge: properties on every item, "
          f"COG tags agree")

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
