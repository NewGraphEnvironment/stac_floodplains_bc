# stac_floodplains_bc

Serve floodplain land-cover and land-cover-**change** (2017 → 2023) rasters for British
Columbia watershed groups as a [STAC](https://stacspec.org/) collection, queryable via
[`rstac`](https://brazil-data-cube.github.io/rstac/) and QGIS (v3.42+) at
<https://images.a11s.one>.

The floodplain modelling lives in the [`floodplains`](https://github.com/NewGraphEnvironment/floodplains)
driver repo (network → VCA floodplain → `drift` STAC LULC + transition). **This repo is the
publish layer**: it takes the already-produced per-watershed-group raster + vector outputs,
converts the rasters to Cloud-Optimized GeoTIFFs, uploads to `s3://stac-floodplains-bc`, and
registers a STAC collection served by the shared `geoserv` pgstac/titiler stack — no
re-modelling.

Sister collections on the same endpoint: `stac-airphoto-bc`, `stac-dem-bc`, `stac-uav-bc`,
`stac-orthophoto-bc`.

## Coverage

Published and live at <https://images.a11s.one> — **17 STAC items** across **16 watershed groups**
in the **Fraser** (chinook), **Peace** (bull trout), and **Skeena** (coho + chinook) regions. Most
groups have one item; **MORR** carries two (coho and chinook). The `Floodplain (km²)` column is the
functional-floodplain `ff04` extent (each item also publishes ff02/ff06 areas). Tree-cover change
over the floodplain, 2017 → 2023:

| WSG | Region | Species | Floodplain (km²) | Gross loss (ha) | Gross gain (ha) | Net (ha) |
|----|----|----|----:|----:|----:|----:|
| LCHL | Fraser | chinook | 325 | 1,261 | 1,747 | +486 |
| LSAL | Fraser | chinook | 256 | 986 | 1,006 | +21 |
| WILL | Fraser | chinook | 305 | 645 | 576 | -69 |
| TABR | Fraser | chinook | 233 | 608 | 352 | -257 |
| UFRA | Fraser | chinook | 188 | 544 | 719 | +175 |
| NECR | Fraser | chinook | 551 | 2,854 | 1,450 | -1,404 |
| MORK | Fraser | chinook | 626 | 946 | 1,212 | +266 |
| FRAN | Fraser | chinook | 883 | 7,177 | 897 | -6,280 |
| BOWR | Fraser | chinook | 298 | 461 | 287 | -174 |
| MCGR | Fraser | chinook | 290 | 510 | 817 | +307 |
| PCEA | Peace | bull trout | 1,068 | 101 | 210 | +109 |
| PARS | Peace | bull trout | 485 | 1,439 | 3,233 | +1,794 |
| PINE | Peace | bull trout | 380 | 763 | 1,497 | +734 |
| BULK | Skeena | coho | 490 | 2,073 | 1,074 | -1,000 |
| MORR | Skeena | coho | 411 | 434 | 685 | +251 |
| MORR | Skeena | chinook | 411 | 482 | 731 | +248 |
| KISP | Skeena | chinook | 247 | 268 | 937 | +669 |
| **Total** | | | **7,036** | **21,553** | **17,428** | **-4,126** |

Gross loss = area tree-covered in 2017 but not 2023; gross gain = the reverse; net = gain − loss
(negative = net tree loss). Figures are aggregated from each item's transition layer. Per-row
values are rounded to whole units, so a column may not sum exactly to the (unrounded) total. MORR
contributes two items (coho + chinook): its floodplain is one physical extent counted **once** in
the km² total, while each item's tree-change is listed and summed separately.

## Pipeline

Reads `$FLOODPLAINS_DATA` (default `../floodplains/data`); processes through five stages
(`scripts/run_pipeline.sh`):

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover WSGs + their publish targets; for each item (`<wsg>_<scenario>`) stage `rasters/<scenario>/{classified_2017,2020,2023,transition}.tif` + `floodplain_landcover.gpkg` + `floodplain.gpkg` (ff02/ff04/ff06 delineations) into `data/{raw,stac}/<item_id>/`; compute per-flood-factor floodplain areas |
| COG | `02_cog.R` | Convert rasters to Cloud-Optimized GeoTIFFs (`filetype = "COG"`, DEFLATE) → `data/stac/<item_id>/` |
| Tag | `03_cog_tag.py` | Embed GDAL metadata tags: `WSG`, `SPECIES`, `SCENARIO`, `REGION`, `FLOODPLAIN_FF02_KM2`, `FLOODPLAIN_FF04_KM2`, `FLOODPLAIN_FF06_KM2`, `GROSS_LOSS_HA`, `GROSS_GAIN_HA`, `NET_HA`, per-asset `YEAR` |
| STAC | `05_stac_register.py` | Build the STAC collection + one item per target → `data/stac/<item_id>.json` |
| Validate | `item_validate.py` | pystac-validate every document on disk; nonzero exit on any failure |

**`run_pipeline.sh` makes no network writes.** Publishing is a separate command, so a rebuild —
or a smoke test — cannot reach S3 or the live catalog at all:

```bash
bash scripts/catalogue_release.sh          # validate → sync → register → verify
```

That split also means a release can be cut from any machine with AWS credentials and SSH to the
catalog host; only the *rebuild* needs the ~900 MB `floodplains` source tree.

### Guards

Bucket versioning is **Suspended**, so publishing a short collection over the live one is
unrecoverable. Three interlocks, each catching what the previous cannot:

1. Staging that skips a rostered group (missing `area.yml` or rasters) drops a `PARTIAL_STAGE`
   marker the release refuses to publish past.
2. `item_validate.py` requires exactly the number of items that were staged — a wrong path or an
   empty tree fails rather than reporting `valid: 0` and exiting 0.
3. Before syncing, the release compares the build against the **live** collection and refuses if
   any live item is absent. This catches the case the marker structurally cannot: a region roster
   missing entirely, whose groups are never counted as "skipped" because the loop never reaches
   them.

Removal is always deliberate — registration is an upsert, so nothing is deleted implicitly. See
the retraction recipe in `scripts/README.md`.

Catalog load (shared `stac` DB → `images.a11s.one`) is **owned by this repo** — `catalogue_release.sh`
registers over SSH with `pypgstac`, which the [`rtj`](https://github.com/NewGraphEnvironment/rtj)
server build installs on the host. The API itself is deliberately read-only (transactions
extension off, `POST` returns 405), so writes go through pypgstac rather than the API.

| Script | Does |
|----|----|
| `collection_register.sh <collection.json>` | upsert the collection document |
| `item_register.sh <item.json>...` | upsert items (NDJSON over SSH, count-checked) |
| `item_unregister.sh <item-id>...` | delete items from the API (idempotent) |

Registration is an **upsert**: nothing is deleted implicitly, and there is no window where the
collection serves zero items. `${GEOSERV_HOST:-root@geopro}` selects the host — the tailnet node
name rather than the reserved IP, which changes on a droplet rebuild.

## Item model

One or more items per watershed group — one per modelled `(species, scenario)` target, id
`<wsg>_<scenario>` (e.g. `morr_co_ff04` + `morr_ch_ff06`). Geometry = the item's headline-scenario
floodplain footprint; datetime range 2017 → 2023. Assets live under the item-keyed S3 prefix
`s3://stac-floodplains-bc/<item_id>/`.

- **Raster assets** (titiler-renderable COGs): `classified_2017`, `classified_2020`,
  `classified_2023`, `transition_2017_2023`
- **Vector assets** (download):
  - `floodplain_landcover` → `floodplain_landcover.gpkg` (per-year classified polygons +
    transition patches)
  - `floodplain` → `floodplain.gpkg` (delineated floodplain extents at three flood factors:
    `<sp>_ff02`, `<sp>_ff04`, `<sp>_ff06`)

  Every layer of **both** GeoPackages carries `wsg`, `species`, and `scenario` columns, so several
  items can be merged into one GeoPackage and kept separable **by attribute** — filter, categorize,
  or replace a single area (`DELETE WHERE wsg = …`) without per-area layer names.
- **Properties** (labelled, aggregated during staging): `wsg`, `species`, `region`,
  `floodplain_ff02_km2`, `floodplain_ff04_km2`, `floodplain_ff06_km2` (floodplain area per flood
  factor), `gross_loss_ha`, `gross_gain_ha`, `net_ha` (tree change from the transition layer)

## Query with rstac

```r
library(rstac)

items <- rstac::stac("https://images.a11s.one/") |>
  rstac::stac_search(collections = "stac-floodplains-bc") |>
  rstac::post_request() |>
  rstac::items_fetch()

# tree-cover change per watershed group
purrr::map_dfr(items$features, \(f) {
  p <- f$properties
  tibble::tibble(
    wsg                 = p$wsg,
    species             = p$species,
    floodplain_ff02_km2 = p$floodplain_ff02_km2,
    floodplain_ff04_km2 = p$floodplain_ff04_km2,
    floodplain_ff06_km2 = p$floodplain_ff06_km2,
    gross_loss_ha       = p$gross_loss_ha,
    gross_gain_ha       = p$gross_gain_ha,
    net_ha              = p$net_ha
  )
})

# render a classified COG asset URL in QGIS / titiler, e.g.:
items$features[[1]]$assets$classified_2023$href
```

## Prerequisites

[`uv`](https://docs.astral.sh/uv/) for the Python steps (`uv run` auto-syncs the env from
`pyproject.toml` + `uv.lock` — pystac / rasterio); R with `terra`, `sf`, `readr`;
AWS credentials for `s3://stac-floodplains-bc`; a populated `floodplains/data/<wsg>/` tree.
