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
