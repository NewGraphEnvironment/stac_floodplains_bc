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
No `--only`.

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

- [ ] `02_raster_tag.py` `SHARED_FIELDS` += the six.
- [ ] `item_create.py` publishes the six beside the existing six.
- [ ] `item_create.py` prose — module docstring, collection `description` (APPEND, never reword:
      `check_citation_premise` tests `EXPECTED_DERIVATION_STATEMENT` by containment), and all three
      GeoPackage asset descriptions. `transition_vector` has no description today and gains one.
- [ ] `item_validate.py` `SHARED_TAG_PROPERTIES` += the six.
- [ ] `prov_fields-check.py` static `SHARED` fixture += the six.
- [ ] Synthetic `meta.json` fixtures in `prov_fields-check.py` / `year_sets-check.py` gain the six.

## Phase 3: Guards

- [ ] `item_validate.py` — new per-item arm over the twelve metrics: all twelve present; each
      `in_wsg` figure within its footprint sibling in the right direction; `net == gain - loss`
      within rounding in both scopes.
- [ ] `test_pipeline.R` — `in_wsg` joins the required column set for every staged data layer.
- [ ] `test_pipeline.R` — keep `DISTINCT wsg, species, scenario` at one row; add an arm that every
      distinct `in_wsg` value is 0 or 1 with at least one row. Leave the source-side twin keyed on
      the three columns only (it *selects* on `nrow(k) == 1L`).
- [ ] `test_pipeline.R` `meta_core` += the six.
- [ ] `test_pipeline.R` positive-metric arms extended to the siblings.

## Phase 4: Prose

- [ ] `README.Rmd` — key-column contract, the "filter before summing" warning, the totals sentence.
- [ ] `scripts/README.md` metric-derivation paragraph gains the `in_wsg` qualifier.
- [ ] `CLAUDE.md` Collection model.
- [ ] `NEWS.md` v2.1.0 entry.

## Phase 5: Rebuild and verify (no network writes)

- [ ] `bash scripts/run_pipeline.sh`
- [ ] `Rscript scripts/test_pipeline.R`
- [ ] Hand-run `prov_fields-check.py`, `gpkg_determinism-check.R`, `style_determinism-check.py`,
      `year_sets-check.py`
- [ ] `prov_census-measure.R`, then re-take `PROVENANCE_FLOOR` + `PROV_CENSUS` from this build
- [ ] Continuity measurement over all 23 items into `findings.md`
- [ ] Sanity-check the two watched value-set arms; record BULK + PCEA numbers

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
