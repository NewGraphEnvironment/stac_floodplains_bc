# Task Plan — Register 5 more groups: Peace bt_ff04 + new Fraser chinook (#3)

Extend the live `stac-floodplains-bc` collection from 8 → 13 items by staging the Peace region
(`bt_ff04`: PCEA, PARS, PINE) and two new Fraser chinook groups (`ch_ff04`: BOWR, MCGR). The
pipeline is already scenario-parameterized, so only `01_stage.R` (hardcoded `REGION="fraser"`)
needs generalizing. Coho (`morr`, `neexdzii`, `co_ff04`) is out of scope.

## Phase 1: Upstream roster (floodplains repo)
- [ ] Add `BOWR`, `MCGR` to `floodplains/config/regions/fraser.yml` `watershed_groups` (data ready;
      no `region` field in `area.yml`, so the roster is the only group→region link). Branch/PR per
      that repo's convention.
- [ ] Confirm `fraser.yml` lists 10 Fraser groups.

## Phase 2: Generalize `01_stage.R` to multiple regions
- [ ] Drop `REGION <- "fraser"`; enumerate `config/regions/*.yml`; build a `wsg_lower → region` map
      (dedupe, warn+first-wins on collision); `wsgs` = names of the map.
- [ ] Loop sets `meta$region <- wsg_region[[wsg]]`.
- [ ] `WSG_ONLY` validates against the multi-region set + resolves region from the map; keep the
      `PARTIAL_STAGE` marker + clean-rebuild wipe.
- [ ] Confirm (re-read only) `03_cog_tag.py` / `04_s3_upload.R` / `05_stac_register.py` unchanged.

## Phase 3: Smoke-test locally (no S3)
- [ ] `WSG=pcea Rscript scripts/test_pipeline.R` — `bt_ff04` validates; metrics match an independent
      GDAL-sqlite recompute.
- [ ] `WSG=bowr Rscript scripts/test_pipeline.R` — new Fraser chinook (after Phase 1); `region=fraser`.

## Phase 4: Publish all 13 + verify live
- [ ] `bash scripts/run_pipeline.sh` → 13 staged, republish to S3 (8 unchanged, 5 new; collection →
      13 item links).
- [ ] Re-run geoserv pypgstac load — **rtj step** (like rtj#177); file rtj follow-on. Not runnable here.
- [ ] `GET images.a11s.one/.../items` returns 13; 5 new with correct loss/gain/net; `bt_ff04` COG fetchable.

## Phase 5: Document + wrap
- [ ] README coverage table → 13 rows with Region + Species columns; totals recomputed; coverage
      sentence spans Fraser + Peace, chinook + bull trout.
- [ ] `/code-check` clean; `/planning-archive`; open PR.

## Validation
- [ ] `WSG=pcea` and `WSG=bowr` smoke tests PASS locally.
- [ ] Published loss/gain/net for the 5 new trace to their transition layers (independent recompute).
- [ ] All 13 items live on `images.a11s.one`.
- [ ] `/code-check` clean on each commit; PWF checkboxes match landed work.
