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

### Phase 0 — validation gate (PR #16)
- Baseline captured before anything could wipe `data/stac`: 18 JSON md5s + the live 17 ids.
  Local ids == live ids exactly.
- The gate as first written **did not work**: `05`'s `if SKIP_S3_UPLOAD … elif PARTIAL_STAGE` chain
  meant it never evaluated the partial-stage refusal. Three further holes followed, the deepest
  being that `skipped` only counts groups the stage loop *reaches* — a missing region roster yml
  drops groups uncounted, so a 14-item collection would have overwritten the live 17 silently.
- All four closed and each exercised, not assumed. `05` rerun reproduces all 18 JSONs
  byte-identical, so the build is deterministic.
- Split out as PR #16 per the agreed two-PR plan.

### Phase 1 — registration transport
- Three scripts written and committed. Review found five defects in the port; the worst is that
  `pgstac.delete_item(id)` without a collection argument is **unscoped across the shared `stac`
  db**, which also hosts `imagery-uav-bc-prod` and `stac-dem-bc`. Confirmed against pgstac v0.9.8
  source rather than inferred, along with `RETURNING * INTO STRICT` raising `NO_DATA_FOUND`.
- Local half fully verified without touching production (compaction, `$`-expansion sides, SQL
  rendering, injection guard, simulated truncation).

### BLOCKED — no SSH access to geopro from this machine
- `ssh root@geopro` → `Permission denied (publickey)`. The M1 offers `id_rsa` and `id_ed25519`;
  geopro's root rejects both. We reach sshd (`Authentications that can continue: publickey`), so
  the tailnet path and the DO firewall are fine — this is purely key authorization, and it is why
  the last reload was run from the M4.
- Blocks: Phase 1 smoke tests, Phase 3 dry-run, Phase 5 release. Does **not** block Phases 2–4
  authoring.
- Resolution is the user's: run from the M4, or add this machine's key to geopro's root
  `authorized_keys`.
- Next: Phases 2–4 (item_validate.py, the 05 refactor, catalogue_release.sh, docs) are unblocked.
