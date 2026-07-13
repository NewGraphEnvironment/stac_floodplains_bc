## Outcome

Extended the `stac-floodplains-bc` collection from 8 → **13 items** by adding the **Peace region**
(`bt_ff04` bull trout: PCEA, PARS, PINE) and two new **Fraser chinook** groups (`ch_ff04`: BOWR,
MCGR). All 13 published to S3 (79 objects; `collection.json` links 13) and verified — new COGs are
public, valid (overviews), correctly tagged; PARS/PCEA metrics recompute exactly from their
transition layers. Region totals: 5,887 km² floodplain, 18,296 ha gross tree loss.

Key points / learnings:
- **The pipeline was already scenario-parameterized**, so `bt_ff04` needed no changes to
  `03/04/05`. The only code change was generalizing `01_stage.R`'s hardcoded `REGION="fraser"` to
  **iterate every `config/regions/*.yml`** and build a `wsg → region` map (region config = source of
  truth; coho, absent from all rosters, is naturally excluded).
- **Upstream prerequisite (Option A):** BOWR/MCGR had config+data but weren't in `fraser.yml`'s
  roster, and `area.yml` has no `region` field, so the roster is the only group→region link. Added
  them upstream via **floodplains#17 / PR#18** before generalizing here — keeps the region config
  authoritative rather than hardcoding a group→region map in this repo.
- **Verified per-group** with the `WSG=<g>` smoke test (`test_pipeline.R`) + independent GDAL-sqlite
  recompute before the full publish.
- **Catalog load is out-of-repo:** the geoserv pypgstac re-load (ssh to prod) is rtj's job — filed
  **rtj#183**. The API returns 13 only after that runs; until then it shows the original 8.

Closed by: commits 6c439e0 → f80ab6d on branch `3-register-5-more-groups-peace-bull-trout` (PR pending).
Related: floodplains#17/#18 (roster), rtj#183 (pgstac re-load), rtj#177 (initial registration), #1.
