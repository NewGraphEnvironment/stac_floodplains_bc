"""02_raster_tag.py — embed publish metadata as GDAL tags on the staged rasters.

Runs BETWEEN 01_stage.R and 03_cog.R, on `data/raw/<item_id>/*.tif` — deliberately
before the COG conversion, not after it (#33). Tagging a finished COG in place
requires IGNORE_COG_LAYOUT_BREAK, and that flag is not a warning suppressor: the
write moves the main IFD to the end of the file, so a client has to fetch nearly
the whole object to read a header. Measured at 98.9% and 99.6% on this
collection's own assets before the reorder.

Tagging the staged raster instead costs nothing, because terra carries every tag,
the colour table and the band description through `writeRaster(filetype = "COG")`
and lays the bytes out correctly. The absence of IGNORE_COG_LAYOUT_BREAK below is
the tell that the ordering is right.

For each item it reads `data/raw/<item_id>/meta.json` (written by 01_stage.R) and
tags the rasters with the WSG identity, scenario, run provenance, and the tree
loss/gain/net figures derived from the transition layer. Classified rasters also
get the year they represent; the transition raster gets its span.

Tags are visible in QGIS: Layer Properties -> Metadata tab.

Note the consequence of running before the COG step rather than after it: this script
alone no longer repairs `data/stac`. Correcting a number in meta.json and re-running only
this step leaves the published COGs carrying the old tags, because they are rebuilt by
03_cog.R and not touched here. Re-run 03 as well — or just `run_pipeline.sh`.
`item_validate.py`'s tag contract is what catches it if you forget.

The plain `"r+"` open below is also a tripwire, deliberately. If `floodplains` ever starts
emitting COGs upstream, GDAL will REFUSE the update rather than silently breaking their
layout — which is the failure this whole reorder exists to prevent, and the safe direction
to fail in.
"""

import json
import re
from pathlib import Path

import rasterio

RAW_DIR = Path("data/raw")

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


tagged = 0
skipped = 0

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
        # 03_cog.R builds the COG afterwards and lays out the final bytes.
        with rasterio.open(cog, "r+") as ds:
            ds.update_tags(**tags)
        tagged += 1

print(f"Tagged {tagged} staged raster(s), skipped {skipped}")
