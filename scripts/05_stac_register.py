"""05_stac_register.py — build the stac-floodplains-bc collection + item JSON.

One or more STAC items per watershed group — one per modelled (species, scenario)
target (`<wsg>_<sp>_ff0N`, e.g. `morr_co_ff04` + `morr_ch_ff06`). Item id is the key
for both the staging dir (`data/{raw,stac}/<item_id>/`) and the S3 asset prefix.
  - geometry  = the item's headline-scenario floodplain footprint (from meta.json)
  - datetime  = 2017 -> 2023 land-cover-change span
  - assets    = classified_2017/2020/2023 + transition_2017_2023 COGs, the
                floodplain_landcover.gpkg vector, and the floodplain.gpkg
                delineations (ff02/ff04/ff06 extents)
  - labelled properties: wsg, species, region, floodplain_ff02/04/06_km2, and the
    tree loss/gain/net figures staged from the transition layer.

Writes collection.json + <item_id>.json under data/stac/ and stops there. Build
only: no validation, no S3, no network. Validation is item_validate.py (it checks
the bytes on disk, so a second in-process copy here would only drift), and
publishing is catalogue_release.sh. That split is what lets validation gate the
asset sync rather than run after it.

The name is now a misnomer — it registers nothing. Renaming is deferred with the
STAC Version Extension work so the ~10 references move once.

Usage:
    uv run python scripts/05_stac_register.py
"""

import json
from datetime import datetime, timezone
from pathlib import Path

import pystac
import rasterio

# --- Config ---------------------------------------------------------------

BUCKET = "stac-floodplains-bc"
S3_REGION = "us-west-2"
COLLECTION_ID = "stac-floodplains-bc"
RAW_DIR = Path("data/raw")
STAC_DIR = Path("data/stac")
S3_BASE = f"https://{BUCKET}.s3.{S3_REGION}.amazonaws.com"

GPKG_MEDIA_TYPE = "application/geopackage+sqlite3"
PROJECTION_EXT = "https://stac-extensions.github.io/projection/v1.1.0/schema.json"


def s3_href(rel_path: str) -> str:
    return f"{S3_BASE}/{rel_path}"


def build_item(wsg_dir: Path, meta: dict) -> pystac.Item:
    item_id = meta["item_id"]
    years = meta["years"]
    span = meta["transition_span"]

    # Projection info from a representative COG (all share the WSG grid).
    ref_cog = wsg_dir / f"classified_{years[0]}.tif"
    with rasterio.open(ref_cog) as ds:
        native_bounds = list(ds.bounds)
        epsg = ds.crs.to_epsg()
        shape_hw = [ds.height, ds.width]
        transform = list(ds.transform)[:6]

    start_dt = datetime(span[0], 1, 1, tzinfo=timezone.utc)
    end_dt = datetime(span[1], 12, 31, tzinfo=timezone.utc)

    # Raster assets — one per classified year plus the transition.
    assets = {}
    for yr in years:
        rel = f"{meta['item_id']}/classified_{yr}.tif"
        assets[f"classified_{yr}"] = pystac.Asset(
            href=s3_href(rel),
            media_type=pystac.MediaType.COG,
            title=f"Classified land cover {yr}",
            roles=["data"],
        )
    trans_rel = f"{meta['item_id']}/transition_{span[0]}_{span[1]}.tif"
    assets[f"transition_{span[0]}_{span[1]}"] = pystac.Asset(
        href=s3_href(trans_rel),
        media_type=pystac.MediaType.COG,
        title=f"Land-cover transition {span[0]}-{span[1]}",
        roles=["data"],
    )
    assets["floodplain_landcover"] = pystac.Asset(
        href=s3_href(f"{meta['item_id']}/floodplain_landcover.gpkg"),
        media_type=GPKG_MEDIA_TYPE,
        title="Floodplain land cover + transition (GeoPackage)",
        roles=["data"],
    )
    assets["floodplain"] = pystac.Asset(
        href=s3_href(f"{meta['item_id']}/floodplain.gpkg"),
        media_type=GPKG_MEDIA_TYPE,
        title="Floodplain delineations ff02/ff04/ff06 (GeoPackage)",
        roles=["data"],
    )

    properties = {
        "title": f"{meta['wsg']} {meta['scenario']} floodplain land-cover change "
                 f"{span[0]}-{span[1]}",
        "wsg": meta["wsg"],
        "species": meta["species"],
        "region": meta["region"],
        "floodplain_ff02_km2": meta["floodplain_ff02_km2"],
        "floodplain_ff04_km2": meta["floodplain_ff04_km2"],
        "floodplain_ff06_km2": meta["floodplain_ff06_km2"],
        "gross_loss_ha": meta["gross_loss_ha"],
        "gross_gain_ha": meta["gross_gain_ha"],
        "net_ha": meta["net_ha"],
        "start_datetime": start_dt.isoformat(),
        "end_datetime": end_dt.isoformat(),
        "proj:epsg": epsg,
        "proj:bbox": native_bounds,
        "proj:shape": shape_hw,
        "proj:transform": transform,
    }

    item = pystac.Item(
        id=item_id,
        geometry=meta["geometry"],
        bbox=meta["bbox_wgs84"],
        datetime=end_dt,
        properties=properties,
        assets=assets,
        stac_extensions=[PROJECTION_EXT],
    )
    item.collection_id = COLLECTION_ID
    item.add_link(pystac.Link(
        rel="collection",
        target=s3_href("collection.json"),
        media_type="application/json",
    ))
    return item


# --- Build items ----------------------------------------------------------

items = []
for meta_path in sorted(RAW_DIR.glob("*/meta.json")):
    wsg = meta_path.parent.name
    wsg_dir = STAC_DIR / wsg
    meta = json.loads(meta_path.read_text())

    # 01 staged this WSG, so every asset must be present — a missing COG/gpkg means
    # a partial run. Fail hard rather than upload a reduced collection with dead hrefs.
    span = meta["transition_span"]
    expected = (
        [wsg_dir / f"classified_{yr}.tif" for yr in meta["years"]]
        + [wsg_dir / f"transition_{span[0]}_{span[1]}.tif"]
        + [wsg_dir / "floodplain_landcover.gpkg"]
        + [wsg_dir / "floodplain.gpkg"]
    )
    missing = [p.name for p in expected if not p.exists()]
    if missing:
        raise SystemExit(f"{wsg}: staged in data/raw but missing assets in {wsg_dir}: {missing}")

    item = build_item(wsg_dir, meta)
    items.append(item)
    (STAC_DIR / f"{item.id}.json").write_text(json.dumps(item.to_dict(), indent=2))

print(f"Generated {len(items)} STAC items")

# --- Build collection -----------------------------------------------------

if not items:
    # Never write/upload an item-less collection — that would clobber the live one.
    raise SystemExit("No items built — nothing staged under data/raw/*/meta.json?")

bboxes = [i.bbox for i in items]
spatial_extent = pystac.SpatialExtent(bboxes=[[
    min(b[0] for b in bboxes), min(b[1] for b in bboxes),
    max(b[2] for b in bboxes), max(b[3] for b in bboxes),
]])
starts = [datetime.fromisoformat(i.properties["start_datetime"]) for i in items]
ends = [datetime.fromisoformat(i.properties["end_datetime"]) for i in items]
temporal_extent = pystac.TemporalExtent(intervals=[[min(starts), max(ends)]])

collection = pystac.Collection(
    id=COLLECTION_ID,
    title="Floodplain Land-Cover Change in British Columbia",
    description=(
        "Floodplain land-cover classification and 2017-2023 transition for British "
        "Columbia watershed groups. One or more items per watershed group (one per "
        "modelled species/scenario): three classified years, a transition raster, a "
        "land-cover GeoPackage, and a floodplain delineation GeoPackage (ff02/ff04/ff06 "
        "extents). Floodplain area per flood-factor and tree loss/gain/net properties "
        "are aggregated from the layers produced by the `floodplains` driver."
    ),
    extent=pystac.Extent(spatial=spatial_extent, temporal=temporal_extent),
    license="proprietary",
)
for item in items:
    collection.add_link(pystac.Link(
        rel="item",
        target=s3_href(f"{item.id}.json"),
        media_type="application/json",
    ))

collection_path = STAC_DIR / "collection.json"
collection_path.write_text(json.dumps(collection.to_dict(), indent=2))

print(f"{len(items)} items + collection written to {STAC_DIR}/")
print("Next: uv run python scripts/item_validate.py  (or bash scripts/catalogue_release.sh)")
