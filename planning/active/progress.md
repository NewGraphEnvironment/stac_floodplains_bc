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
