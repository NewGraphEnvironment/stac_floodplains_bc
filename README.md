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

Initial publish: the 8 **Fraser-region** watershed groups (chinook, functional floodplain
`ff04`) — LCHL, LSAL, WILL, TABR, UFRA, NECR, MORK, FRAN. One STAC **item per watershed group**.

## Pipeline

Reads `$FLOODPLAINS_DATA` (default `../floodplains/data`); processes through five stages
(`scripts/run_pipeline.sh`):

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover WSGs; copy each `rasters/<sp>_ff04/{classified_2017,2020,2023,transition}.tif` + `floodplain_landcover.gpkg` into `data/raw/<wsg>/` |
| COG | `02_cog.R` | Convert rasters to Cloud-Optimized GeoTIFFs (`filetype = "COG"`, DEFLATE) → `data/stac/<wsg>/` |
| Tag | `03_cog_tag.py` | Embed GDAL metadata tags: `WSG`, `SPECIES`, `SCENARIO`, `YEAR`, `FLOODPLAIN_KM2`, `GROSS_LOSS_HA`, `GROSS_GAIN_HA`, `NET_HA` |
| S3 | `04_s3_upload.R` | `aws s3 sync data/stac s3://stac-floodplains-bc` |
| STAC | `05_stac_register.py` | Generate STAC collection + items, validate with pystac |

Bulk-load into the catalog on the geoserv server (shared `stac` DB → `images.a11s.one`):

```bash
ssh root@<geopro> 'bash /tmp/stac_register-pypgstac.sh \
  stac-floodplains-bc https://stac-floodplains-bc.s3.us-west-2.amazonaws.com'
```

## Item model

One item per watershed group (`<wsg>_<sp>_ff04`), geometry = the `ff04` floodplain footprint,
datetime range 2017 → 2023.

- **Raster assets** (titiler-renderable COGs): `classified_2017`, `classified_2020`,
  `classified_2023`, `transition_2017_2023`
- **Vector asset** (download): `floodplain` → `floodplain_landcover.gpkg` (floodplain polygon +
  transition patches)
- **Properties** (labelled, computed from the transition layer at register time): `wsg`,
  `species`, `region`, `floodplain_km2`, `gross_loss_ha`, `gross_gain_ha`, `net_ha`

## Query with rstac

```r
library(rstac)

q <- rstac::stac("https://images.a11s.one/") |>
  rstac::stac_search(collections = "stac-floodplains-bc") |>
  rstac::post_request()

r <- rstac::items_fetch(q)
```

## Prerequisites

`conda env create -f environment.yml` (pystac / rasterio); R with `terra`, `sf`, `readr`;
AWS credentials for `s3://stac-floodplains-bc`; a populated `floodplains/data/<wsg>/` tree.
