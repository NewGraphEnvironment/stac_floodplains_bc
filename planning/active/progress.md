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
- Next: Phase 3 — restore each bug and prove the guard fires
