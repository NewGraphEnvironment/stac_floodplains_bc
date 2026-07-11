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
- Ran the UFRA smoke test — **PASS** end-to-end (stage → COG → tag → register → validate, no S3).
  Loss/gain/net 544.5/719.0/174.6 ha; independently recomputed from the source transition gpkg via
  GDAL-sqlite (544.46/719.02) → matches R/sf. Item + collection validate; PARTIAL_STAGE guard and
  SKIP_S3_UPLOAD both behaved.
- **Migrated conda → uv** (dem#16 pilot). Empirical basis: `uv pip install` of the full stack took
  ~1-2s from PyPI wheels (GDAL 3.12.1 raster I/O verified) and the pipeline's Python steps ran on
  it; conda `env create` failed 3× on the Anaconda ToS gate (defaults channel) — the committed
  `nodefaults` fix doesn't bypass it (base condarc triggers the check). Added `pyproject.toml` +
  `uv.lock`, swapped the two `conda run` calls for `uv run` (auto-syncs), removed `environment.yml`,
  updated README/CLAUDE/scripts docs, gitignored `.venv/`. Re-ran the smoke test through the
  migrated `uv run` path — still PASS. Note: `environment.yml` nodefaults commit `91dc61b` was made
  by a parallel Opus session; now moot (file removed).
- Posted the uv finding to `stac_dem_bc#16` (issuecomment-4947934417).
- **PUBLISHED all 8 to S3** (`bash scripts/run_pipeline.sh`, 145s, exit 0). Bucket was empty →
  clean first publish. 8 WSGs staged, 32 COGs converted + tagged, 190 MiB synced, 8 items +
  collection validate, 9 JSON files uploaded. S3 now holds 49 objects (32 tif + 8 gpkg + 8 item
  json + collection.json), no stray dotfiles. Verified: objects public over HTTPS (206 range
  requests), a COG reads remotely as valid GeoTIFF with overviews [2,4,8,16,32] + embedded tags,
  collection.json links 8 items. Region totals reproduce the issue headline exactly — gross loss
  15,022.3 ha, floodplain 3,366 km².
- Catalog load DONE via **rtj#177** (CLOSED 2026-07-11, by a parallel session): floodplains added
  to `stac_register-all.sh` COLLECTIONS + rtj CLAUDE.md, pypgstac load run on geopro. **Collection
  is LIVE** — verified `GET images.a11s.one/collections/stac-floodplains-bc` → 200 and `/items` →
  all 8 with correct loss/gain/net. End-to-end round-trip (S3 → pgstac → STAC API) confirmed.
- Remaining (all in this repo, non-blocking): README coverage table + query examples; optional QGIS
  round-trip; then `/planning-archive` and PR. Issue #1 is functionally complete — the collection
  is published and queryable.
