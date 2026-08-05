# Progress — Carry wsg into published gpkg assets (#5)

## Session 2026-08-05

- Verified the gate: floodplains#30 merged AND source data regenerated (contract met across all areas).
- Plan-mode exploration found KISP newly rostered upstream -> republish yields 17 items.
- Plan-agent review: 19 findings folded in, incl. 2 blockers (scope assertion to
  floodplain_landcover.gpkg; snapshot before publish since bucket versioning is Suspended).
- Phases approved by user.
- Created branch `5-carry-watershed-group-identifier-wsg-int` off main.
- Next: Phase 0 (KISP issue) then Phases 1-5.

### Phases 0-2, 4 — issue split, assertion, verification, docs
- Phase 0: filed #13 (KISP); amended #5 acceptance to 17 items.
- Phase 1: test_pipeline.R asserts wsg == meta$wsg on every layer of BOTH gpkgs (+ explicit
  library(sf), floodplain_landcover.gpkg presence check, zero-row guard).
- CODE-CHECK CAUGHT A BAD PREMISE: the plan asserted floodplain.gpkg was geometry-only. False —
  it carries valley/wsg/species/scenario and upstream backfills both files. Assertion widened;
  README and issue #5 wording corrected. Only `wsg` is asserted (species/scenario are not
  item-invariant, since whole-WSG gpkgs are copied into each item dir).
- Phase 2: 16/16 groups pass; KISP metrics match independent recompute; floodplain.gpkg wsg
  swept across all 16 areas (all layers ok).
- Phase 4: README coverage 17 items/16 WSGs + KISP row + new totals; scripts/README refreshed.

### Phase 3 + 5 — republish 17 + reload filed
- Snapshotted 16 item JSONs + collection.json before publishing (bucket versioning is Suspended,
  so there is no rollback). Publish start 2026-08-05T20:47:04Z.
- run_pipeline.sh: 17 staged, 68 COGs, 17 items + collection valid, 18 JSON synced.
- Snapshot diff: all 16 pre-existing items byte-identical on id/bbox/geometry/9 properties ->
  upstream changed SCHEMA ONLY, as predicted.
- S3-side acceptance: 17/17 floodplain_landcover.gpkg refreshed after publish start (proves the
  sync was not a silent no-op); gpkgs downloaded from S3 carry correct wsg (LCHL/PARS/KISP).
- Positive check across 17 item JSONs: PASS; kisp_ch_ff04 present.
- rtj#202 filed for the pgstac reload. No cleanup step (paths already item-keyed).

### Phase 5 close-out — reload verified live
- Reload was run from the M4 (rtj#202). Live catalog now serves **17** items including
  `kisp_ch_ff04`; collection spatial extent widened to cover Kispiox.
- KISP's live properties match the independent recompute exactly, so the published figures trace
  back to the model with no drift through COG -> tag -> STAC -> pgstac.
- Swept all 17 live items: 6 assets each, three positive ff areas, no stale `floodplain_km2`,
  every asset href under its own `<item_id>/` prefix.
- Worth recording: an `/items` probe minutes before the verification returned **16 without KISP**,
  the next returned 17 — the reload landed mid-session (or a replica lagged). A single count check
  is not by itself proof; the property/asset sweep is what makes this non-silent.
- Archived; PR covers #5 and #13.
