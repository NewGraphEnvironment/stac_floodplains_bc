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
