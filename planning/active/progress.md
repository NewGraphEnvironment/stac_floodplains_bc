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

### Phase 1 — harness knobs

- `ssh` shim now appends its stdin to `$SSHIN` instead of `/dev/null`: `item_unregister.sh`
  names its ids only inside the SQL it pipes, so without this a destructive call left no trace
  in `$LOG` and `n_delete()` would have counted zero however many items a run destroyed.
- `FAKE_GONE_IDS`, matched **before** the blanket `printf '200'` — every `-w '%{http_code}'`
  call took that branch, so a retired id could only ever read 200.
- `FAKE_LIVE_IDS_FINAL`: a third search stage, because a retirement release searches three
  times and a two-stage knob would hand the post-delete set to the compare that precedes the delete.
- `refused()` now also requires `n_delete() == 0`. It asserted only `rc != 0 && n_aws == 0`, so a
  refusal firing *after* a delete had landed would have passed it.
- Existing suite re-run: ALL PASS.

### Phases 3-5 — the mechanism

- `RETIRED_ITEMS` + six preflight arms; the delete placed after the `fail` gate; step 5 asks
  containment and step 7 equality, which is what keeps the re-run possible.
- `scripts/item_retract_s3.sh`: the irreversible half, `--yes` required, three refusals.
- The JSON sync writes `collection.json` last, closing a window that existed on every release
  so far and would first have mattered on the one that adds 17 items.
- Mutation tables in `findings.md`: 10 release arms + 6 S3/sync guards, every one red.
  Two first-round greens were the mutation patching inside a branch the case never enters.

### Phases 6-8 — dead guards, docs, issue hygiene

- `test_pipeline.R` and `stage_years-check.R` moved off `ufra`, which since floodplains#125
  stages nothing. The second was printing "the call site was NOT proven" on its documented
  invocation; 13 assertions on `bulk`.
- `## Retraction` split into Replacement and Removal, both release-first, with the rtj
  reload hazard named. Release table gains steps 6 and 7. Stale counts corrected.
- `NEWS.md`: the mechanism, what the cutover must land in one commit, and the `v2.0.0`
  reservation making it a minor bump.
- Posted on floodplains#125: the retirement cannot be staged per group, a release needs all
  13 remaining runs, and the `stage_years-check.R` note under its "Left" list is done.
- #79 closed by construction (option 1, structural). #76's body rewritten: the per-group
  framing corrected, the decisions and the mechanism recorded, blockers listed.
