# Progress — Publish Fraser ff04 floodplain collection (#1)

## Session 2026-07-09
- Created the repo (private) + scaffold: README, scripts/README (pipeline plan), environment.yml,
  gitignore, CLAUDE.md. Default branch `main`.
- Filed issue #1 (publish Fraser ff04 collection); scaffolded this PWF baseline on branch
  `1-publish-fraser-ff04`.
- Confirmed endpoint model (shared `stac` DB → `images.a11s.one`; no subdomain), bucket region
  (us-west-2), and source-data layout (see findings.md).
- Companion rtj issue to add `stac-floodplains-bc` to `stac_register-all.sh` + CLAUDE.md bucket
  list.
- Phase 1 (scaffold) done: wrote `01_stage.R`, `02_cog.R`, `03_cog_tag.py`, `04_s3_upload.R`,
  `05_stac_register.py`, `run_pipeline.sh`. Confirmed against UFRA source: transition class label
  is `"Trees"`, fields `from_class`/`to_class`/`area_ha`, floodplain CRS EPSG:3005. Publish conda
  env has no vector reader, so metrics + footprint are computed in R (step 01) and passed to the
  Python tag/register steps via `data/raw/<wsg>/meta.json`. All six files syntax-check clean.
- Environment review (across all 5 stac_*_bc repos + issues): family is on **conda**; uv is
  roadmap only (no repo has pyproject/uv.lock). `stac_dem_bc#16` owns the conda→uv migration and is
  OPEN — blocker is whether GDAL/rasterio/rio-cogeo wheels install under uv without conda-forge.
  Decision: floodplains stays on conda, inherits uv when dem lands it. Our `environment.yml` is a
  floor-pinned spec, not a stamped lock (the "no lockfile" gap dem#16 cites); stamp via
  `conda env export` after the env is first built if reproducibility is needed. No conda env in the
  family carries a vector reader — R/sf does vector work everywhere, validating the step-01 design.
- Added `scripts/test_pipeline.R` — single-WSG (default UFRA) local-only smoke test, mirroring
  airphoto's precedent. New flags: `WSG_ONLY` (01) and `SKIP_S3_UPLOAD` (05) keep a one-item test
  run from clobbering the live 8-item collection.
- Next: run `scripts/test_pipeline.R` for UFRA once conda env + `$FLOODPLAINS_DATA` are in place
  (Phase 2), then the real UFRA S3 publish + titiler/rstac verification.
