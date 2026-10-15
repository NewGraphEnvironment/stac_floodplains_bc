# Task: Complete the whole-network cutover in one release at v2.0.0 (#89)

The collection serves 23 per-species items (`<wsg>_<sp>_ff0N`). Upstream (floodplains#125)
retired the `targets:` blocks, so every rostered group now models the whole stream network and
a rebuild here produces 23 `<wsg>_all_ff04` items instead. Registration is an upsert, so
without an explicit retirement every converted group would serve two floodplains built on
different networks and different DEM grids, with nothing in the items saying which is current.

One release, at `v2.0.0`: retire all 23 live ids and publish all 23 whole-network ones in one
upsert. `NEWS.md` reserves `v2.0.0` for exactly this.

**Measured 2026-10-15T20:43Z** (`Rscript scripts/prov_census-measure.R`, producer `760b8d9-dirty`):
23 rostered / 23 staged / floor 23; `link_run_uid` 18, the other eleven 23. `drift` 0.20.0
installed matches every record. Live API: exactly the 23 species ids.

**Scope:** run through `RELEASE COMPLETE`. `item_retract_s3.sh` and the README regen are handed
over (airvine, 2026-10-15).

## Phase 1: Empty the deprecation literals, before the build

- [x] `DEPRECATED_ITEMS = set()` — `scripts/item_create.py:91`
- [x] `EXPECTED_DEPRECATED = set()` — `scripts/item_validate.py:258`
- [x] Keep both comment blocks; record that the marker self-cleared

## Phase 2: Rebuild, and take the numbers from the build

- [x] `bash scripts/run_pipeline.sh` (no `ALLOW_SKIPPED`, no `ALLOW_DRIFT_SKEW`)
- [x] No `PARTIAL_STAGE`, 23 items, all `<wsg>_all_ff04`
- [x] Record `01_stage.R`'s aspatial-table and unclaimed-layer reports (reported, not refused)
- [x] Capture `item_validate.py`'s `census:` line — the authority

## Phase 3: Set every literal, from the build

- [x] `PROVENANCE_FLOOR` — `scripts/catalogue_release.sh:61`
- [x] `PROV_CENSUS` — `scripts/item_validate.py:540`
- [x] `scripts/prov_fields-check.py`: fixture populations and every fixture-derived number that
      moves with them; the all-absent population stays
- [x] `RETIRED_ITEMS` — `scripts/catalogue_release.sh:80` — exactly the 23 live ids
- [x] `ALLOWED_YEAR_SETS` unchanged: both tuples still occupied

## Phase 4: Prove the guards before the release gate does

- [x] `item_validate.py --expect-provenance <floor>`
- [x] `prov_fields-check.py`
- [x] `style_drift-check.py`, `style_determinism-check.py`, `attribution_drift-check.py`,
      `year_sets-check.py`, `fp_provenance-check.R`, `gpkg_determinism-check.R`,
      `stage_years-check.R`
- [x] `catalogue_release-check.sh` — one expected failure, its `RETIRED_ITEMS=""` arm

## Phase 5: The documents that go stale at the cutover

- [x] `NEWS.md`: promote Unreleased to `## v2.0.0`, naming all 23 retired ids
- [x] `CLAUDE.md` above the marker
- [x] `README.Rmd` prose + `scripts/readme_functions.R` comment
- [x] Stale comments naming mcgr/pine as the two carrying no provenance

## Phase 6: Tag and release

- [x] `/code-check branch`
- [x] `/planning-archive`, `/gh-pr-push`
- [x] Merge the PR (skip `/gh-pr-merge` steps 6-9 — no `DESCRIPTION`)
- [x] `git tag v2.0.0` on the merge commit
- [x] `bash scripts/catalogue_release.sh` — no `--allow-retract`
- [x] Report at `RELEASE COMPLETE`

## Validation

- [x] Tests pass
- [x] `/code-check` clean (once over the branch)
- [x] PWF checkboxes match landed work
- [x] `/planning-archive` on completion
