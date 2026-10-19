# Progress — Publish in_wsg and in_open_water (#98)

## Session 2026-10-19

- Plan-mode exploration: three Explore agents over `01_stage.R` + `fp_provenance.R`,
  `item_create.py` + `item_validate.py`, and `readme_functions.R` + `README.Rmd` +
  `test_pipeline.R` + the `*-check` family.
- Measured the split on disk across all 23 rostered groups before planning (findings.md).
- Three decisions taken at the plan gate (airvine): `_footprint_` suffix, all six metrics get a
  sibling, release is v2.1.0.
- Created branch `98-publish-in-wsg-and-in-open-water-items` off main at `affcd31`.
- Scaffolded PWF baseline with approved phases.
- Next: Phase 1.

### Phase 1 — staged both scopes

- `01_stage.R`: new `in_wsg_flag()` refuses an absent column and an NA value (both proved);
  `tree_transition_metrics()` returns six numbers; `read_area_km2()` → `read_areas_km2()`
  returning both scopes; `meta` gains the six `*_footprint_*` fields; the STAGED line prints
  `in_wsg (footprint)` per figure.
- Verified against BULK's live item: in_wsg loss/gain/net = 2793 / 1319 / -1475 against live
  2793.4 / 1318.7 / -1474.6 (continuity holds), and footprint ff02/04/06 = 611 / 660 / 699
  against live 610.91 / 659.99 / 698.94. in_wsg areas are 599 / 647 / 685.
