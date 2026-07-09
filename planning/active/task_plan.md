# Task Plan — Publish Fraser ff04 floodplain LULC + transition collection (#1)

Publish one STAC item per Fraser watershed group (`ff04`) to `stac-floodplains-bc`, served on
the shared `images.a11s.one` endpoint. No modelling here — stage → COG → tag → upload → register
the outputs already produced by the `floodplains` driver.

## Phase 1: Scaffold pipeline
- [ ] `01_stage.R` — discover WSGs under `$FLOODPLAINS_DATA` (default `../floodplains/data`) that
      have an `ff04` floodplain; copy classified/transition rasters + `floodplain_landcover.gpkg`
      into `data/raw/<wsg>/`. Read species/scenario from `floodplains/config/<wsg>/area.yml`.
- [ ] `02_cog.R` — `terra::writeRaster(..., filetype = "COG", DEFLATE)` → `data/stac/<wsg>/`.
- [ ] `03_cog_tag.py` — rasterio `update_tags`: WSG, SPECIES, SCENARIO, YEAR, FLOODPLAIN_KM2,
      GROSS_LOSS_HA, GROSS_GAIN_HA, NET_HA (loss/gain/net from the transition gpkg layer).
- [ ] `04_s3_upload.R` — `aws s3 sync data/stac s3://stac-floodplains-bc`.
- [ ] `05_stac_register.py` — pystac collection + one item per WSG; raster + vector assets;
      validate.
- [ ] `run_pipeline.sh` — chain 01–05; footer prints the geoserv pypgstac load command.

## Phase 2: Prove end-to-end on one WSG (UFRA)
- [ ] Run the full pipeline for UFRA only.
- [ ] Confirm item validates, S3 objects present, titiler renders a COG, rstac returns the item.
- [ ] Verify `gross_loss_ha` / `gross_gain_ha` / `net_ha` match the floodplains run numbers.

## Phase 3: Publish all 8
- [ ] Stage + COG + tag + upload + register LCHL, LSAL, WILL, TABR, UFRA, NECR, MORK, FRAN.
- [ ] Per group, verify classified coverage ≈ floodplain area before trusting.
- [ ] Load into the catalog on geoserv (`stac_register-pypgstac.sh`).

## Phase 4: Verify + document
- [ ] rstac + QGIS round-trip against `images.a11s.one`.
- [ ] README coverage table + query examples.
- [ ] Confirm the rtj `stac_register-all.sh` entry lands (companion rtj issue).

## Validation
- [ ] `bash scripts/run_pipeline.sh` runs clean for UFRA, then all 8.
- [ ] Published loss/gain/net properties trace to the floodplains transition layers.
- [ ] `/code-check` clean on each commit; PWF checkboxes match landed work.
- [ ] `/planning-archive` on completion.
