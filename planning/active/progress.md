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

### Phase 2 — the refusal proven
- Seven sandbox arms, each told apart by its own message (`findings.md` carries the table and the
  commands): unreadable record, moved schema and a mid-write raster each refuse with no census;
  the no-record control still prints one; a missing bundle and a missing `area.yml` skip by name.
- Added a guard the plan did not have: nothing staged is now its own refusal. The skip arms were
  printing `PROVENANCE_FLOOR=0` and exiting 0, and 0 is both a legitimate past value and what a
  reader that found nothing produces.

### Phases 3 and 4, and the plan review folded in
- The review landed mid-Phase 4 and moved Phase 1 as well: see `findings.md` for the three
  load-bearing findings (the `processing:software` pairing and today's aborting build; the
  no-rasters skip swallowing a build stop; `fp_prov_span()` never called), what was declined and
  why, and the mutation table for the five new arms.
- Docs: `scripts/README.md` gains its own section naming it a measurement and the pre-flight
  rather than the authority; `CLAUDE.md` and `NEWS.md` likewise, plus the aborting-build finding.
- Issues: #90 filed for the `fp_roster.R` extraction the mirror defers (the number was written
  only after filing). #89's body corrected in two places — its DUNC bullet, which was wrong about
  the build, and step 3, which now names the build's own `census:` line as the authority.
- `prov_fields-check.py`: three arms over the literals, a comment naming the producer, and a note
  that the all-absent fixture population stays even though the live catalogue no longer has one.
