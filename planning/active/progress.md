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

### Phase 1 — the script
- `scripts/prov_census-measure.R` lands: roster walk mirroring `01_stage.R`'s selection and
  order, `PROV_FIELDS` parsed out of `01_stage.R`, the reader driven per target, refusal on any
  failed read, banner + exit 0 on a skip, paste-ready block naming all three destinations.
- Run on the real tree: 23 rostered / 20 staged / 20 carrying, `link_run_uid` 18,
  `link_config_sha256` and `link_sha` 19 — equal to the planning probe. `dunc_all_ff04` is the
  one item short of all three log-sourced fields, `mcgr_all_ff04` short of `link_run_uid` alone.
- Fixed while testing: the roster total was `staged + skipped`, which is only right while every
  skip is a target rather than a whole group. Counted from the targets each `area.yml` declares
  instead, with groups declaring none reported on their own line.
