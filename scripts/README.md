# scripts

Publish pipeline for the `stac-floodplains-bc` collection. Reads the already-produced
floodplain outputs from `$FLOODPLAINS_DATA` (default `../floodplains/data`) — this repo does
no floodplain modelling.

Run end-to-end: `bash scripts/run_pipeline.sh`

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover rostered WSGs with an `ff04` floodplain; copy the classified/transition rasters into `data/raw/<wsg>/` and both `floodplain_landcover.gpkg` + `floodplain.gpkg` (ff02/ff04/ff06 delineations) into `data/stac/<wsg>/`; derive per-flood-factor floodplain areas + tree metrics + footprint → `data/raw/<wsg>/meta.json` |
| COG | `02_cog.R` | Convert the staged rasters to Cloud-Optimized GeoTIFFs → `data/stac/<wsg>/` |
| Tag | `03_cog_tag.py` | Embed GDAL metadata tags from `meta.json` (WSG, species, scenario, region, floodplain area per flood factor ff02/ff04/ff06 km², gross loss/gain/net ha, per-asset year) |
| S3 | `04_s3_upload.R` | `aws s3 sync data/stac s3://stac-floodplains-bc` (COGs + gpkgs; JSON handled by 05) |
| STAC | `05_stac_register.py` | Generate + validate the STAC collection and one item per WSG; upload the JSON to S3 |

The tree-loss numbers (`gross_loss_ha`, `gross_gain_ha`, `net_ha`) are computed once, during
staging, from each WSG's `transition_<sp>_ff04_2017_2023` gpkg layer (`from_class == "Trees"` vs
`to_class == "Trees"`, summing `area_ha`) and written to `meta.json` — so the tag and register
steps publish identical figures that trace directly to the modelled transition patches. Metrics
are computed in R (step 01) because the publish Python env carries no vector reader.

## Smoke test

`test_pipeline.R` runs one watershed group end-to-end (`stage → COG → tag → STAC`)
**without touching S3** — it builds and validates the item locally. Use it after any
change to the scripts, the floodplains data layout, or the STAC schema, before a real
all-8 publish.

```
Rscript scripts/test_pipeline.R            # defaults to UFRA
WSG=necr Rscript scripts/test_pipeline.R   # any Fraser WSG
```

It relies on two flags the pipeline scripts honour: `WSG_ONLY=<wsg>` restricts `01_stage.R`
to a single group, and `SKIP_S3_UPLOAD=1` makes `05_stac_register.py` build + validate
locally without uploading — so a one-item test run can never clobber the live 8-item
collection.

Catalog load runs on the geoserv server via `stac_register-pypgstac.sh` (in `rtj`), not here.
