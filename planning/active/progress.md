# Progress — Register 5 more groups (#3)

## Session 2026-07-12
- Scoped the handoff: 5 new groups = BOWR, MCGR (Fraser ch_ff04) + PCEA, PARS, PINE (Peace bt_ff04),
  all data-ready. Coho out of scope. See findings.md.
- Confirmed only `01_stage.R` needs changing (scenario already parameterized; 03/04/05 glob-driven).
- Decision (Option A): add BOWR, MCGR to floodplains `fraser.yml` so region roster stays source of
  truth; staging generalizes to iterate all region configs.
- Filed issue #3; plan approved; branch `3-register-5-more-groups-peace-bull-trout` off main.
- Next: Phase 1 — add BOWR, MCGR to floodplains `config/regions/fraser.yml`.
