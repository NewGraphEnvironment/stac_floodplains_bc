# Task: Publish in_wsg and in_open_water: items are split at the group line, and headline metrics should read in_wsg (#98)

## Problem

Published items say nothing about which of their ground is inside their own watershed group
(`in_wsg`) and which is open water (`in_open_water`). The gpkg assets already carry the new
columns once they are restaged, but the item schema does not describe them. The headline metrics
also switch silently from clipped to whole-footprint figures: PCEA's gross change would roughly
triple, because most of the change in that item lies in Williston's arms in PARS and FINA.

Upstream: floodplains#53 and floodplains#138, in floodplains#144. All 23 rostered groups were
backfilled 2026-10-18.

## Scope of change

| property | today | after |
|---|---|---|
| `floodplain_ff02/04/06_km2` | whole footprint | **`in_wsg` only** (value moves) |
| `gross_loss_ha` / `gross_gain_ha` / `net_ha` | clipped (== `in_wsg`) | `in_wsg` only (value held) |
| `floodplain_ff02/04/06_footprint_km2` | — | new, whole footprint |
| `gross_loss_footprint_ha` / `gross_gain_footprint_ha` / `net_footprint_ha` | — | new |

Decisions taken at the plan gate (airvine, 2026-10-19): sibling suffix `_footprint_`; all six
metrics get a sibling; release is **v2.1.0**.

The item's `geometry`, `bbox` and `proj:bbox` stay whole-footprint and are not rescoped: the COGs
cover that ground, and a STAC geometry must contain its assets. `st_union()` over two pieces of
what was one polygon is the same geometry, so this is a no-change to verify, not a change to make.

`DEPRECATED_ITEMS` / `RETIRED_ITEMS` stay empty. No item id moves, no asset is added or retired.

**`--only` is not merely declined, it is unusable** (plan review G2): `only_preflight.py`'s
value and shape arms both filter on the four declared prefixes, and every metric property is
unprefixed, so a `--only` republish in the window before v2.1.0 would print `0 lost` and
publish one item whose `floodplain_ff04_km2` means something different from the other 22 live
items — permanently, on a bucket with versioning Suspended. Phase 3 adds the metric names to
that file's shape arm so the construct refuses itself. `--skip-sync` is unusable too: all three
asset families change.

## Phase 1: Stage both scopes (`scripts/01_stage.R`)

- [x] `tree_transition_metrics()`: refuse when the transition layer carries no `in_wsg` column,
      then return six numbers — the existing three over `in_wsg` rows plus three `*_footprint_*`
      over all rows. Keep `round(, 1)`, keep `net = gain - loss` per scope.
- [x] `read_area_km2()`: same shape — require `in_wsg`, return the `in_wsg` area and the all-rows
      area for each of ff02/ff04/ff06.
- [x] `meta` gains the six `*_footprint_*` fields.
- [x] Per-item STDOUT line prints both scopes.
- [x] Leave `fp` / `st_union` / `bbox` alone.

## Phase 2: Publish surface

- [x] `02_raster_tag.py` `SHARED_FIELDS` += the six.
- [x] `item_create.py` publishes the six beside the existing six.
- [x] `item_create.py` prose — module docstring, collection `description` (APPEND, never reword:
      `check_citation_premise` tests `EXPECTED_DERIVATION_STATEMENT` by containment), and all three
      GeoPackage asset descriptions. `transition_vector` has no description today and gains one.
- [x] `item_validate.py` `SHARED_TAG_PROPERTIES` += the six.
- [x] `prov_fields-check.py` static `SHARED` fixture += the six, pinned by a new
      `assert set(SHARED) == SHARED_TAG_PROPERTIES` (the name was imported and unused).
- [x] ~~Synthetic `meta.json` fixtures in `year_sets-check.py`~~ — measured false: it imports
      `check_checksums` alone and builds item JSON, never `meta.json`, so nothing to change.

## Phase 3: Guards

- [x] `item_validate.py` — new `check_metric_scopes()`, four arms (see progress.md): all twelve present; each
      `in_wsg` figure within its footprint sibling in the right direction; `net == gain - loss`
      within rounding in both scopes.
- [x] `test_pipeline.R` — `in_wsg` joins the required column set for every staged data layer
      (measured: all 246 whole-network layers over the 23 rostered groups carry it; the 222
      that do not are the retired species layers #80 never stages).
- [x] `test_pipeline.R` — keep `DISTINCT wsg, species, scenario` at one row; add an arm that every
      distinct `in_wsg` value is 0 or 1 with at least one row. Leave the source-side twin keyed on
      the three columns only (it *selects* on `nrow(k) == 1L`).
- [x] `test_pipeline.R` `meta_core` += the six.
- [x] `test_pipeline.R` positive-metric arms extended to the siblings, plus both net identities.

## Phase 3b: What the plan review found (spawned at scaffold, landed mid-Phase-4)

Verified each before acting; the ones I disproved or reclassified are named in `findings.md`.

- [ ] **B2** `METRIC_SCOPE_CENSUS` is asserted on a plain rebuild, unlike every literal it
      claims to copy: `PROV_CENSUS` is asserted only under `--expect-provenance`. Gate it the
      same way, and correct the comment that says it already is.
- [ ] **B3** The measured straddle counts are never printed, only the literal — the exact trap
      `PROV_CENSUS`'s own comment records ("a number nobody can read is a literal nobody
      updates"). Print them unconditionally beside the `census:` line.
- [ ] **B4** Nothing pins `02_raster_tag.SHARED_FIELDS` to `item_validate.SHARED_TAG_PROPERTIES`,
      and the add direction is unguarded for these tags: `check_cog_tags`'s `managed` set unions
      `NGE_`-prefixed tags only, so an unprefixed tag with no entry in the literal is invisible.
      Add the static pin in `prov_fields-check.py`, modelled on the `PROV_FIELDS` arm.
- [ ] **B5** The `in_wsg` claim the asset descriptions now publish on 23 items is checked on
      ONE item, by `test_pipeline.R`, which neither `run_pipeline.sh` nor `catalogue_release.sh`
      runs. Add the column + value-set arm to `item_validate.py`.
- [ ] **Acc1** Nothing proves `check_metric_scopes` fires — the `SHARED` fixture is built to
      satisfy it. Add restore-the-bug cases: a swapped pair, an inconsistent net, and two
      identical scopes across the tree (the census arm).
- [ ] **G2** Add the metric names to `only_preflight.py`'s shape arm (see above).
- [ ] **G3/G5** `01_stage.R`: the `in_wsg` refusal covers two layer families, not every data
      layer — B5 is the fix, not a second staging arm. And the "seventeen fields" comment is now
      23.

Accepted without change, recorded because they are checked non-claims:

- **O2** No `styles/` regeneration: the outside rows draw from the same 10-class vocabulary, so
  `EXPECTED_STYLE_CATEGORIES` (10 / 91) cannot find a new uncategorized value, and
  `EXPECTED_RAT_ROWS` describes drift's encoding rather than any item's data.
- **Acc4** Nothing in `item_validate.py` compares a published area against a bbox, a geometry or
  a raster window, so scoping the areas while leaving the footprint geometry is internally
  consistent. `proj:*` comes off the raster and cannot move.
- **G1** `readme_functions.R` needs no functional change — the rescoping is what makes its
  provincial total correct. Its two `7,273 km2` comment literals were already stale and are now
  an order of magnitude instead of a figure.

## Phase 4: Prose

- [x] `README.Rmd` — key-column contract, the "filter before summing" warning, the totals sentence.
- [x] `scripts/README.md` metric-derivation paragraph gains the `in_wsg` qualifier.
- [x] `CLAUDE.md` Collection model.
- [x] `NEWS.md` v2.1.0 entry (dated on release).

## Phase 5: Rebuild and verify (no network writes)

**Order is load-bearing, and the plan had it backwards** (plan review B1). `test_pipeline.R`
re-runs the real `01_stage.R`, which wipes both staging trees and drops `PARTIAL_STAGE`, so a
single-group smoke test AFTER the full rebuild destroys it: `gpkg_determinism-check.R` and
`style_determinism-check.py` default to `ITEM=sloc_all_ff04` and would stop, the 23-item
continuity measurement would have one item, and `catalogue_release.sh` refuses the marker.
**Nothing may re-run `01_stage.R` after the full rebuild.** `prov_census-measure.R` is the one
exemption — it reads `$FLOODPLAINS_DATA` and never touches `data/`.

- [x] `WSG=bulk Rscript scripts/test_pipeline.R` — single group, first, while the tree is
      disposable
- [ ] `WSG=pcea Rscript scripts/test_pipeline.R` — the straddle outlier, where the two scopes
      are 42% apart
- [ ] `bash scripts/run_pipeline.sh` — and nothing single-group after it
- [ ] Hand-run `prov_fields-check.py`, `gpkg_determinism-check.R`, `style_determinism-check.py`,
      `year_sets-check.py`, `attribution_drift-check.py`, `catalogue_release-check.sh`
- [ ] `stage_years-check.R` — the only thing that exercises `in_wsg_flag()`'s refusals on a
      tree that is not `data/`. Its `PIN_META_SHA256` arm is expected to print SKIP (the pin is
      `ufra_ch_ff04`'s build and floodplains#125 moved UFRA to `all_ff04`), so the skip is not
      a regression
- [ ] `prov_census-measure.R`, then run the RELEASE-shaped validate (`--expect-provenance 23`)
      and expect **no** census movement: `run.datetime_utc` is untouched upstream and every
      raster's mtime predates its landcover stamp, so nothing should have moved. Re-take only a
      number that actually moved, and name it in NEWS with the reason
- [ ] Continuity measurement over all **23** items against the **live API**, item by item, into
      `findings.md`: `in_wsg` loss/gain/net equal to live; `*_footprint_km2` equal to live
      `floodplain_ffNN_km2`; and `bbox_wgs84` plus the geometry coordinate count diffed, with a
      note on whether any *printed* coordinate moved (the split/union round trip perturbs at
      ~1e-11 and `digits = 10` sits on that boundary — so this is measured, not asserted)
- [ ] Sanity-check the two watched value-set arms; record BULK + PCEA numbers
- [ ] **Do NOT render `README.md` / `index.html`.** The new prose says the column totals count
      no ground twice, while the cache is v2.0.1 and the committed table reads 10,611 km² — the
      footprint sum. Measured: in_wsg 10,092.27, footprint 10,611.35, difference 519.08 km²;
      loss and gain do not move. The regen is release step 6, after the release

## Phase 6: Release v2.1.0

Outside the PR mandate — run by the user, or on explicit instruction.

- [ ] NEWS committed, tag cut by hand on it, tree clean
- [ ] `AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=10 bash scripts/catalogue_release.sh`
- [ ] Verify on the bytes a consumer downloads, not on `RELEASE COMPLETE`
- [ ] Push the tag only after the release succeeds; then release step 6 (README regen)

## Validation

- [ ] `run_pipeline.sh` + `test_pipeline.R` pass
- [ ] `/code-check branch` clean (three-round floor)
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
