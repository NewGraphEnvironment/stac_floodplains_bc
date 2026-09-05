# Progress — Make the classified year set per-item from provenance (#61)

## Session 2026-09-05

- Plan-mode exploration; phases approved by user
- Two policy decisions taken by the user before the baseline:
  - #23 two-population rule: a human-set `ALLOWED_YEAR_SETS` literal in `item_validate.py`
  - unprovenanced items (`mcgr`, `pine`): year set discovered from the staged rasters
- Concurrent Plan-agent review returned 3 blockers, all confirmed against the tree
  (drift skew leaves no runnable "before"; a second hardcoded count in `test_pipeline.R`;
  `--only` passes `--partial`, making the cross-item arm vacuous)
- Created branch `61-make-the-classified-year-set-per-item-fro` off main
- Scaffolded PWF baseline from issue #61 with approved phases
- Next: Phase 1

### Phase 1 — year set per item, asserted against disk (done)

- `fp_prov_span()` added to `scripts/fp_provenance.R`; `YEARS` deleted from `01_stage.R`.
  `TRANSITION_SPAN` kept, retyped as integer, and promoted to the anchor the derived set is
  checked against.
- Measured, not assumed: `WSG_ONLY=ufra` restages `data/raw/ufra_ch_ff04/meta.json`
  **byte-identical** to the pre-change build already on disk
  (`22c2460f77b6b7f0da3a2c23cf0290cddf81429e657a692fc3e7b2eaac0e68e3`). A previous full
  build in `data/` turned out to be a usable local "before" after all, so the API baseline
  is a cross-check rather than the only route.
- `WSG_ONLY=lnth` stages seven classified years and a 2017-2023 transition, with
  `landcover_key` refolded over seven digests.

### Phase 2 — offline proof and restore-the-bug (done)

- `fp_years_reconcile()` extracted out of the staging loop into `fp_provenance.R`: a guard
  buried in a loop over watershed groups cannot be fired against both known answers.
- `scripts/fp_provenance-check.R` grew 25 cases (72 assertions, 0 failed) covering
  `fp_prov_span` and `fp_years_reconcile`, controls first.
- `scripts/stage_years-check.R` is new: it restores each defect in a real upstream tree and
  runs `01_stage.R` over it, in a sandbox whose upstream area is symlinks and whose `data/`
  is its own. 13 assertions, 0 failed. Each arm greps its own message.
- Two fixtures rotted mid-session because floodplains#79 converted `bulk` while the work was
  in flight; both are now gated on the area's own `produced_datetime`.

### Phases 3-5 (done)

- `ALLOWED_YEAR_SETS` + the split key check in `item_validate.py`, partition and `--partial`
  reasoning written down beside the guard. `scripts/year_sets-check.py` proves all five arms,
  each greping its own message; one call-site proof by mutating the live built tree.
- `test_pipeline.R`: `--partial` (a pre-existing #26 break, reproduced on `main`), both
  hardcoded asset counts per item. `item_create.py` description, `run_pipeline.sh` banner.
- Determinism: `04_gpkg_style.py` is a true no-op on the third pass over a seven-year
  GeoPackage, and both determinism checks pass with `ITEM=lnth_ch_ff04` — the fixture axis
  they could not previously reach.
- `README.Rmd` asset table per item; both targets re-rendered with `update_query = FALSE`, so
  the coverage figure and table still describe the published catalogue this PR does not
  change. `index.html` moved 17 lines out of 5.8 MB and is byte-identical across two renders.
- `NEWS.md` gets an Unreleased entry; every figure in it derived from the artifact.

### Review round 1 — 7 findings, all real, all fixed

Confirmed against the tree before acting, in both directions:

| finding | fix |
|---|---|
| `stage_years-check.R`'s isolation assertion claimed more than it tested | fingerprint `REPO/data` before the first run and after the last — plus a premise guard, because `"<absent>" == "<absent>"` passes and an absent `data/` is what an escaped run would leave behind |
| the byte-identity pin was gated on upstream but not the local toolchain | second gate on the sf/GDAL/PROJ triple; `meta.json`'s areas, bbox and geometry are computed here, so a different GDAL would have FAILED under a message reading "the code moved the data" |
| neither new check script was reachable from anything | documented in `scripts/README.md` beside its five siblings |
| `NEWS.md` said "grew 25 cases" | 23, measured: 52 → 75 `expect_*` calls, script prints 72 assertions |
| `NEWS.md` listed `change_interval` among the absolutes | it is record-dependent and does not run for the two forward-only items; reworded in `NEWS.md` and in the PR body |
| `CLAUDE.md:83` still said "3 classified-year COGs" | the sentence this issue falsifies, in the document the next session reads first |
| `fp_provenance-check.R`'s `YEARS` was a double under a false comment | integer, next to a type-strict `identical()` that would have fired on correct input the first time anyone reused it |

The reviewer also ran all three suites and measured disk-vs-record across all 23 rostered
targets: 21 match, 2 forward-only, **no target becomes unstageable**. And it confirmed
empirically that R's `unlink(recursive = TRUE)` removes a symlink rather than its target, which
is what makes the sandbox safe.

### Review round 2 — 4 findings, all real, all fixed

The validator logic came back clean under mutation testing (neutering an arm turns exactly
one assertion red, so every case reaches the arm it names). All four findings were in
**claims**, which is the same mechanism as round 1's:

| finding | fix |
|---|---|
| the blast-radius claim was false AND understated it — the smoke test could validate *no* group, not "any but the two" | `EXPECTED_DEPRECATED` names two items, so a one-group tree is always missing at least one, including each of the two themselves. Corrected in `NEWS.md`, the `test_pipeline.R` comment and the PR body |
| the stray-file arm was described as catching "a stray COG" and only covered `classified_<yyyy>.tif` | **widened** rather than narrowed — the arm now compares the item's whole directory against its published assets, which is what the comment's own `aws s3 sync` reasoning argues for. Three stray shapes proved, plus a control |
| arm (b)'s remedy covered only the *became-obsolete* direction; for a set added *ahead* of its data, deleting it walks the operator back through arm (a) | both directions named, and the likeliest real cause (a group that failed to stage) pointed at. Pinned as **rendered text**, since an assertion matching only the interpolated year set is blind to the sentence around it |
| `item_create.py`'s module docstring still declared `classified_2017/2020/2023` | corrected — the same class as round 1's `CLAUDE.md:83`, in a file round 1 was not given |

Two things worth keeping from the round: the `expect_problem` needle discipline caught my own
rewording of arm (b)'s message the moment the fix landed, which is precisely why the cases
grep for a message instead of a status. And my own PR body carried a stale assertion count
twice — the same "restated rather than derived" mechanism, in the document I wrote about it.
