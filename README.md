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

Sister collections on the same endpoint: `stac-airphoto-bc`, `stac-elevation-bc`, `stac-uav-bc`.

## Coverage

Published and live at <https://images.a11s.one>: one item per (watershed group, species,
scenario) target, so a group with two modelled species carries two rows. The block below, caption
included, is generated from the live API after every full release; the caption names the counts
and the catalogue version it describes. `Floodplain (km²)` is each item's **own** scenario extent
— `ff04` functional floodplain, or the wider `ff06` valley bottom where the `Scenario` column says
so — so read that column before comparing rows (each item also publishes all three ff02/ff04/ff06
areas). Tree-cover change over that extent, 2017 → 2023:

*Generated from the live API by `scripts/readme_coverage-table.py`: 23 items across 22 watershed groups in 4 regions (Columbia, Fraser, Peace, Skeena), catalogue version 1.1.0.*

| WSG | Region | Species | Scenario | Floodplain (km²) | Gross loss (ha) | Gross gain (ha) | Net (ha) |
|----|----|----|----|----:|----:|----:|----:|
| KOTL | Columbia | bull trout | ff04 | 676 | 536 | 338 | -198 |
| LARL | Columbia | bull trout | ff04 | 286 | 122 | 56 | -66 |
| SLOC | Columbia | bull trout | ff04 | 117 | 74 | 52 | -23 |
| BOWR | Fraser | chinook | ff04 | 236 | 292 | 203 | -89 |
| FRAN | Fraser | chinook | ff04 | 782 | 5,264 | 590 | -4,674 |
| LCHL | Fraser | chinook | ff04 | 233 | 912 | 1,073 | +161 |
| LNTH | Fraser | chinook | ff04 | 152 | 272 | 65 | -207 |
| LSAL | Fraser | chinook | ff04 | 186 | 560 | 650 | +90 |
| MCGR | Fraser | chinook | ff04 | 290 | 510 | 817 | +307 |
| MORK | Fraser | chinook | ff04 | 417 | 623 | 772 | +149 |
| NECR | Fraser | chinook | ff04 | 397 | 1,943 | 915 | -1,028 |
| TABR | Fraser | chinook | ff04 | 155 | 347 | 150 | -197 |
| THOM | Fraser | chinook | ff04 | 87 | 56 | 3 | -53 |
| UFRA | Fraser | chinook | ff04 | 147 | 414 | 529 | +115 |
| UNTH | Fraser | chinook | ff04 | 101 | 260 | 179 | -81 |
| WILL | Fraser | chinook | ff04 | 236 | 486 | 352 | -133 |
| PARS | Peace | bull trout | ff04 | 410 | 1,076 | 2,696 | +1,620 |
| PCEA | Peace | bull trout | ff04 | 1,052 | 84 | 137 | +53 |
| PINE | Peace | bull trout | ff04 | 380 | 763 | 1,497 | +734 |
| BULK | Skeena | coho | ff04 | 387 | 1,565 | 827 | -738 |
| KISP | Skeena | chinook | ff04 | 190 | 199 | 693 | +494 |
| MORR | Skeena | coho | ff04 | 358 | 309 | 576 | +268 |
| MORR | Skeena | chinook | ff06 | 372 | 343 | 606 | +264 |
| **Total** | | | | **7,273** | **17,008** | **13,775** | **-3,233** |

Gross loss = area tree-covered in 2017 but not 2023; gross gain = the reverse; net = gain − loss
(negative = net tree loss). Figures are aggregated from each item's transition layer. Per-row
values are rounded to whole units, so a column may not sum exactly to the (unrounded) total. MORR,
with two items (coho + chinook), has its `ff04` extent counted **once** in the km² total, while each
item's tree-change is listed and summed separately.

## Pipeline

Reads `$FLOODPLAINS_DATA` (default `../floodplains/data`); processes through six stages
(`scripts/run_pipeline.sh`):

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover WSGs + their publish targets; for each item (`<wsg>_<scenario>`) stage `rasters/<scenario>/{classified_2017,2020,2023,transition}.tif` + `floodplain_landcover.gpkg` + `floodplain.gpkg` (ff02/ff04/ff06 delineations) into `data/{raw,stac}/<item_id>/`, extract the transition layer to `transition_vector.gpkg`, and compute per-flood-factor floodplain areas |
| Tag | `02_raster_tag.py` | Embed GDAL metadata tags onto the **staged** rasters: `WSG`, `SPECIES`, `SCENARIO`, `REGION`, `FLOODPLAIN_FF0*_KM2`, `GROSS_LOSS_HA`, `GROSS_GAIN_HA`, `NET_HA`, `NGE_*` run provenance, per-asset `YEAR`. Before the COG conversion, not after (#33) |
| COG | `03_cog.py` | Convert the tagged rasters to Cloud-Optimized GeoTIFFs (`rasterio.shutil.copy`, DEFLATE) → `data/stac/<item_id>/`, absorbing the class-label RAT into each `.tif` |
| Style | `04_gpkg_style.py` | Embed a `layer_styles` row per feature layer in all three GeoPackages so they open styled in QGIS, from the same `classes.json` that feeds the RAT (#46); copy the three `.qml` beside the assets. Before the STAC build, since that is where `file:checksum` is computed |
| STAC | `item_create.py` | Build the STAC collection + one item per target → `data/stac/<item_id>.json`, including the three `style_*` assets |
| Validate | `item_validate.py` | pystac-validate every document on disk; nonzero exit on any failure |

Every item also carries twelve `nge:` run-provenance properties, published as explicit nulls
until the upstream area has been re-modelled with provenance recording. Two describe the landcover
input: `nge:landcover_key` is a fingerprint of the landcover **produced** — the producer's per-year
content digests folded to one value as `sha256:` over the lines `<year>=<digest>`, years ascending,
newline-joined — and `nge:landcover_item_hash` is the identity of what was **read**, a hash over the
resolved STAC item ids (unchanged by an in-place upstream re-derivation, which is why both ship).

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

Every full release is a **tag**. `catalogue_release.sh` refuses unless HEAD sits exactly on a
`vX.Y.Z` tag that `NEWS.md`'s top entry names, stamps that version onto the collection (STAC
Version Extension), and fails unless the API serves it back — so
`curl -s https://images.a11s.one/collections/stac-floodplains-bc | jq .version` answers which
release is live. Recipe under "Cut a release" in `scripts/README.md`.

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
- **Raster assets stream** — a COG does not have to be downloaded. Both the palette and the
  class labels are embedded (#34/#35), so QGIS and GDAL open one already coloured and labelled
  straight off S3:

  ```bash
  GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR \
  gdalinfo /vsicurl/https://stac-floodplains-bc.s3.us-west-2.amazonaws.com/kotl_bt_ff04/classified_2023.tif
  ```

  The same `/vsicurl/...` path pastes into QGIS's Add Raster Layer dialog. Set
  `GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR` or GDAL spends a dozen wasted requests probing for
  sidecar files that are not there — the bucket answers each with a 403, which is slow rather
  than fatal, and noisy enough to look like a failure.

- **Vector assets** (download):
  - `floodplain_landcover` → `floodplain_landcover.gpkg` (per-year classified polygons +
    transition patches)
  - `floodplain` → `floodplain.gpkg` (delineated floodplain extents at three flood factors:
    `<sp>_ff02`, `<sp>_ff04`, `<sp>_ff06`)
  - `transition_vector` → `transition_vector.gpkg` (the transition patches **alone**, without the
    three dissolved classified epochs that carry most of the bundle's geometry — 70 MB across the
    catalogue against 515 MB of bundles). Take this when you want the change layer and not the
    epochs; it is what makes the data fit a Mergin project.

    The file and its single layer are both named without a year span, deliberately. The span moves
    as the model is re-run, and QGIS styles bind to `path|layername=` — so a style pointing at
    `transition_vector.gpkg|layername=transition` keeps working across re-models. The span stays
    readable from the item's `start_datetime`/`end_datetime`.

  Every layer of **all three** GeoPackages carries `wsg`, `species`, and `scenario` columns, so several
  items can be merged into one GeoPackage and kept separable **by attribute** — filter, categorize,
  or replace a single area (`DELETE WHERE wsg = …`) without per-area layer names.
- **Asset integrity** — every asset carries `file:checksum` and `file:size`
  ([file extension](https://github.com/stac-extensions/file)). Floodplain products are regenerated
  as the DEM, classifier and imagery years improve, so "the floodplain of a watershed group" is a
  moving target; the checksum is what lets you tell *which version* a figure came from, and confirm
  a download arrived intact.

  `file:checksum` is a **multihash**, not a bare digest: `1220` + the sha256 hex, where `12` is the
  sha2-256 code and `20` the 32-byte length. To verify a download, strip the four-character prefix:

  ```bash
  curl -sO https://stac-floodplains-bc.s3.us-west-2.amazonaws.com/kisp_ch_ff04/floodplain.gpkg
  shasum -a 256 floodplain.gpkg          # compare against file:checksum minus the leading 1220
  ```
  ```r
  # or from the catalogue, no manual copying
  a <- items$features[[1]]$assets$floodplain
  sub("^1220", "", a$`file:checksum`) == digest::digest("floodplain.gpkg", algo = "sha256", file = TRUE)
  ```
- **Properties** (labelled, aggregated during staging): `wsg`, `species`, `scenario`,
  `flood_factor`, `region`, `floodplain_ff02_km2`, `floodplain_ff04_km2`, `floodplain_ff06_km2`
  (floodplain area per flood factor), `gross_loss_ha`, `gross_gain_ha`, `net_ha` (tree change from
  the transition layer)

  `wsg` / `species` / `scenario` are the item key — the same three columns every published
  GeoPackage layer carries, so a merged multi-item GeoPackage stays separable by attribute.
  `flood_factor` is the numeric form of the scenario suffix (`ch_ff06` → `6`) and is a real
  multiplier on bankfull depth, so range queries are meaningful: `ff04` is the functional
  floodplain, `ff06` the valley bottom. **Filter on it whenever comparing groups** — the collection
  mixes flood factors, so an unfiltered aggregate sums different extents.

  The collection's `summaries` lists the available `scenario`, `species` and `region` values plus
  the `flood_factor` range, so a client can discover them without downloading items (which are
  3–9 MB each).

## Query with rstac

```r
library(rstac)

items <- rstac::stac("https://images.a11s.one/") |>
  rstac::stac_search(collections = "stac-floodplains-bc") |>
  rstac::post_request() |>
  rstac::items_fetch()

# tree-cover change per item
purrr::map_dfr(items$features, \(f) {
  p <- f$properties
  tibble::tibble(
    wsg                 = p$wsg,
    species             = p$species,
    scenario            = p$scenario,
    flood_factor        = p$flood_factor,
    floodplain_ff02_km2 = p$floodplain_ff02_km2,
    floodplain_ff04_km2 = p$floodplain_ff04_km2,
    floodplain_ff06_km2 = p$floodplain_ff06_km2,
    gross_loss_ha       = p$gross_loss_ha,
    gross_gain_ha       = p$gross_gain_ha,
    net_ha              = p$net_ha
  )
})
```

The collection mixes flood factors, so filter by `scenario` before comparing groups — otherwise
you are summing functional floodplains (`ff04`) and valley bottoms (`ff06`) together:

```r
# only valley-bottom (ff06) items, server-side — filter on flood_factor rather than
# scenario, which is species-pinned and would miss a future co_ff06 / bt_ff06
vb <- rstac::stac("https://images.a11s.one/") |>
  rstac::stac_search(collections = "stac-floodplains-bc") |>
  rstac::ext_query(flood_factor == 6) |>
  rstac::post_request() |>
  rstac::items_fetch()

# what values exist, without downloading any items (they are 3-9 MB each)
rstac::stac("https://images.a11s.one/") |>
  rstac::collections("stac-floodplains-bc") |>
  rstac::get_request() |>
  (\(x) x$summaries)()

# render a classified COG asset URL in QGIS / titiler, e.g.:
items$features[[1]]$assets$classified_2023$href
```

## Prerequisites

[`uv`](https://docs.astral.sh/uv/) for the Python steps (`uv run` auto-syncs the env from
`pyproject.toml` + `uv.lock` — pystac / rasterio, GDAL **3.12+** for RAT-in-`GDAL_METADATA`);
R with `sf`, `readr`, `drift`;
AWS credentials for `s3://stac-floodplains-bc`; a populated `floodplains/data/<wsg>/` tree.

## Attribution

Two licences, over two different things.

- **The scripts in this repo** are [MIT](LICENSE), as in `stac_dem_bc` and `stac_uav_bc`.
- **The published catalogue metadata and derived products** — everything under
  `s3://stac-floodplains-bc` and the collection served at `images.a11s.one` — are
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The collection publishes that
  as its `license`, with a `rel: license` link, six `providers`, and this same sentence as
  `sci:citation`:

> New Graph Environment Ltd. (2026). Floodplain Land-Cover Change in British Columbia
> [data set]. Derived from Impact Observatory, 10m Annual Land Use Land Cover (9-class) V2
> (`io-lulc-annual-v02`), licensed under CC BY 4.0
> (<https://creativecommons.org/licenses/by/4.0/>), accessed via Microsoft Planetary
> Computer; modified by clipping to modelled floodplain extents and cross-tabulating 2017
> against 2023 into land-cover transitions. Floodplain delineation contains information
> licensed under the Open Government Licence – Canada (MRDEM-30, Natural Resources Canada)
> and the Open Government Licence – British Columbia (Freshwater Atlas stream network,
> Province of British Columbia). Stream network built with the `link` package, reproducing
> the `bcfishpass` modelling approach.

### Why CC BY 4.0 outbound

Read from each producer's own record on 2026-09-03, not inferred:

| input | licence | what it obliges |
|---|---|---|
| [`io-lulc-annual-v02`](https://planetarycomputer.microsoft.com/api/stac/v1/collections/io-lulc-annual-v02) — Impact Observatory 10 m annual LULC | `CC-BY-4.0` | credit, a licence link, and a statement that the material was **modified** |
| [`mrdem-30`](https://datacube.services.geo.ca/stac/api/collections/mrdem-30) — NRCan DTM, the terrain the floodplains are delineated off | `OGL-Canada-2.0` | "Contains information licensed under the Open Government Licence – Canada" |
| BC Freshwater Atlas stream network, via `link` / `fresh` | Open Government Licence – British Columbia | the equivalent BC sentence |

None is share-alike, so the derived products may carry our own licence and CC BY 4.0 is the
natural match. `bcfishpass` is a **method** citation rather than a licence obligation:
nothing published here redistributes its override data — the published geometry is
FWA-derived — so it is credited as the modelling approach the network reproduces.

That chain of reasoning is the one thing no guard can check, which is why it is written
down. What *is* checked, absolutely and on every build, is in `scripts/item_validate.py`
(`check_collection_metadata`, `check_citation_premise`) and read back from the live API by
step 5 of `scripts/catalogue_release.sh`.

Items carry no `license` of their own, deliberately: STAC inherits it from the collection,
and the per-item source attribution is the `nge:landcover_*` provenance block, which the
release's provenance floor (#32) is what keeps non-null.
