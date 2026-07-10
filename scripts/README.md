# scripts

Publish pipeline for the `stac-floodplains-bc` collection. Reads the already-produced
floodplain outputs from `$FLOODPLAINS_DATA` (default `../floodplains/data`) — this repo does
no floodplain modelling.

Run end-to-end: `bash scripts/run_pipeline.sh`

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover the Fraser-region WSGs with an `ff04` floodplain; copy the classified/transition rasters into `data/raw/<wsg>/` and the `floodplain_landcover.gpkg` into `data/stac/<wsg>/`; derive per-WSG metrics + footprint → `data/raw/<wsg>/meta.json` |
| COG | `02_cog.R` | Convert the staged rasters to Cloud-Optimized GeoTIFFs → `data/stac/<wsg>/` |
| Tag | `03_cog_tag.py` | Embed GDAL metadata tags from `meta.json` (WSG, species, scenario, region, floodplain km², gross loss/gain/net ha, per-asset year) |
| S3 | `04_s3_upload.R` | `aws s3 sync data/stac s3://stac-floodplains-bc` (COGs + gpkg; JSON handled by 05) |
| STAC | `05_stac_register.py` | Generate + validate the STAC collection and one item per WSG; upload the JSON to S3 |

The tree-loss numbers (`gross_loss_ha`, `gross_gain_ha`, `net_ha`) are computed once, during
staging, from each WSG's `transition_<sp>_ff04_2017_2023` gpkg layer (`from_class == "Trees"` vs
`to_class == "Trees"`, summing `area_ha`) and written to `meta.json` — so the tag and register
steps publish identical figures that trace directly to the modelled transition patches. Metrics
are computed in R (step 01) because the publish conda env carries no vector reader.

Catalog load runs on the geoserv server via `stac_register-pypgstac.sh` (in `rtj`), not here.
