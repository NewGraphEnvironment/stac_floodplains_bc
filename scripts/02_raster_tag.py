"""02_raster_tag.py — embed publish metadata as GDAL tags on the staged rasters.

Runs BETWEEN 01_stage.R and 03_cog.py, on `data/raw/<item_id>/*.tif` — deliberately
before the COG conversion, not after it (#33). Tagging a finished COG in place
requires IGNORE_COG_LAYOUT_BREAK, and that flag is not a warning suppressor: the
write moves the main IFD to the end of the file, so a client has to fetch nearly
the whole object to read a header. Measured at 98.9% and 99.6% on this
collection's own assets before the reorder.

Tagging the staged raster instead costs nothing, because 03_cog.py's GDAL CreateCopy
carries every tag, the colour table, the band description and the class-label RAT through
to the COG and lays the bytes out correctly (measured). The absence of
IGNORE_COG_LAYOUT_BREAK below is the tell that the ordering is right.

Since #34/#35 this script also AUTHORS those labels, writing a PAM `.aux.xml` beside each
staged raster that 03 then absorbs into the `.tif`. See write_rat_sidecar().

For each item it reads `data/raw/<item_id>/meta.json` (written by 01_stage.R) and
tags the rasters with the WSG identity, scenario, run provenance, and the tree
loss/gain/net figures derived from the transition layer. Classified rasters also
get the year they represent; the transition raster gets its span.

Tags are visible in QGIS: Layer Properties -> Metadata tab.

Note the consequence of running before the COG step rather than after it: this script
alone no longer repairs `data/stac`. Correcting a number in meta.json and re-running only
this step leaves the published COGs carrying the old tags, because they are rebuilt by
03_cog.py and not touched here. Re-run 03 as well — or just `run_pipeline.sh`.
`item_validate.py`'s tag contract is what catches it if you forget.

The plain `"r+"` open below is also a tripwire, deliberately. If `floodplains` ever starts
emitting COGs upstream, GDAL will REFUSE the update rather than silently breaking their
layout — which is the failure this whole reorder exists to prevent, and the safe direction
to fail in.
"""

import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

import rasterio

RAW_DIR = Path("data/raw")
CLASSES_PATH = RAW_DIR / "classes.json"

# The one cartographic literal in this repo (#35). Everything else about the legend is
# generated from drift's table; this is the recessive colour for the no-change diagonal,
# which carries ~91% of the transition raster's valid cells and would otherwise swamp the
# signal. drift supplies no such colour because "no change" is not a land-cover class, so
# there is nothing upstream to ferry. If a future drift grows a transition palette, this
# constant and TRANSITION_RAT below are what it replaces.
NO_CHANGE_RGB = (217, 217, 217)   # #d9d9d9, neutral light grey

# GDAL RAT field usages. QGIS resolves a RAT by USAGE, not by column name, so getting
# these wrong yields a table that displays in gdalinfo and renders as nothing — labels
# present, colours ignored, and every other guard green. GFU_MinMax=5, Name=2,
# Red=6, Green=7, Blue=8, Alpha=9.
RAT_FIELDS = [
    ("value", "Integer", "0", "MinMax", "5"),
    ("class_name", "String", "2", "Name", "2"),
    ("red", "Integer", "0", "Red", "6"),
    ("green", "Integer", "0", "Green", "7"),
    ("blue", "Integer", "0", "Blue", "8"),
    ("alpha", "Integer", "0", "Alpha", "9"),
]

# Scalar tags shared by every asset in a WSG.
SHARED_FIELDS = [
    "wsg", "species", "scenario", "region",
    "floodplain_ff02_km2", "floodplain_ff04_km2", "floodplain_ff06_km2",
    "gross_loss_ha", "gross_gain_ha", "net_ha",
]

# Run provenance (#17), mirrored so a downloaded COG is self-describing. Same field
# names as 01_stage.R's PROV_FIELDS; the tag key is NGE_<FIELD>, built from the
# unprefixed name.
#
# The key must NOT carry the `nge:` STAC prefix. Measured: a colon in a GDAL tag key is
# parsed as a namespace separator, so `update_tags(**{"NGE:LINK_RUN_UID": "abc"})`
# round-trips as key `NGE` with value `LINK_RUN_UID=abc`. Eleven prefixed fields would
# collapse into ONE `NGE` tag holding whichever was written last — a uniform, silent
# loss on every COG.
PROV_FIELDS = [
    "link_run_uid", "link_config_sha256", "link_sha", "link_version",
    "flooded_version", "drift_version", "produced_datetime",
    "landcover_source", "landcover_collection", "landcover_stac_url", "landcover_key",
]
# One companion tag naming what was looked for and not found, so a COG carries the
# same "we looked and there was none" signal the STAC item does. Without it a
# provenance-less COG is indistinguishable from one this pipeline never touched.
PROV_NULL_TAG = "NGE_PROVENANCE_NULL"


def shared_tags(meta: dict) -> dict:
    # Same empty-string idiom as provenance_tags(): omitting a None field instead would
    # leave nothing to write, so a value that went real -> null could never be CLEARED
    # from a COG that already carried it (update_tags merges).
    return {f.upper(): ("" if meta.get(f) is None else str(meta[f])) for f in SHARED_FIELDS}


def provenance_tags(meta: dict) -> dict:
    """Provenance tags for one item. A null value is encoded as the EMPTY STRING.

    GDAL metadata is string-only and has no null, so every candidate encoding either
    lies or is refused: `str(None)` writes the literal `'None'`, and `'NA'`/`'null'`
    round-trip as ordinary strings a consumer cannot tell from a real value.

    The empty string is the one honest option, because GDAL treats it as absence in
    both directions — measured: writing `""` to a fresh key leaves the key absent on
    read, and writing `""` over an EXISTING key deletes it. That second half is what
    makes this the clearing mechanism as well as the encoding, which matters because
    `update_tags()` merges rather than replaces (also measured), so a stale tag would
    otherwise survive a rewrite.

    A key absent from meta.json raises rather than defaulting: 01_stage.R writes every
    field on every item, so absence is a staging bug and not a null.
    """
    tags = {f"NGE_{f.upper()}": ("" if meta[f] is None else str(meta[f]))
            for f in PROV_FIELDS}
    nulls = sorted(f for f in PROV_FIELDS if meta[f] is None)
    tags[PROV_NULL_TAG] = ",".join(nulls)
    return tags


def load_classes() -> list[dict]:
    """The land-cover table 01_stage.R ferried from `drift::dft_class_table("io-lulc")`.

    Raises rather than defaulting to an empty table. An empty one would produce a RAT with
    no rows, which is the uniform defect nothing downstream can see: every item would lose
    the same labels, the asset count would still be right, and the STAC classification
    extension validates an item carrying zero classes (measured).
    """
    if not CLASSES_PATH.is_file():
        raise SystemExit(
            f"{CLASSES_PATH} is missing — 01_stage.R writes it; re-run staging")
    doc = json.loads(CLASSES_PATH.read_text())
    classes = doc.get("classes")
    if not classes:
        raise SystemExit(f"{CLASSES_PATH} carries no classes")
    return classes


def _rgb(color: str) -> tuple[int, int, int]:
    """'#419bdf' -> (65, 155, 223). 01_stage.R has already asserted the #RRGGBB shape."""
    return tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))


def classified_rat(classes: list[dict]) -> list[tuple]:
    """One row per land-cover class: the code as published, its name and its colour."""
    return [(c["code"], c["class_name"], *_rgb(c["color"]), 255) for c in classes]


def transition_rat(classes: list[dict]) -> list[tuple]:
    """One row per `from -> to` pair, encoded `from * 1000 + to` as `drift` produces it.

    The FULL cross product, not the codes observed in one watershed group: the RAT
    documents the encoding, which is a property of drift's scheme rather than of any
    item's data. Deriving it from observed values would make every item's RAT differ and
    would cost a full read of a ~677M-cell raster per item.

    That uniformity is deliberate and it has a price — a cross-item consistency check
    cannot see a defect that hits every item the same way. item_validate.py pays it back
    with the check uniformity cannot give: every code PRESENT in the raster has a row.

    Colour is the destination class's, so a legend reads change by what the ground became.
    The no-change diagonal takes NO_CHANGE_RGB so the ~91% of cells that did not change
    recedes instead of swamping the signal (#35).
    """
    rows = []
    for src in classes:
        for dst in classes:
            code = src["code"] * 1000 + dst["code"]
            label = (f"{src['class_name']} (no change)" if src["code"] == dst["code"]
                     else f"{src['class_name']} \u2192 {dst['class_name']}")
            rgb = NO_CHANGE_RGB if src["code"] == dst["code"] else _rgb(dst["color"])
            rows.append((code, label, *rgb, 255))
    return rows


def write_rat_sidecar(raster: Path, rows: list[tuple]) -> None:
    """Write a PAM `.aux.xml` carrying `rows` as a GDAL Raster Attribute Table.

    This is an INTERMEDIATE, never a published asset. 03_cog.py's CreateCopy absorbs it
    into the COG's own `GDAL_METADATA` tag (GDAL 3.12+), so the labels ship inside the
    `.tif` and a sidecar would be redundant — which matters because geoserv's titiler sets
    `CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif,.TIF,.tiff"` and could never fetch one.
    catalogue_release.sh excludes `*.aux.xml` from the sync for the same reason.

    Hand-written rather than written through GDAL: rasterio exposes no RAT API at all, and
    the GDAL Python bindings have no wheel (`uv pip install gdal` -> "no usable wheels"),
    so adding them would reopen the conda->uv blocker this repo cleared. PAM is a
    documented on-disk format; emitting it costs nothing but care.

    That care is `xml_declaration=False`, and it is load-bearing. MEASURED: GDAL's PAM
    parser SILENTLY IGNORES a sidecar carrying an `<?xml version...?>` declaration — same
    bytes otherwise, the RAT reads back with it absent and does not with it present.
    `ET.write(encoding="utf-8")` emits one by default, so the natural call is the broken
    one, and it fails in the invisible direction: the file looks perfect, the RAT never
    reaches the COG, and nothing reports it. Keeping the declaration off is checked by
    item_validate.py against the published bytes rather than trusted here.
    """
    pam = ET.Element("PAMDataset")
    band = ET.SubElement(pam, "PAMRasterBand", band="1")
    # tableType="thematic" — these are discrete classes, not a continuous ramp.
    rat = ET.SubElement(band, "GDALRasterAttributeTable", tableType="thematic")
    for i, (name, type_name, type_code, usage_name, usage_code) in enumerate(RAT_FIELDS):
        fd = ET.SubElement(rat, "FieldDefn", index=str(i))
        ET.SubElement(fd, "Name").text = name
        ET.SubElement(fd, "Type", typeAsString=type_name).text = type_code
        ET.SubElement(fd, "Usage", usageAsString=usage_name).text = usage_code
    for i, row in enumerate(rows):
        row_el = ET.SubElement(rat, "Row", index=str(i))
        for value in row:
            # ElementTree escapes &, < and > for us. Labels carry a U+2192 arrow, which
            # survives as UTF-8 into the embedded RAT (measured).
            ET.SubElement(row_el, "F").text = str(value)
    ET.ElementTree(pam).write(
        raster.with_suffix(raster.suffix + ".aux.xml"),
        encoding="utf-8", xml_declaration=False)


# Every tag key this script owns. The skip check below compares over THIS set rather
# than over the keys being written, because a key that must now be absent does not
# appear in the write dict at all — `all(existing.get(k) == v for k, v in tags.items())`
# iterates the smaller set, returns True, and the stale tag survives on a published
# asset. Reachable only when this step is re-run without 01 — 01 unlinks data/raw and
# re-copies the rasters, so a full run always tags files carrying nothing but the
# source's own AREA_OR_POINT. The guard is cheap and the failure is silent.
#
# It matters slightly MORE after #33 than before: a stale tag on a staged raster is now
# carried into the COG by terra, rather than being overwritten on the COG itself.
MANAGED_KEYS = (
    {f.upper() for f in SHARED_FIELDS}
    | {f"NGE_{f.upper()}" for f in PROV_FIELDS}
    | {PROV_NULL_TAG, "YEAR", "YEAR_FROM", "YEAR_TO"}
)
# all([]) is True, so an empty managed set would skip every COG and silently tag none.
# Assert the SOURCE lists rather than the union: the union folds in a non-empty literal
# set, so `assert MANAGED_KEYS` is a tautology that cannot fire.
assert SHARED_FIELDS and PROV_FIELDS, "a field list is empty — every COG would be skipped"


CLASSES = load_classes()
CLASSIFIED_RAT = classified_rat(CLASSES)
TRANSITION_RAT = transition_rat(CLASSES)

tagged = 0
skipped = 0
rats = 0

for meta_path in sorted(RAW_DIR.glob("*/meta.json")):
    wsg = meta_path.parent.name
    meta = json.loads(meta_path.read_text())
    base = {**shared_tags(meta), **provenance_tags(meta)}

    rasters = sorted((RAW_DIR / wsg).glob("*.tif"))
    # Zero rasters iterates nothing and reports "Tagged 0, skipped 0" — indistinguishable
    # from a clean run. 05 would catch it later as a missing asset; fail where it happened.
    if not rasters:
        raise SystemExit(f"{wsg}: staged in {RAW_DIR} but has no rasters to tag")
    for cog in rasters:
        tags = dict(base)

        # Per-asset temporal tag from the filename.
        m_year = re.search(r"classified_(\d{4})", cog.stem)
        m_span = re.search(r"transition_(\d{4})_(\d{4})", cog.stem)
        if m_year:
            tags["YEAR"] = m_year.group(1)
        elif m_span:
            tags["YEAR_FROM"] = m_span.group(1)
            tags["YEAR_TO"] = m_span.group(2)

        # The RAT sidecar is written UNCONDITIONALLY, above the skip check below, and that
        # placement is the whole point. The skip check compares GDAL TAGS; it knows nothing
        # about the sidecar, so a raster whose tags already match would keep its tags and
        # silently get no labels. MANAGED_KEYS cannot express "and the sidecar exists".
        #
        # Writing it every run is safe and cheap: the content is a pure function of
        # classes.json and the raster's role, so it is byte-stable across rebuilds.
        if m_year:
            write_rat_sidecar(cog, CLASSIFIED_RAT)
        elif m_span:
            write_rat_sidecar(cog, TRANSITION_RAT)
        else:
            raise SystemExit(
                f"{cog}: filename matches neither classified_<year> nor "
                f"transition_<from>_<to>, so its class labels cannot be chosen")
        rats += 1

        with rasterio.open(cog) as ds:
            existing = ds.tags()
        # Compare over the managed key set, with both sides normalised to what a READ
        # returns: GDAL reports an empty-string tag as absent, so the desired state of a
        # null field is None, not "". Comparing the raw write dict instead would never
        # match on a null field and would re-tag every COG on every run forever.
        want = {k: (v if v != "" else None) for k, v in tags.items()}
        if all(existing.get(k) == want.get(k) for k in MANAGED_KEYS):
            skipped += 1
            continue

        # No IGNORE_COG_LAYOUT_BREAK: these are the staged plain GeoTIFFs, not COGs.
        # 03_cog.py builds the COG afterwards and lays out the final bytes.
        with rasterio.open(cog, "r+") as ds:
            ds.update_tags(**tags)
        tagged += 1

# A count, not a silence: `rats` is the completeness signal for the labels, and it is
# reported separately from `tagged` because the two are governed by different conditions —
# every raster gets a RAT every run, while tagging skips what already matches.
print(f"Tagged {tagged} staged raster(s), skipped {skipped}; "
      f"wrote {rats} class-label RAT sidecar(s) "
      f"({len(CLASSIFIED_RAT)} classes / {len(TRANSITION_RAT)} transitions)")
