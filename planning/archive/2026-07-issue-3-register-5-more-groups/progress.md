# Progress — Register 5 more groups (#3)

## Session 2026-07-12
- Scoped the handoff: 5 new groups = BOWR, MCGR (Fraser ch_ff04) + PCEA, PARS, PINE (Peace bt_ff04),
  all data-ready. Coho out of scope. See findings.md.
- Confirmed only `01_stage.R` needs changing (scenario already parameterized; 03/04/05 glob-driven).
- Decision (Option A): add BOWR, MCGR to floodplains `fraser.yml` so region roster stays source of
  truth; staging generalizes to iterate all region configs.
- Filed issue #3; plan approved; branch `3-register-5-more-groups-peace-bull-trout` off main.
- Next: Phase 1 — add BOWR, MCGR to floodplains `config/regions/fraser.yml`.

## Session 2026-07-12 (cont.)
- Phase 1: floodplains#17/PR#18 merged — fraser.yml now lists 10 (added BOWR, MCGR).
- Phase 2: 01_stage.R generalized to iterate all config/regions/*.yml (wsg→region map, first-win +
  hard-stop on missing region:); committed 41cceb4 after a clean fresh-eyes review.
- Phase 3: WSG=pcea (bt, region=peace) + WSG=bowr (ch, region=fraser) smoke tests PASS; metrics
  match independent recompute.
- Phase 4: published all 13 (run_pipeline.sh, 263s). S3 has 79 objects, collection.json → 13 links,
  new COGs verified public+valid. Live API returns 13 only after **rtj#183** (pypgstac re-load) runs.
- Phase 5: README table → 13 rows (region+species cols), totals 5,887 km² / 18,296 ha loss.
- Next: /code-check, /planning-archive, open PR. Ping/run rtj#183 to make the 5 new live.
