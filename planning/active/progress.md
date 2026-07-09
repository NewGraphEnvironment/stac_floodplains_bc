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
- Next: Phase 1 — implement `01_stage.R` … `05_stac_register.py` + `run_pipeline.sh`.
