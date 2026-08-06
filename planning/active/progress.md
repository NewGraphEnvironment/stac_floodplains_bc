# Progress — Adopt the converged stac-catalog system (#14)

## Session 2026-08-05

- Plan-mode exploration: 3 Explore agents (uav reference implementation, this repo's pipeline, rtj +
  sister repos) then 2 Plan agents (minimal-diff design, adversarial risk review).
- The adversarial pass corrected two of my own stated premises — the airphoto IP is not stale or
  divergent, and the 9 MB NDJSON corruption is already fixed in the script being replaced. Both are
  recorded in `findings.md` so the PR rationale doesn't repeat them.
- It also caught three things that would have been ported as live bugs (`--delete`, a verify that
  can never pass without git tags, an un-fielded search that downloads 38 MB) and two silent-success
  traps (validate-passes-on-zero, truncated-ssh-exits-0).
- Seven decisions settled with the user: scope (items 1/2/4/5, defer 3), hybrid naming, split
  rebuild from publish, flat `scripts/`, upsert + explicit unregister, `${GEOSERV_HOST:-root@geopro}`,
  dry-run on a throwaway collection, two PRs.
- Created branch `14-adopt-the-converged-stac-catalog-system` off main.
- Next: Phase 0 — baseline md5 + live snapshot, then the ordering fix (PR 1).
