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

### Phase 4 — the prose (done)

Every location the review listed, plus the ones found while editing. The premise this issue
overturned was quoted or reasoned from in nine files.

- `catalogue_release.sh` — "the largest asset is an upstream gpkg copied verbatim" was
  *reasoning* for why the `--only` read-back compares wholesale rather than by checksum. The
  conclusion survives on its other leg; the retired leg is recorded as retired, with the
  GDAL-version consequence (review G6).
- `04_gpkg_style.py` — the `floodplain.gpkg` catch-all was sound while the layers were
  inherited and is a selection we make now.
- `item_validate.py` — "nine invisible layers per item" is three or four.
- `style_qml-write.py`, `scripts/README.md`'s style table — `_patches` exists only on MORR's
  retired families upstream, so no published item ships one.
- `item_create.py` — both GeoPackage assets gained a `description` saying the file holds one
  item's layers, which is the one thing a consumer cannot see without opening it.
- `README.Rmd` — a new paragraph on what merging N items now gives you. **Not re-rendered:**
  regenerating `README.md` / `index.html` is release step 6, past the tag (#55).
- `readme_functions.R` — the "~140 kB to ~9 MB" range was measured on the old bundles.
- `scripts/README.md` — the `~670 MB` / `700 MB` figures were already inconsistent with the
  two bundles alone being 827 MB, so they were replaced with the figure actually measured
  rather than with one derived from a stale base.
- `CLAUDE.md` — a new paragraph on the write and its selection rule, the undescribed-tables
  paragraph now about **two** tables with what still has no cover named, and the
  `OGR_CURRENT_DATE` paragraph rewritten: the pin covers all three GeoPackages, and no
  published asset is a verbatim upstream copy any more.
- `NEWS.md` — one entry under Unreleased, with the measured volume change and the #76 tie.

#### Published volume, measured over all 23 rostered groups

`826.9 -> 642.9 MB`, 184 MB less to publish. MORR -70% (116.3 -> 35.4), BULK -36%
(169.0 -> 107.8), KISP -35% (57.2 -> 37.0); the remaining 20 shrink 0-19% from repacking
alone, which is why every item's `file:checksum` for both assets moves and not only the three.

#### Whole suite, after the prose and the asset-description change

| check | result |
|---|---|
| `WSG=morr test_pipeline.R` | PASS end to end |
| `WSG=larl test_pipeline.R` | PASS end to end |
| `stage_years-check.R` | 14 assertions, 0 failed, 0 skipped |
| `fp_provenance-check.R` | 87 assertions, 0 failed, 0 skipped |
| `prov_fields-check.py` | 44 assertions, 0 failed |
| `year_sets-check.py` | 16 assertions, 0 failed |
| `catalogue_release-check.sh` | ALL PASS |
| `attribution_drift-check.py` | matches |
| `style_drift-check.py` | 3 styles byte-identical |
| `style_determinism-check.py` | 3 GeoPackages byte-identical, re-run a no-op |
| `gpkg_determinism-check.R` | 3 arms MATCH; `NO_PIN=1` all 3 DIFFER |

### Validation — roster-wide (done)

`ALLOW_DRIFT_SKEW=1 Rscript scripts/01_stage.R` over the whole roster: **23 staged, 0 skipped**,
no `PARTIAL_STAGE`, 21 of 23 carrying run provenance (`PROVENANCE_FLOOR`'s literal, unmoved).
The census named exactly BULK, MORR and KISP, and the unknown-family report printed nothing —
so no staged layer across the catalogue sits in a family this repo does not know.

Then an independent check over all 23 staged items (`sqlite3` only, no `fp_gpkg.R`, so it
shares no code with the selector):

| assertion | result |
|---|---|
| staged layer set is a subset of the upstream file's | 46 / 46 files |
| `<sp>_ff02/04/06` and the item's `transition_<scen>_<span>` present | 23 / 23 items |
| every staged layer keyed to its own item (`wsg`, `species`, and `scenario` in the item's ff set for `floodplain.gpkg` / the item scenario for the landcover bundle) | all 218 layers |
| two bundles on disk | **642.9 MB** |

That 642.9 MB is the same number the volume measurement reached through `gpkg_copy_layers()`
into a tempdir, from a different code path — the published tree and the projection agree.

`AREA=morr` and `AREA=bulk Rscript scripts/stage_years-check.R`: 13 assertions, 0 failed, 1
skipped each — the skip is the `PIN_META_SHA256` arm, which is ufra_ch_ff04's digest and says
so, and it is the arm's own documented refusal to describe another area rather than a silence.
So the 25- and 14-foreign-layer paths both run through the real `01_stage.R` call site in a
sandbox, with all three year-set defect arms restored and caught.

### Code-check round 1 — 5 findings, all fixed

Reviewer report: `planning/active/review-round1.md`. Every finding reproduced before it was
acted on; the reviewer also re-derived every prose number in the diff independently and found
none wrong.

**The bug was inside my own fix.** `gpkg_copy_layers()`'s warning guard captured the GDAL
warning, muffled it, and raised *after* the call — but `gdal_utils()` raises on the same call,
which unwound `withCallingHandlers()` before that line could run. The captured text was
discarded and the muffle suppressed the one place it would have printed, so the operator got
`gdal_utils vectortranslate: an error occured` and nothing else: **strictly worse than having
no handler**, since R otherwise prints the warning beside the error. Reproduced, and visible in
my own Phase 1 probe output, which I had misread as `-f GPKG` changing the failure path rather
than as my guard's message never appearing. Now both conditions are captured and joined into
one message, and the layer name is back.

A second defect came out of chasing the reviewer's minor note that the determinism arms
translate in a different layer order than the stage. **Layer order changes the bytes** —
measured: BULK's four floodplain layers written in reverse give an identical file size and a
different md5. So the published `file:checksum` depended on `st_layers()` order, a GDAL
implementation detail, and `gpkg_determinism-check.R` (which orders by `table_name`) had been
proving the reproducibility of a file the stage does not write. `gpkg_copy_layers()` now sorts
internally, with `method = "radix"` so the order is C-locale bytes rather than the operator's
`LC_COLLATE`. The determinism arms' md5s now equal the staged files' md5s exactly
(`7152a8bde62f…`, `c74432f94f21…`).

| finding | fix | proof |
|---|---|---|
| 1 warning guard unreachable, layer name lost | capture the error too, join both into one message | the message now contains `nope_missing` |
| 2a a documented skip became a hard stop (bundle check hoisted above the no-rasters skip, upstream of `PARTIAL_STAGE` and `ALLOW_SKIPPED`) | missing bundle is a group **SKIP**, recorded in `skipped` | full run, one group's bundle removed: `PARTIAL_STAGE written — 22 target(s) skipped`, and `ALLOW_SKIPPED=1` reaches its own branch with no marker. (The earlier `WSG_ONLY` attempt could never reach it: `01_stage.R:174` writes the marker for `WSG_ONLY`, so the block short-circuits — pre-existing and documented.) |
| 2b a skipped target's layers reported as upstream's retired targets | own sets and the group claim computed **before** the raster skip, from declared targets | sandbox with `rasters/` removed: `SKIPPED`, and no "match no target" line at all |
| 3 the layer-set arm derived its expectation from the selector it checks | expectation re-derived in SQL (a second implementation), **plus** an absolute floor of layer names built from `meta.json` and the item id | selector made to drop every `classified_*`: the SQL arm fires. Source *and* selector both missing `classified_bt_ff04_2020`, so the SQL arm agrees: the floor arm fires |
| 4 `NA` `data_type` made the all-aspatial refusal pass vacuously (`x[c(TRUE,NA)]` yields an NA element) | `%in% "features"` / `%in% "attributes"` | gpkg_contents rows deleted for the feature layers: the refusal fires, naming all four |
| 5 a layerless GeoPackage raised `arguments imply differing number of rows: 0, 1` | explicit precondition naming the file | **not reproduced** — dropping the last table makes GDAL refuse to open the file at all, so the case may be unreachable. Kept as a cheap precondition that refuses rather than passes, and recorded as unproven |

Minor notes also taken: the `floodplain.gpkg` asset description said "ff02/ff04/ff06" while 18
of 23 items also ship `_by_blue_line_key`; `gpkg_determinism-check.R` guarded only one of the
two source paths; and a pre-existing wrong claim (#75) that `lit` and `logs` are areas carrying
no `provenance.json` — they are a reference-PDF folder and a log folder, with no
`config/<wsg>/` at all, so the stage never walked them.

Re-validated after the fixes: roster-wide 23 staged / 0 skipped, independent audit 46/46 and
23/23 at 642.9 MB, `WSG=morr` PASS end to end, determinism 3 arms MATCH and all 3 DIFFER cold.
