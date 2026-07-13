# Task Plan — Register 5 more groups: Peace bt_ff04 + new Fraser chinook (#3)

Extend the live `stac-floodplains-bc` collection from 8 → 13 items by staging the Peace region
(`bt_ff04`: PCEA, PARS, PINE) and two new Fraser chinook groups (`ch_ff04`: BOWR, MCGR). The
pipeline is already scenario-parameterized, so only `01_stage.R` (hardcoded `REGION="fraser"`)
needs generalizing. Coho (`morr`, `neexdzii`, `co_ff04`) is out of scope.

## Phase 1: Upstream roster (floodplains repo) ✓
- [x] Added `BOWR`, `MCGR` to `floodplains/config/regions/fraser.yml` — floodplains#17, PR#18 merged.
- [x] `fraser.yml` lists 10 Fraser groups (validated).

## Phase 2: Generalize `01_stage.R` to multiple regions ✓
- [x] Dropped `REGION <- "fraser"`; enumerate `config/regions/*.yml`; build `wsg_lower → region` map
      (warn+first-wins on collision); `wsgs` = names of the map.
- [x] Loop sets `meta$region <- wsg_region[[wsg]]`; header docstring updated.
- [x] `WSG_ONLY` validates against the multi-region set + resolves region from the map; `PARTIAL_STAGE`
      + clean-rebuild wipe unchanged.
- [x] Confirmed `03_cog_tag.py` / `04_s3_upload.R` / `05_stac_register.py` need no change.

## Phase 3: Smoke-test locally (no S3) ✓
- [x] `WSG=pcea` — `bt_ff04` validates, `region=peace`; metrics 100.6/210.0/109.4 match independent
      GDAL-sqlite recompute exactly.
- [x] `WSG=bowr` — new Fraser chinook validates, `region=fraser` (roster addition flows through).

## Phase 4: Publish all 13 + verify live
- [x] `bash scripts/run_pipeline.sh` (263s) → 13 staged, 52 COGs, 79 S3 objects, 13 items +
      collection valid, 14 JSON synced. 8 existing unchanged; collection.json → 13 item links.
- [x] Re-load filed as **rtj#183** (operational re-run on geoserv; wiring already in from #177). The
      geoserv ssh/pypgstac step is not runnable from this repo.
- [x] S3-side verified: 79 objects, 25 new-group objects present, new COGs public (206) + valid with
      overviews + correct tags; PARS (1438.9/3232.8) and PCEA (100.6/210.0) recompute exactly.
      **API returns 13 only after rtj#183 runs** (still 8 until then).

## Phase 5: Document + wrap
- [x] README coverage table → 13 rows with Region + Species columns; totals recomputed (5,887 km²,
      18,296 ha loss); coverage sentence spans Fraser + Peace, chinook + bull trout.
- [ ] `/code-check` clean; `/planning-archive`; open PR.

## Validation
- [ ] `WSG=pcea` and `WSG=bowr` smoke tests PASS locally.
- [ ] Published loss/gain/net for the 5 new trace to their transition layers (independent recompute).
- [ ] All 13 items live on `images.a11s.one`.
- [ ] `/code-check` clean on each commit; PWF checkboxes match landed work.
