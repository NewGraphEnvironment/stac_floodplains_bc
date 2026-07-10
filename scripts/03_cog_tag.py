"""03_cog_tag.py — embed publish metadata as GDAL tags on the floodplain COGs.

Runs after 02_cog.R. For each watershed group it reads the staged
`data/raw/<wsg>/meta.json` (written by 01_stage.R) and tags every COG in
`data/stac/<wsg>/` with the WSG identity, scenario, and the tree loss/gain/net
figures derived from the transition layer. Classified rasters also get the year
they represent; the transition raster gets its span.

Tags are visible in QGIS: Layer Properties -> Metadata tab.
"""

import json
import re
from pathlib import Path

import rasterio

RAW_DIR = Path("data/raw")
STAC_DIR = Path("data/stac")

# Scalar tags shared by every asset in a WSG.
SHARED_FIELDS = [
    "wsg", "species", "scenario", "region",
    "floodplain_km2", "gross_loss_ha", "gross_gain_ha", "net_ha",
]


def shared_tags(meta: dict) -> dict:
    return {f.upper(): str(meta[f]) for f in SHARED_FIELDS if meta.get(f) is not None}


tagged = 0
skipped = 0

for meta_path in sorted(RAW_DIR.glob("*/meta.json")):
    wsg = meta_path.parent.name
    meta = json.loads(meta_path.read_text())
    base = shared_tags(meta)

    cogs = sorted((STAC_DIR / wsg).glob("*.tif"))
    for cog in cogs:
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
        # Skip only when every computed value already matches, so a re-run after an
        # upstream number changes still overwrites stale tags.
        if all(existing.get(k) == v for k, v in tags.items()):
            skipped += 1
            continue

        with rasterio.open(cog, "r+", IGNORE_COG_LAYOUT_BREAK="YES") as ds:
            ds.update_tags(**tags)
        tagged += 1

print(f"Tagged {tagged} COGs, skipped {skipped}")
