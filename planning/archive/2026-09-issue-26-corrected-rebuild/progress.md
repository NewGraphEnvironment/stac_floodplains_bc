# Progress — Published items are over-mapped (#26)

## Session 2026-09-04

- Plan-mode exploration; phases approved by user. Two decisions taken: `v1.1.0` now with
  `v2.0.0` reserved for an all-corrected catalogue, and no re-stage — the corrected 23-item
  build is already on disk and is what the floor of 21 was measured on
- Archived #47's PWF: its code shipped in PR #51, and its Phase 6 (cut the release)
  transferred here rather than being tracked in two places
- Created branch `26-published-floodplain-items-were-built-wi` off main
- Phase 1: `DEPRECATED_ITEMS` literal; `deprecated: true` + the version extension on
  exactly `mcgr_ch_ff04` and `pine_bt_ff04`. Rebuilt: 21 items at 3 extensions, 2 at 4
- Phase 2: `check_deprecated` — set equality, literal-ids-exist, the extension/field
  biconditional, `deprecated: false` refused, and the self-clearing arm. Runs before
  `check_checksums`. Positive control green; pystac itself now emits
  `DeprecatedWarning: The item 'pine_bt_ff04' is deprecated`, which is a real consumer
  library reading the marker
- Phase 3: **7 of 7 guards proved**, each grepped for its own message. One came back
  `WRONG GUARD (rc=0)` and the proof was at fault, not the guard — it mutated the
  builder's literal where the guard is about the validator's. Retargeted; the residual
  uncovered case (a nonexistent id in the builder's copy alone) publishes nothing and is
  recorded as a deliberate boundary
- Caught the harness leaving `data/stac` polluted: it restores `meta.json` but does not
  rebuild. Rebuilt clean. The release gate would have refused the polluted tree
- Phase 4: `NEWS.md` → `## v1.1.0 (2026-09-03)`, geometry correction leading, and the
  `v2.0.0` convention recorded in the header where the next person reads it
- `/code-check`: 3 rounds, 20 findings, all fixed. Round 1 caught `check_deprecated`
  breaking `--only` outright and the one-way self-clear; round 2 caught `--partial`
  over-dropping and a FALSE claim to consumers that `file:checksum` distinguishes replaced
  data; round 3 caught the same over-drop on the mirror arm. Three factual errors caught in
  the release note: 18->12->13 items, 5-33% -> 1.5-33.5%, and the checksum discriminator
- Harness 100 -> 111 assertions; 9k/9l/9m each proved to discriminate against a scratch copy
- PR #52 merged (`3749de2`); tagged `v1.1.0` on the NEWS commit
- **RELEASE COMPLETE — v1.1.0, 23 items live.** Step 5 verified the version, the licence,
  both links, `sci:citation` and the deprecation markers, on the API and the bucket.
  Confirmed independently from the API afterwards: 23 items, `deprecated` on exactly
  `mcgr_ch_ff04` + `pine_bt_ff04`, `tabr_ch_ff04` now 154.63 km² (was 232.69)
- **#47's open premise is answered by measurement**: `rel: license` and `rel: derived_from`
  DO survive pgstac's `get_links()` on this deployment — the API serves both
- README coverage table regenerated from the live API (23 items, 22 groups)
- Next: close #26 and #47, update memory
