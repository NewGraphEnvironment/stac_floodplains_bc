"""item_create.py — build the stac-floodplains-bc collection + item JSON.

One or more STAC items per watershed group — one per modelled (species, scenario)
target (`<wsg>_<sp>_ff0N`, e.g. `morr_co_ff04` + `morr_ch_ff06`). Item id is the key
for both the staging dir (`data/{raw,stac}/<item_id>/`) and the S3 asset prefix.
  - geometry  = the item's headline-scenario floodplain footprint (from meta.json)
  - datetime  = 2017 -> 2023 land-cover-change span
  - assets    = classified_2017/2020/2023 + transition_2017_2023 COGs, the
                floodplain_landcover.gpkg vector, the floodplain.gpkg
                delineations (ff02/ff04/ff06 extents), and transition_vector.gpkg
                (the transition layer alone, without the classified epochs)
  - labelled properties: wsg, species, region, floodplain_ff02/04/06_km2, and the
    tree loss/gain/net figures staged from the transition layer.
  - `classification:classes` on every raster asset (#34/#35), generated from the same
    data/raw/classes.json that 02_raster_tag.py builds the embedded RAT from, so the
    STAC surface and the COG surface cannot disagree.

Writes collection.json + <item_id>.json under data/stac/ and stops there. Build
only: no validation, no S3, no network. Validation is item_validate.py (it checks
the bytes on disk, so a second in-process copy here would only drift), and
publishing is catalogue_release.sh. That split is what lets validation gate the
asset sync rather than run after it.

Usage:
    uv run python scripts/item_create.py
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
# A QML is XML, and there is no registered media type for a QGIS layer style. Naming an
# unregistered `application/...+xml` would assert a type nobody can resolve; `application/xml`
# is what it demonstrably is.
QML_MEDIA_TYPE = "application/xml"

# The layer styles published beside the data (#46), generated from the same classes.json
# that feeds the RAT and classification:classes, and embedded in each GeoPackage's
# layer_styles table by 04_gpkg_style.py. Published as assets as well, for consumers who
# merge items into one GeoPackage or who disable default styles. Keys are prefixed rather
# than named for the file stem: `floodplain` and `transition_vector` are already asset
# keys, and a stem collision would silently replace a data asset while leaving the count
# unchanged — the trap already documented for `transition_vector` below.
STYLE_ASSETS = {
    "style_floodplain": ("floodplain.qml", "QGIS layer style: floodplain delineations"),
    "style_classified": ("classified.qml", "QGIS layer style: classified land cover"),
    "style_transition": ("transition.qml", "QGIS layer style: land-cover transitions"),
}
PROJECTION_EXT = "https://stac-extensions.github.io/projection/v1.1.0/schema.json"
FILE_EXT = "https://stac-extensions.github.io/file/v2.1.0/schema.json"
CLASSIFICATION_EXT = (
    "https://stac-extensions.github.io/classification/v2.0.0/schema.json")

CLASSES_PATH = RAW_DIR / "classes.json"

# Multihash prefix for sha2-256: 0x12 = function code, 0x20 = 32-byte digest length.
# file:checksum is a multihash, NOT a bare digest — see file_meta().
_MULTIHASH_SHA256 = "1220"

# Run provenance (#17), ferried from the producer via meta.json. Declared in
# 01_stage.R's PROV_FIELDS; these are the same names, published under the `nge:`
# namespace established in stac_uav_bc#16. Keep the two lists in step — the
# meta[f] lookup below raises rather than defaulting, so a drift fails loudly.
PROV_FIELDS = [
    "link_run_uid", "link_config_sha256", "link_sha", "link_version",
    "flooded_version", "drift_version", "produced_datetime",
    "landcover_source", "landcover_collection", "landcover_stac_url", "landcover_key",
    "landcover_item_hash",
]
NGE_PROV_PROPERTIES = [f"nge:{f}" for f in PROV_FIELDS]


def _slug(name: str) -> str:
    """'Flooded Vegetation' -> 'Flooded_Vegetation'; 'Snow/Ice' -> 'Snow_Ice'.

    The classification extension constrains `name` to `^[0-9A-Za-z-_]+$`. Of the nine
    published classes three carry a space (`Flooded Vegetation`, `Built Area`,
    `Bare Ground`) and one a slash (`Snow/Ice`), so the readable form cannot be the
    machine name. It goes in `title` instead; nothing is lost.
    """
    return re.sub(r"[^0-9A-Za-z_-]+", "_", name).strip("_")


def _load_classes() -> list[dict]:
    """The class table 01_stage.R ferried from drift. Raises rather than defaulting.

    Defaulting to an empty list here would be the worst available failure: the extension
    URL would still be declared, every asset would carry no classes, and the item would
    VALIDATE — measured, because the extension's Item branch "does not require" the field.
    A uniform loss like that is invisible to any cross-item comparison as well.
    """
    if not CLASSES_PATH.is_file():
        raise SystemExit(f"{CLASSES_PATH} is missing — 01_stage.R writes it; re-run staging")
    classes = json.loads(CLASSES_PATH.read_text()).get("classes")
    if not classes:
        raise SystemExit(f"{CLASSES_PATH} carries no classes")
    return classes


def _assert_unique_names(entries: list[dict], what: str) -> list[dict]:
    """Slugs must be injective.

    `uniqueItems: true` on the array cannot catch a collision, because two entries that
    share a `name` still differ by `value` and so are distinct objects. A consumer keying a
    legend by `name` would silently merge them.
    """
    names = [e["name"] for e in entries]
    if len(set(names)) != len(names):
        dupes = sorted({n for n in names if names.count(n) > 1})
        raise SystemExit(f"{what}: class names are not unique after slugging: {dupes}")
    return entries


def classified_classes(classes: list[dict]) -> list[dict]:
    """`classification:classes` for a classified land-cover raster."""
    return _assert_unique_names([
        {"value": c["code"],
         "name": _slug(c["class_name"]),
         "title": c["class_name"],
         "description": c["description"],
         # 6 hex chars, no leading '#'. drift stores '#419bdf'.
         "color_hint": c["color"].lstrip("#").upper()}
        for c in classes], "classified")


def transition_classes(classes: list[dict]) -> list[dict]:
    """`classification:classes` for the transition raster: the full `from -> to` scheme.

    Mirrors the RAT 02_raster_tag.py writes into the COG, row for row and colour for
    colour, because both are built from the same classes.json. That is the point — the two
    published surfaces cannot disagree by construction, and item_validate.py checks the
    published bytes against the published JSON to prove it stayed that way.
    """
    entries = []
    for src in classes:
        for dst in classes:
            same = src["code"] == dst["code"]
            entries.append({
                "value": src["code"] * 1000 + dst["code"],
                "name": f"{_slug(src['class_name'])}__{_slug(dst['class_name'])}",
                "title": (f"{src['class_name']} (no change)" if same
                          else f"{src['class_name']} \u2192 {dst['class_name']}"),
                # Colour by DESTINATION, with the no-change diagonal held back so the ~91%
                # of cells that did not change recedes. Keep in step with
                # 02_raster_tag.py's NO_CHANGE_RGB.
                "color_hint": "D9D9D9" if same else dst["color"].lstrip("#").upper(),
            })
    return _assert_unique_names(entries, "transition")


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
    02 tags the STAGED rasters, 03 writes the COGs from them, and this script runs after both.
    The COG write is the last step to touch a published byte, which is what #33
    changed — tagging used to run last, in place, and that moved the main IFD to the
    end of the file. Any future step that touches an asset after this point would
    publish a checksum that silently does not match the object.
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
            extra_fields={**file_meta(wsg_dir / f"classified_{yr}.tif"),
                          "classification:classes": CLASSIFIED_CLASSES},
        )
    trans_name = f"transition_{span[0]}_{span[1]}.tif"
    trans_rel = f"{meta['item_id']}/{trans_name}"
    assets[f"transition_{span[0]}_{span[1]}"] = pystac.Asset(
        href=s3_href(trans_rel),
        media_type=pystac.MediaType.COG,
        title=f"Land-cover transition {span[0]}-{span[1]}",
        # The raster keeps NO-CHANGE cells (~91% of valid cells); transition_vector.gpkg
        # below is changes-only. The two published representations of "the transition" do
        # not contain the same thing, which a consumer comparing counts has to know.
        description=(
            f"Land-cover transition {span[0]}-{span[1]}, encoded from x 1000 + to "
            f"(2011 = Trees to Rangeland). Includes no-change cells, which the "
            f"classification classes render recessively; transition_vector.gpkg carries "
            f"the changed patches only."),
        roles=["data"],
        extra_fields={**file_meta(wsg_dir / trans_name),
                      "classification:classes": TRANSITION_CLASSES},
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
    # The transition layer alone, without the three dissolved classified epochs that carry
    # most of the bundle's geometry (#23).
    #
    # Key is `transition_vector`, NOT the filename stem: `transition_2017_2023` is already
    # the transition COG's key above, so keying by stem would overwrite it — the item would
    # still show the right asset count, the raster would silently vanish, and the
    # uniform-key-set check in item_validate.py would pass because every item lost the same
    # key. Deliberately year-free besides, so a QGIS style survives a change of span.
    assets["transition_vector"] = pystac.Asset(
        href=s3_href(f"{meta['item_id']}/transition_vector.gpkg"),
        media_type=GPKG_MEDIA_TYPE,
        title="Land-cover transition patches (GeoPackage)",
        roles=["data"],
        extra_fields=file_meta(wsg_dir / "transition_vector.gpkg"),
    )

    for _key, (_file, _title) in STYLE_ASSETS.items():
        assets[_key] = pystac.Asset(
            href=s3_href(f"{meta['item_id']}/{_file}"),
            media_type=QML_MEDIA_TYPE,
            title=_title,
            roles=["style"],
            extra_fields=file_meta(wsg_dir / _file),
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

    # Provenance (#17). `meta[f]` deliberately, not `meta.get(f)`: 01_stage.R writes every
    # field on every item, so a missing key is a staging bug and must raise here rather
    # than default to a null that is indistinguishable from a genuine absence.
    #
    # A null VALUE is expected and correct — floodplains#33 is forward-only, so an area
    # modelled before it lands has no provenance to carry. Verified that pystac preserves
    # null properties through to_dict(), a JSON round trip, from_dict() and validate().
    properties.update({f"nge:{f}": meta[f] for f in PROV_FIELDS})

    item = pystac.Item(
        id=item_id,
        geometry=meta["geometry"],
        bbox=meta["bbox_wgs84"],
        datetime=end_dt,
        properties=properties,
        assets=assets,
        stac_extensions=[PROJECTION_EXT, FILE_EXT, CLASSIFICATION_EXT],
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
# Built once, before anything is written: a missing or empty classes.json must abort
# before the first item JSON lands, for the same reason the scenario/asset preflight below
# does — a mixture of labelled and unlabelled items passes every release guard.
_CLASSES = _load_classes()
CLASSIFIED_CLASSES = classified_classes(_CLASSES)
TRANSITION_CLASSES = transition_classes(_CLASSES)
print(f"classification: {len(CLASSIFIED_CLASSES)} land-cover classes, "
      f"{len(TRANSITION_CLASSES)} transitions from {CLASSES_PATH}")

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
           "floodplain_landcover.gpkg", "floodplain.gpkg", "transition_vector.gpkg"]
        + [f for f, _ in STYLE_ASSETS.values()]
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
        + [wsg_dir / "transition_vector.gpkg"]
        + [wsg_dir / f for f, _ in STYLE_ASSETS.values()]
    )
    missing = [p.name for p in expected if not p.exists()]
    if missing:
        raise SystemExit(f"{wsg}: staged in data/raw but missing assets in {wsg_dir}: {missing}")

    item = build_item(wsg_dir, meta)
    items.append(item)
    (STAC_DIR / f"{item.id}.json").write_text(json.dumps(item.to_dict(), indent=2))

print(f"Generated {len(items)} STAC items")

# Provenance coverage (#17). A published floodplain whose run cannot be traced should be a
# number on screen, not a silence — and under forward-only upstream this starts at zero
# coverage and climbs as areas are re-modelled, so the count is the progress signal.
#
# Two distinct questions, deliberately not collapsed into one: whether ANY provenance was
# carried, and whether the specific field that identifies a link RUN is present.
# `link_run_uid` is legitimately null even on a fresh block if the schema predates
# link#262, so a block can be present while the run is still untraceable.
_no_prov = [i.id for i in items
            if all(i.properties.get(p) is None for p in NGE_PROV_PROPERTIES)]
_untraceable = [i.id for i in items if i.properties.get("nge:link_run_uid") is None]
print(f"  provenance block: {len(items) - len(_no_prov)}/{len(items)} item(s)")
print(f"  link run traceable (nge:link_run_uid): "
      f"{len(items) - len(_untraceable)}/{len(items)} item(s)")
if _untraceable:
    _shown = sorted(_untraceable)[:10]
    _more = f" (+{len(_untraceable) - len(_shown)} more)" if len(_untraceable) > len(_shown) else ""
    print(f"    untraceable: {', '.join(_shown)}{_more}")

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
        "land-cover GeoPackage, a floodplain delineation GeoPackage (ff02/ff04/ff06 "
        "extents), and the transition layer on its own for consumers that do not need "
        "the classified epochs. Floodplain area per flood-factor and tree loss/gain/net properties "
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
