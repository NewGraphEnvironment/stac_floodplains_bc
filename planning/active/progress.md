# Progress — Retire the per-species floodplain items (#76)

## Session 2026-10-14

- Plan-mode exploration: measured the live collection (23 items, all per-species, 22 groups,
  no `dunc`), the upstream roster (23 groups, all four regions `network: whole`, no `targets:`
  block anywhere), and which groups actually hold whole-network rasters (**4 of 23**).
- Established that the migration cannot be done group-by-group: `--only` cannot publish a
  never-live item, and `readme_functions.R:133-148` refuses any API/bucket item-count mismatch.
  It is one full release retiring 17 items, blocked upstream by floodplains#125, #133 and MCGR's
  config state.
- Decisions taken by airvine: S3 objects deleted after verify in a separate guarded script;
  the release performs the pgstac delete from a `RETIRED_ITEMS` literal; #79 closes by construction.
- Plan reviewed by a Plan agent; ten findings reproduced before being acted on, three of which
  changed the design (the delete's placement, the unreachable half of the set relation, and the
  `--only` hole). Recorded in `findings.md`.
- Created branch `76-retire-the-per-species-floodplain-items` off main.
- Scaffolded the PWF baseline with the reviewed phases.
- Next: Phase 1, the harness knobs without which the new arms cannot be proven.
