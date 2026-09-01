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

import hashlib
import json
import re
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
FILE_EXT = "https://stac-extensions.github.io/file/v2.1.0/schema.json"

# Multihash prefix for sha2-256: 0x12 = function code, 0x20 = 32-byte digest length.
# file:checksum is a multihash, NOT a bare digest — see file_meta().
_MULTIHASH_SHA256 = "1220"


def s3_href(rel_path: str) -> str:
    return f"{S3_BASE}/{rel_path}"


def file_meta(path: Path) -> dict:
    """`file:checksum` + `file:size` for one asset, per the STAC file extension.

    checksum is a MULTIHASH, hex-encoded lowercase: '1220' + sha256. The prefix is
    what makes it self-describing; a bare sha256 is not a valid multihash.

    The schema cannot catch a mistake here — it is only `^[a-f0-9]+$`, so a bare
    digest with no prefix validates cleanly and uppercase hex fails for an unrelated
    reason. So assert the shape ourselves rather than trusting validation.

    Safe to hash at build time ONLY because every asset is byte-final by now:
    02 writes the COGs, 03 rewrites their tags in place ("r+"), and 05 runs after
    both. Any future step that touches an asset after this point would publish a
    checksum that silently does not match the object.
    """
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    checksum = _MULTIHASH_SHA256 + h.hexdigest()
    # 4 prefix chars + 64 hex chars. hexdigest() is already lowercase; never upper it.
    if len(checksum) != 68 or not checksum.startswith(_MULTIHASH_SHA256):
        raise SystemExit(f"Malformed multihash for {path}: {checksum!r}")
    return {"file:checksum": checksum, "file:size": path.stat().st_size}


def flood_factor(scenario: str) -> int:
    """Numeric flood factor from a scenario key: 'ch_ff06' -> 6.

    Not a label — `flooded`'s VCA regression defines
    flood_depth = bankfull_depth * flood_factor, so ff02/ff04/ff06 are 2x/4x/6x
    bankfull depth and ordinal comparisons ("at least ff04") are meaningful.

    Raises rather than returning None on an unrecognized scenario: a silently
    absent property is exactly the failure this issue exists to fix.
    """
    m = re.search(r"_ff(\d+)$", scenario)
    if not m:
        raise SystemExit(
            f"Cannot derive flood_factor: scenario {scenario!r} does not end in _ff<NN>"
        )
    return int(m.group(1))


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
    # extra_fields carries file:checksum + file:size. Note pystac's own
    # FileExtension.ext(asset, add_if_missing=True) cannot be used here: it raises
    # STACError on an asset with no owner, and these assets are all built before the
    # Item exists. Setting the fields directly also matches how proj:* is done below.
    assets = {}
    for yr in years:
        rel = f"{meta['item_id']}/classified_{yr}.tif"
        assets[f"classified_{yr}"] = pystac.Asset(
            href=s3_href(rel),
            media_type=pystac.MediaType.COG,
            title=f"Classified land cover {yr}",
            roles=["data"],
            extra_fields=file_meta(wsg_dir / f"classified_{yr}.tif"),
        )
    trans_name = f"transition_{span[0]}_{span[1]}.tif"
    trans_rel = f"{meta['item_id']}/{trans_name}"
    assets[f"transition_{span[0]}_{span[1]}"] = pystac.Asset(
        href=s3_href(trans_rel),
        media_type=pystac.MediaType.COG,
        title=f"Land-cover transition {span[0]}-{span[1]}",
        roles=["data"],
        extra_fields=file_meta(wsg_dir / trans_name),
    )
    assets["floodplain_landcover"] = pystac.Asset(
        href=s3_href(f"{meta['item_id']}/floodplain_landcover.gpkg"),
        media_type=GPKG_MEDIA_TYPE,
        title="Floodplain land cover + transition (GeoPackage)",
        roles=["data"],
        extra_fields=file_meta(wsg_dir / "floodplain_landcover.gpkg"),
    )
    assets["floodplain"] = pystac.Asset(
        href=s3_href(f"{meta['item_id']}/floodplain.gpkg"),
        media_type=GPKG_MEDIA_TYPE,
        title="Floodplain delineations ff02/ff04/ff06 (GeoPackage)",
        roles=["data"],
        extra_fields=file_meta(wsg_dir / "floodplain.gpkg"),
    )

    properties = {
        "title": f"{meta['wsg']} {meta['scenario']} floodplain land-cover change "
                 f"{span[0]}-{span[1]}",
        "wsg": meta["wsg"],
        "species": meta["species"],
        # The third part of the item key (wsg/species/scenario), which upstream
        # documents as both a STAC property and a gpkg column. ff04 (functional
        # floodplain) and ff06 (valley bottom) are different extents, so a
        # cross-group query is only honest if the client can filter on this.
        "scenario": meta["scenario"],
        "flood_factor": flood_factor(meta["scenario"]),
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
        stac_extensions=[PROJECTION_EXT, FILE_EXT],
    )
    item.collection_id = COLLECTION_ID
    item.add_link(pystac.Link(
        rel="collection",
        target=s3_href("collection.json"),
        media_type="application/json",
    ))
    return item


# --- Build items ----------------------------------------------------------

# Preflight every scenario before writing anything. Items are written to disk one at
# a time below, so a failure partway leaves a MIXTURE of fresh and stale item JSONs
# next to a stale collection.json — and that mixture passes every release guard
# (collection.json present, item count right, all valid, no orphans), so it would
# publish to a bucket with versioning Suspended. Fail before the first write instead.
meta_paths = sorted(RAW_DIR.glob("*/meta.json"))
for _mp in meta_paths:
    _meta = json.loads(_mp.read_text())
    flood_factor(_meta["scenario"])
    # Same reasoning for the asset files: a missing or unreadable asset must abort
    # before the first JSON is written, not partway through the loop below. Opening
    # each file (rather than just is_file()) is what makes "unreadable" true as well
    # as "missing" — a permission or I/O error surfaces here instead of raising an
    # unhandled FileNotFoundError/OSError mid-write. It cannot detect corruption;
    # only hashing can, and that happens moments later in build_item().
    _span = _meta["transition_span"]
    _dir = STAC_DIR / _meta["item_id"]
    for _name in (
        [f"classified_{yr}.tif" for yr in _meta["years"]]
        + [f"transition_{_span[0]}_{_span[1]}.tif",
           "floodplain_landcover.gpkg", "floodplain.gpkg"]
    ):
        try:
            with (_dir / _name).open("rb") as _fh:
                _fh.read(1)
        except OSError as e:
            raise SystemExit(
                f"{_meta['item_id']}: cannot read asset, refusing to checksum: {_dir / _name} ({e})")

items = []
for meta_path in meta_paths:
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

# Summaries let a client discover the queryable values without downloading items —
# which matters here because the items are 3-9 MB each. Derived from the built items
# rather than hardcoded, so adding a scenario upstream cannot leave this stale.
collection.summaries = pystac.Summaries({
    "scenario": sorted({i.properties["scenario"] for i in items}),
    "species": sorted({i.properties["species"] for i in items}),
    "region": sorted({i.properties["region"] for i in items}),
    # A Set of Values, not a Range Object. Flood factor is discrete (2/4/6) and today
    # only 4 and 6 exist — a range would advertise flood_factor=5 as available, and a
    # client building a filter list from this summary would offer it and get nothing.
    "flood_factor": sorted({i.properties["flood_factor"] for i in items}),
})
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
