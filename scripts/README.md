# scripts

Publish pipeline for the `stac-floodplains-bc` collection. Reads the already-produced
floodplain outputs from `$FLOODPLAINS_DATA` (default `../floodplains/data`) — this repo does
no floodplain modelling.

Run end-to-end: `bash scripts/run_pipeline.sh`

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover WSGs with an `ff04` floodplain; copy the classified/transition rasters + `floodplain_landcover.gpkg` into `data/raw/<wsg>/` |
| COG | `02_cog.R` | Convert rasters to Cloud-Optimized GeoTIFFs → `data/stac/<wsg>/` |
| Tag | `03_cog_tag.py` | Embed GDAL metadata tags (WSG, species, scenario, year, floodplain km², gross loss/gain/net ha) |
| S3 | `04_s3_upload.R` | `aws s3 sync data/stac s3://stac-floodplains-bc` |
| STAC | `05_stac_register.py` | Generate + validate STAC collection and items |

The tree-loss numbers (`gross_loss_ha`, `gross_gain_ha`, `net_ha`) are computed at register
time from each WSG's `transition_<sp>_ff04_2017_2023` gpkg layer (`from_class == "Trees"` vs
`to_class == "Trees"`, summing `area_ha`) — so the published figures trace directly to the
modelled transition patches.

Catalog load runs on the geoserv server via `stac_register-pypgstac.sh` (in `rtj`), not here.
