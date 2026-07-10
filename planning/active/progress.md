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
- Next: Phase 2 — run the full pipeline for UFRA only and verify item/S3/titiler/rstac round-trip
  and that loss/gain/net match the floodplains numbers.
