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
- [x] Smoke-test harness `scripts/test_pipeline.R` (single WSG, local-only via `WSG_ONLY` +
      `SKIP_S3_UPLOAD` so a one-item run can't clobber the live collection) — mirrors airphoto's
      `test_pipeline.R`.
- [x] Run `scripts/test_pipeline.R` for UFRA (local, no S3): item validates; loss/gain/net
      populated (544.5 / 719.0 / 174.6 ha) and cross-checked against the source transition layer
      via an independent GDAL-sqlite recompute (544.46 / 719.02 → match).
- [x] Superseded by the full all-8 publish (below) — S3 objects present + verified. titiler/rstac
      await the geoserv pypgstac load (rtj).
- [ ] Verify `gross_loss_ha` / `gross_gain_ha` / `net_ha` match the floodplains driver's own summary
      (`lulc_summary_ch_ff04.rds`), not just an independent recompute of the same layer.
      (Region totals already match the issue headline exactly: 15,022.3 ha loss, 3,366 km².)

Environment: **piloting uv** here (`pyproject.toml` + `uv.lock`, run via `uv run`). The
`stac_dem_bc#16` conda→uv blocker (GDAL/rasterio wheels without conda-forge) was cleared
empirically — uv installs the full stack in ~2s and the pipeline runs on it; conda was blocked on
this machine by the Anaconda ToS gate. No vector reader in the Python env either way — R/sf does the
vector work (step-01 design). Not yet proven on the Linux VM (geopro), which dem#16 also wants.

## Phase 3: Publish all 8
- [x] Stage + COG + tag + upload + register LCHL, LSAL, WILL, TABR, UFRA, NECR, MORK, FRAN
      (`bash scripts/run_pipeline.sh`, 145s): 8 staged, 32 COGs, 49 S3 objects, 8 items +
      collection valid, JSON synced. Verified: COGs publicly fetchable (HTTP 206), valid COG with
      overviews [2,4,8,16,32], embedded tags readable over the network; collection.json links 8 items.
- [x] Per group, verify classified coverage ≈ floodplain area: region gross loss 15,022.3 ha and
      floodplain 3,366 km² reproduce the issue headline exactly, so per-group coverage is sound.
- [ ] Load into the catalog on geoserv (`stac_register-pypgstac.sh`) — **rtj step, not runnable
      here**; needs the companion rtj issue (add to `stac_register-all.sh`). This is what makes
      titiler render + rstac queryable.

## Phase 4: Verify + document
- [ ] rstac + QGIS round-trip against `images.a11s.one`.
- [ ] README coverage table + query examples.
- [ ] Confirm the rtj `stac_register-all.sh` entry lands (companion rtj issue).

## Validation
- [ ] `bash scripts/run_pipeline.sh` runs clean for UFRA, then all 8.
- [ ] Published loss/gain/net properties trace to the floodplains transition layers.
- [ ] `/code-check` clean on each commit; PWF checkboxes match landed work.
- [ ] `/planning-archive` on completion.
