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

### Phase 1 — the writer (done)

- `scripts/fp_gpkg.R`: `gpkg_layer_keys()`, `gpkg_own_layers()`, `gpkg_copy_layers()`, plus
  the multi-layer measurement in the SCOPE header.
- Plan review 1 landed mid-phase (`review-1.md`). Fourteen findings adopted, two of them
  changing Phase 1 itself: the scenario-set key for `floodplain.gpkg` (G2) and the
  once-per-group key reading (O8) are in the helpers as written. Re-verified G2's keep-set
  equality claim independently (24 of 24 areas identical) before adopting it.
- Next: Phase 2 — `01_stage.R`.

### Phase 2 — staging writes the filtered bundles (done)

- `01_stage.R`: the two `file.copy()` calls replaced by `gpkg_copy_layers()` over
  `gpkg_own_layers()`; the group's keys read once before the target loop with the two
  refusals (unattributable layer, foreign `wsg`) there; the per-group unclaimed census after
  it; the aspatial and unknown-family reports per item; and `fp_gpkg` repointed at the
  staged copy.
- Measured on the real tree:
  - `WSG_ONLY=larl` — 3 + 4 layers both sides, a content no-op, as a group with no foreign
    layers must be.
  - `WSG_ONLY=morr` — `floodplain.gpkg` 13 -> 4 layers (24.5 -> 12.2 MB),
    `floodplain_landcover.gpkg` 22 -> 6 (91.8 -> 23.1 MB). The item no longer carries MORR's
    coho or chinook floodplains. Both reports fired with the key printed beside each layer.
- **`Rscript scripts/stage_years-check.R`: 14 assertions, 0 failed, 0 skipped** — including
  `PIN_META_SHA256`, the only byte-pin on `meta.json` in the repo. So reading the areas,
  bbox and geometry from the staged copy rather than the source moved **no published
  number**. The pin fired rather than skipping, so that is a measurement and not a silence.

### Phase 3 — the guards (done)

- `test_pipeline.R`: the per-layer arm now asserts all three key columns, over a
  `gpkg_contents.data_type` filter rather than a geometry filter — the geometry filter
  excluded exactly the aspatial tables the stage now selects (review AC19). Verified on a
  styled file that `layer_styles` carries no `gpkg_contents` row, so the new filter excludes
  it structurally rather than by name. A second arm compares the staged layer set against the
  source's own key table.
- `gpkg_determinism-check.R`: rewritten to three arms, the two multi-layer ones reading the
  **producer's** files rather than the staged copies (review AC20) — the staged copies are
  themselves `gpkg_copy_layers()` output, so re-translating one would prove the weaker claim.
  Skips out loud when `$FLOODPLAINS_DATA` is absent. The cold path now requires **every** arm
  to differ, not one.

#### Every refusal fired, each against the mutation only it can see

| guard | mutation | result |
|---|---|---|
| `test_pipeline` per-layer key | the pre-#80 whole-file copy restored | red: `classified_ch_ff06_2017 … is keyed MORR/ch/ch_ff06 but item morr_all_ff04 is MORR/all/all_ff04` |
| `test_pipeline` layer set | one of the item's OWN layers dropped, so every shipped layer is correctly keyed and the arm above cannot fire | red: `holds 5 layer(s) but the source's 22 include exactly 6 … missing: composition_all_ff04_2017_2023` |
| `01_stage` foreign wsg | `UPDATE bt_ff02 SET wsg='BULK'` in a sandbox copy | red, naming the group and the consequence |
| `01_stage` empty own set | `species='xx'` on every floodplain layer | red, printing the keys present |
| `01_stage` all-aspatial own set | `species='xx'` on ufra's feature layers, leaving `patch_watercourse_*` | red, naming the step that would otherwise fail three later |
| `01_stage` missing key column | `ALTER TABLE bt_ff06 DROP COLUMN species` | red: `1 layer(s) carry no usable item key … [absent: species]` |
| `gpkg_copy_layers` empty request | `layers = character(0)` | red |
| determinism, cold path | `NO_PIN=1` | all three arms DIFFER |

- End to end: `WSG=larl` and `WSG=morr` both PASS stage -> tag -> COG -> style -> STAC ->
  validate. MORR's styled bundle drops from ~30 style rows to 9.
- **Correction landed this phase.** The plan's claim that `gdal_utils()` "only warns" on a
  missing layer was a probe artifact — `tryCatch(error =, warning =)` takes the warning first
  and never reaches the error. It does both. The plan review's independent code read was
  right and the probe was not; `findings.md` and `review-1.md` carry the corrected
  measurement, and the guards stay for corrected reasons.
