# Plan review — #36 (Plan agent, 2026-09-01, pre-baseline)

All three blockers confirmed against the code before folding in. Disposition per finding.

| # | class | finding | disposition |
|---|---|---|---|
| 1 | Blocker | Case 1 greps for `collection.json`, a string the sweeping sync's argv never contains — empty on correct code and on the defect alike | assert the shape: no root-source aws call, no `--include *.json` sync; positive control uses the same grep |
| 2 | Blocker | `printf '%q '` logging escapes spaces/asterisks, so `load collections` and `--exclude '*/*'` greps miss on both negative and control | log tab-separated `%s`; ssh shim logs the payload's first line |
| 3 | Blocker | `--only` with an empty value passes the shape check and selects the full-release path | refuse empty explicitly; a case-3 refusal for bare `--only` |
| 4 | Gap | `collection.json` cannot be optional under `--only`: `item_validate.py:709` requires exactly one | keep the preflight check |
| 5 | Gap | fixture requirements: asset files on disk named as href basenames, one strictly largest, `file:checksum` on it, collection `id`, absolute paths, href map by last two segments | all in the fixture builder |
| 6 | Gap | curl flags are combined (`-sI`, `-sf -X POST`); a shim testing `$1 = -I` falls through | dispatch on any `-X POST`/`/search`, any `-w`, any `-*I*` |
| 7 | Gap | membership comparison must be a string compare, not `comm ... \|\| true`; must-be-live via `grep -qxF --` | as stated |
| 8 | Ordering | "invert the assertion" shows it can be false, not that it sees the bug | Phase 3 restores the defect (sweeping sync under `--only`) and watches case 1 go red |
| 9 | Assumption | traced: no `--only` route reaches `collection.json`; rtj reload stays consistent | recorded in findings |
| 10 | Assumption | `--skip-sync` composes; steps 2+3 need a three-way; full tree under `--only` re-hashes ~670 MB | three-way branch; header notes the cost |
| 11 | Scope | case 3's interlock control is green on current main by design, not red | Phase 1 checklist says so |
| 12 | Acceptance | `local_ids` also feeds the both-ways comparison, not just `probe_item`; Phase 5 pilot log should capture the `valid: 1 item(s)` line | both in the plan |
