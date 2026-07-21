# Progress — Publish floodplain.gpkg delineations (#8)

## Session 2026-07-18

- Plan-mode exploration — read 01/03/05/test_pipeline, grepped `floodplain_km2`, confirmed
  ff02/04/06 layers + uniform naming.
- Plan-agent adversarial review — 5 findings folded into the plan (atomic rename, scripts/README,
  README mislabel, positive check, ff04 guard).
- Phases approved by user.
- Created branch `8-publish-floodplain-gpkg-delineations-ff0` off main.
- Scaffolded PWF baseline from issue #8 with approved phases.
- Next: start Phase 1 (smoke-test contract).

### Phase 1 — smoke-test contract (RED)
- test_pipeline.R: assert 2 gpkgs incl floodplain.gpkg, three floodplain_ff0{2,4,6}_km2 > 0
  (isTRUE-guarded), is.null(floodplain_km2); summary prints three areas.
- Confirmed red on current pipeline: `WSG=bulk` halts at "expected 2 gpkgs".

### Phases 2+3 — stage three extents + register asset/props (GREEN)
- 01_stage.R: copy floodplain.gpkg; endsWith("_ff04") guard; species-prefix token-swap for
  ff02/04/06 layers with missing-layer stop(); three floodplain_ff0*_km2 in meta.json.
- 03_cog_tag.py: SHARED_FIELDS -> three ff area keys (FLOODPLAIN_FF0*_KM2 tags).
- 05_stac_register.py: new `floodplain` gpkg asset; floodplain.gpkg in expected-assets guard;
  three area props; docstring + collection description updated.
- Bundled 2+3 in one commit (05 KeyErrors on missing floodplain_km2).
- WSG=bulk smoke test PASS; independent recompute matches; code-check round 1 Clean.

### Phase 4 — sweep + docs
- README.md: two vector assets (fixed `floodplain` mislabel), three ff extent layers, three area
  properties; pipeline-table tag row + rstac example updated.
- scripts/README.md: gpkgs + per-flood-factor areas; "Fraser-region" -> "rostered" in edited cell.
- Sweep: only remaining floodplain_km2 is the intentional is.null() test assertion.
- Downstream rtj: zero floodplain_km2 references.

### Phase 5 — publish + verify (LIVE PENDING rtj reload)
- User approved production publish (schema break on live collection).
- run_pipeline.sh: 15 items re-published to S3 with new schema; 15/15 floodplain.gpkg uploaded;
  collection.json links 15; validated. Verified bulk + fran carry floodplain_ff0{2,4,6}_km2 + both
  gpkg assets on S3.
- Local positive check: 15/15 pass (three nested ff areas > 0, floodplain asset, no floodplain_km2).
- Commented on rtj#190 — one pgstac reload subsumes the coho load AND the schema migration.
- Remaining: rtj runs the reload (out-of-repo) → verify images.a11s.one serves 15 w/ new schema.
