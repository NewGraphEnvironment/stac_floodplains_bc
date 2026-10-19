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

### Phases 2 + 3 - publish surface and guards

One commit, because `item_validate.py` carries both halves.

- `02_raster_tag.py` `SHARED_FIELDS` and `item_validate.py` `SHARED_TAG_PROPERTIES` both gain
  the six. Tagging both scopes rather than only the published one is deliberate: the
  unsuffixed tags CHANGED MEANING, and a COG downloaded before this release carries a
  whole-footprint value under a name that now means in_wsg. It is free - rescoping the three
  area values rewrites every COG anyway.
- `item_create.py` publishes the six, and the prose lands in three places because STAC items
  carry no per-property description: the module docstring, the collection `description`
  (APPENDED - `item_validate.py:247` tests `EXPECTED_DERIVATION_STATEMENT` by containment),
  and all three GeoPackage asset descriptions. `transition_vector.gpkg` had none and gains
  one: it is the file the change figures are aggregated from and the one whose row count
  changed meaning.
- `item_validate.py` `check_metric_scopes()`, wired in before the ~1.3 GB checksum re-read:
  (1) all twelve present and numeric, bool excluded explicitly since it subtracts as 1;
  (2) `in_wsg <= footprint` on the five non-negative pairs (net excluded - signed);
  (3) `gain - loss == net` in both scopes; (4) `METRIC_SCOPE_CENSUS`, the straddle count per
  metric. Arm 4 is the only one that catches a DROPPED in_wsg filter, because two identical
  scopes satisfy arms 1-3. Measured 23/23 on all five over the floodplains#144 tree; dropped
  under `--partial`.
- `test_pipeline.R`: `in_wsg` required on every staged data layer; its distinct values asserted
  to be a non-empty subset of {FALSE, TRUE}; `DISTINCT wsg, species, scenario` deliberately NOT
  widened (the split is geometric, both sides carry the item key); `meta_core` and the
  positive-metric arms extended.

Measurements taken this phase:

- 246 whole-network layers across the 23 rostered groups, all carrying `in_wsg`. The 222
  without it are the retired per-species layers #80 does not stage.
- `gross_gain_ha` in_wsg vs footprint differs on all 23 groups, as does loss and all three
  areas - hence 23 across the board in `METRIC_SCOPE_CENSUS`. BULK in_wsg gain is 1318.7,
  equal to the live item exactly.

Gap noted, out of scope: `only_preflight.py` compares PROVENANCE properties only, so a
`--only` republish would not see a changed metric value. That was already true before #98
(the metrics are unprefixed and `canon()` only reads the four prefixes).
