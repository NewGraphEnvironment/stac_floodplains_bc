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

Published and live at <https://images.a11s.one> — the 8 **Fraser-region** watershed groups
(chinook, functional floodplain `ff04`), one STAC **item per watershed group**. Tree-cover change
over the floodplain, 2017 → 2023:

| WSG | Floodplain (km²) | Gross loss (ha) | Gross gain (ha) | Net (ha) |
|----|----:|----:|----:|----:|
| LCHL | 325 | 1,261 | 1,747 | +486 |
| LSAL | 256 | 986 | 1,006 | +21 |
| WILL | 305 | 645 | 576 | -69 |
| TABR | 233 | 608 | 352 | -257 |
| UFRA | 188 | 544 | 719 | +175 |
| NECR | 551 | 2,854 | 1,450 | -1,404 |
| MORK | 626 | 946 | 1,212 | +266 |
| FRAN | 883 | 7,177 | 897 | -6,280 |
| **Total** | **3,366** | **15,022** | **7,958** | **-7,064** |

Gross loss = area tree-covered in 2017 but not 2023; gross gain = the reverse; net = gain − loss
(negative = net tree loss). Figures are aggregated from each group's transition layer. Per-row
values are rounded to whole units, so a column may not sum exactly to the (unrounded) total.

## Pipeline

Reads `$FLOODPLAINS_DATA` (default `../floodplains/data`); processes through five stages
(`scripts/run_pipeline.sh`):

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover WSGs; copy each `rasters/<sp>_ff04/{classified_2017,2020,2023,transition}.tif` + `floodplain_landcover.gpkg` into `data/raw/<wsg>/` |
| COG | `02_cog.R` | Convert rasters to Cloud-Optimized GeoTIFFs (`filetype = "COG"`, DEFLATE) → `data/stac/<wsg>/` |
| Tag | `03_cog_tag.py` | Embed GDAL metadata tags: `WSG`, `SPECIES`, `SCENARIO`, `REGION`, `FLOODPLAIN_KM2`, `GROSS_LOSS_HA`, `GROSS_GAIN_HA`, `NET_HA`, per-asset `YEAR` |
| S3 | `04_s3_upload.R` | `aws s3 sync data/stac s3://stac-floodplains-bc` |
| STAC | `05_stac_register.py` | Generate STAC collection + items, validate with pystac |

Catalog load (shared `stac` DB → `images.a11s.one`) runs from the
[`rtj`](https://github.com/NewGraphEnvironment/rtj) repo, which manages the geoserv server, once
the items are in S3:

```bash
# in rtj — collection is listed in stac_register-all.sh (rtj#177)
scripts/geoserv/stac_register-pypgstac.sh \
  stac-floodplains-bc https://stac-floodplains-bc.s3.us-west-2.amazonaws.com
```

## Item model

One item per watershed group (`<wsg>_<sp>_ff04`), geometry = the `ff04` floodplain footprint,
datetime range 2017 → 2023.

- **Raster assets** (titiler-renderable COGs): `classified_2017`, `classified_2020`,
  `classified_2023`, `transition_2017_2023`
- **Vector asset** (download): `floodplain` → `floodplain_landcover.gpkg` (floodplain polygon +
  transition patches)
- **Properties** (labelled, aggregated from the transition layer during staging): `wsg`,
  `species`, `region`, `floodplain_km2`, `gross_loss_ha`, `gross_gain_ha`, `net_ha`

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
    wsg            = p$wsg,
    floodplain_km2 = p$floodplain_km2,
    gross_loss_ha  = p$gross_loss_ha,
    gross_gain_ha  = p$gross_gain_ha,
    net_ha         = p$net_ha
  )
})

# render a classified COG asset URL in QGIS / titiler, e.g.:
items$features[[1]]$assets$classified_2023$href
```

## Prerequisites

[`uv`](https://docs.astral.sh/uv/) for the Python steps (`uv run` auto-syncs the env from
`pyproject.toml` + `uv.lock` — pystac / rasterio); R with `terra`, `sf`, `readr`;
AWS credentials for `s3://stac-floodplains-bc`; a populated `floodplains/data/<wsg>/` tree.
