# Progress — Produce the provenance floor and census numbers (#82)

## Session 2026-10-15

- Plan-mode exploration: read `fp_provenance.R`, `fp_provenance-check.R`, `01_stage.R`'s roster
  walk and target loop, `prov_fields-check.py`'s census arms, both literals and their comments,
  `scripts/README.md`, and issues #82 / #89.
- Measured the roster census with a throwaway probe (in `findings.md`) — 23 rostered, 20 staging,
  20 carrying provenance — which surfaced the skip-before-read ordering the issue's spec does not
  carry.
- Two decisions taken at the plan gate (airvine): reconcile with `prov_fields-check.py` by naming
  all three destinations in the output and adding a static no-copy arm, keeping its asserted
  counts; and on a skipped target, print the census with a loud banner and exit 0.
- Phases approved by user. Created branch `82-produce-the-provenance-floor-and-census` off main.
- Next: Phase 1, `scripts/prov_census-measure.R`.
