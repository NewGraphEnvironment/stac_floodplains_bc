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

### Phase 6 (steps 1-2) — config merged + full local dry-run (VALIDATED)
- floodplains PR #25 (targets) merged to main; #19 disturbance also merged (#26). floodplains
  checkout now on main with targets committed — the earlier overlay dependency is gone.
- Full local dry-run (SKIP_S3): 16 items staged/COG'd/tagged/registered + pystac-valid.
- Positive check PASS across all 16: three nested ff areas > 0, floodplain + floodplain_landcover
  assets, no floodplain_km2, every asset href under <item_id>/; collection links 16; no bare-<wsg>/
  hrefs. morr_co_ff04 + morr_ch_ff06 both present.
- HELD at step 3 (production publish to S3 + reload + trailing-slash cleanup) for user go-ahead.

### Phase 6 step 3 — production publish (S3 DONE; reload + cleanup pending)
- Ran on the 11-... branch (repo had been switched to main; #11 unmerged — switched back).
- run_pipeline.sh: 16 items published to s3://stac-floodplains-bc under item-keyed <item_id>/ paths;
  64 COGs; collection.json links 16; all valid. Verified morr_ch_ff06 on S3 (species ch, region
  skeena, item-keyed hrefs, chinook loss/gain/net 482/731/+248).
- Live still 15 (rtj#190's reload ran earlier); rtj#198 filed for the 16 + item-keyed reload.
- Old flat <wsg>/ prefixes intact — HELD cleanup until reload verified (live 15 still reference them).
- Note: main has c4b35f8 = /claude-md-init --public-clean (repo flipped toward public). #11 branch
  predates it; reconcile CLAUDE.md/.claude/visibility at merge (do NOT clobber the public-clean state).
