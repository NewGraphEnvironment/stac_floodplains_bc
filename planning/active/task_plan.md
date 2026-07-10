# Task Plan — Publish Fraser ff04 floodplain LULC + transition collection (#1)

Publish one STAC item per Fraser watershed group (`ff04`) to `stac-floodplains-bc`, served on
the shared `images.a11s.one` endpoint. No modelling here — stage → COG → tag → upload → register
the outputs already produced by the `floodplains` driver.

## Phase 1: Scaffold pipeline
- [x] `01_stage.R` — discover Fraser-region WSGs under `$FLOODPLAINS_DATA` (default
      `../floodplains/data`) with an `ff04` floodplain; copy classified/transition rasters into
      `data/raw/<wsg>/` + `floodplain_landcover.gpkg` into `data/stac/<wsg>/`. Reads
      species/scenario from `config/<wsg>/area.yml`; derives floodplain km², footprint geometry,
      and loss/gain/net from the transition layer into `data/raw/<wsg>/meta.json` (sidecar the
      Python steps consume, since the conda env has no vector reader).
- [x] `02_cog.R` — `terra::writeRaster(..., filetype = "COG", DEFLATE, NEAREST overviews)` →
      `data/stac/<wsg>/`.
- [x] `03_cog_tag.py` — rasterio `update_tags` from `meta.json`: WSG, SPECIES, SCENARIO, REGION,
      FLOODPLAIN_KM2, GROSS_LOSS_HA, GROSS_GAIN_HA, NET_HA, per-asset YEAR/span.
- [x] `04_s3_upload.R` — `aws s3 sync data/stac s3://stac-floodplains-bc` (COGs + gpkg).
- [x] `05_stac_register.py` — pystac collection + one item per WSG; raster + vector assets;
      footprint geometry + loss/gain/net properties; validate; upload JSON to S3.
- [x] `run_pipeline.sh` — chain 01–05; footer prints the geoserv pypgstac load command.

  Phase 1 is scaffold-only: all six files written and syntax-checked (R parse, `py_compile`,
  `bash -n`). End-to-end execution against real data is Phase 2.

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
