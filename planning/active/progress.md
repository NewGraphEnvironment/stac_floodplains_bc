# Progress — Publish multiple species items per WSG (#11)

## Session 2026-07-20

- Merged PR #7 (coho) + PR #10 (#8 delineations) to main first — #11 builds on #8's code.
- Plan-mode exploration; surfaced the item-keyed-layout structural change (WSG-keyed paths collide
  for two morr items). User chose item-keyed-for-all + config-driven discovery.
- Plan-agent adversarial review — 7 findings folded into the plan.
- Phases approved by user.
- Created branch `11-publish-multiple-species-items-per-water` off main.
- Scaffolded PWF baseline.
- Next: start Phase 1 (upstream floodplains area.yml targets list).

### Phase 1 — upstream floodplains targets (DONE)
- floodplains config/morr/area.yml: added targets [co/co_ff04, ch/ch_ff06]; PR #25.
- Backward compatible (primary_scenario fallback for the other 14). Parses via R yaml.
- Local floodplains checkout on branch morr-publish-targets-co-ch, so the stac pipeline reads
  the targets during #11 development.

### Phase 2 — smoke-test contract re-keyed (RED)
- test_pipeline.R iterates data/raw/*/meta.json (item dirs), asserts item-id-keyed staging, per-item
  structure, staged count == declared targets, and morr => {morr_co_ff04, morr_ch_ff06}.
- Confirmed red on current pipeline: WSG=morr halts at "staged item count != declared targets".

### Phase 5 — docs
- README.md: item model = one-or-more items per WSG, item-keyed asset prefix; coverage 16 items /
  15 WSGs (added MORR chinook row, MORR-floodplain-counted-once footnote); pipeline table <item_id>
  paths; species added to rstac example.
- scripts/README.md: stage/COG/STAC rows re-keyed to <item_id>.
