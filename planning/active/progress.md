# Progress — Stage each item's GeoPackages with only that item's layers (#80)

## Session 2026-10-14

- Plan-mode exploration: read `01_stage.R`, `fp_gpkg.R`, `test_pipeline.R`,
  `04_gpkg_style.py`, `gpkg_determinism-check.R`, `item_validate.py`, `catalogue_release.sh`,
  `stage_years-check.R`, and the two decisions in #75's body.
- Measured the upstream layer census (276 layers, 24 areas), the per-file key asymmetry, the
  `vectortranslate` determinism arms, and the size effect. All in `findings.md`.
- Two forks taken to the plan gate and decided by the user: a layer matching no item is
  **reported, not refused**; the aspatial tables are **reported, not whitelisted**.
- Created branch `80-stage-each-item-s-geopackages-with-only` off main.
- Scaffolded the PWF baseline from the approved plan.
- Next: Phase 1 — the writer in `scripts/fp_gpkg.R`.
