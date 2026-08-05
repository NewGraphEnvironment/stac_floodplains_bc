# Task: Carry `wsg` into published gpkg assets; republish (16 → 17 with KISP) (#5)

## Problem

`floodplains#30` (merged) now writes `wsg`/`species`/`scenario` into every
`floodplain_landcover.gpkg` layer at generation time, and the source data has been regenerated. The
published S3 assets still carry the old schema, so downstream consumers (rtj QGIS multi-WSG merges)
can't separate areas by attribute. This repo does no modelling — `01_stage.R` copies the gpkg whole
— so #5 is a **republish + verify**, not a change to staging logic.

The republish also picks up **KISP** (Kispiox, chinook `ch_ff04`), newly rostered upstream in
`config/regions/skeena_ch.yml` and data-complete → **16 → 17 items**. Tracked as its own issue,
delivered by the same republish/PR.

## Key facts (exploration + Plan-agent review, 19 findings folded in)

- **Contract met:** every `floodplain_landcover.gpkg` layer carries `wsg`+`species`+`scenario` —
  MORR 18 layers, BULK 6, others 4. Values are the uppercase WSG code, matching `toupper(wsg)`.
- **BLOCKER — scope the assertion:** `floodplain.gpkg` layers are geometry-only (zero attributes).
  "Every gpkg layer carries wsg" must be scoped to **`floodplain_landcover.gpkg`** or it fails 17/17.
- **BLOCKER — no rollback:** bucket versioning is **Suspended** and `01_stage.R` wipes gitignored
  `data/{raw,stac}`. **Snapshot the 16 item JSONs + collection.json before publishing.**
- **`aws s3 sync` re-uploads only because there's no `--size-only`** (staged mtimes are fresh).
  LCHL's `floodplain.gpkg` is byte-identical in size to S3 — a future `--size-only` would silently
  skip it. That omission is load-bearing.
- **Verify from S3, not local** — local trivially passes (byte copy of source).
- KISP resolves cleanly (only in `skeena_ch.yml`, `region: skeena`, no `targets` → fallback
  `kisp_ch_ff04`). KISP numbers: ff02 210.86 / ff04 246.74 / ff06 274.74 km²; loss 267.9 / gain
  937.2 / net +669.3. New totals: 7,036 / 21,553 / 17,428 / −4,126.
- Loss/gain recomputed from regenerated source match the current README for all 16 → upstream
  changed **schema only**.
- Gotcha: `ogrinfo -so` appends `(Multi Polygon)` on only some layers — never `$`-anchor layer regexes.

## Phase 0: File the KISP issue + align #5's acceptance

- [x] Filed #13 "Publish KISP (Kispiox, Skeena chinook) as a new item".
- [x] Amended #5's acceptance to 17 (and corrected its gpkg-scope wording after the code-check).

## Phase 1: Assert the contract in the smoke test

Regression guard, **not** red-green TDD — it passes immediately (columns already exist upstream).

- [x] `test_pipeline.R`: added explicit `library(sf)`.
- [x] Added `"floodplain_landcover.gpkg" %in% gpkgs` to the existing `stopifnot()`.
- [x] Per-item loop asserts every layer of **both** gpkgs carries `wsg` == `meta$wsg`.
      **Corrected mid-phase:** the plan (via the Plan agent) claimed `floodplain.gpkg` was
      geometry-only; code-check disproved it — it carries `valley`/`wsg`/`species`/`scenario` and
      upstream backfills BOTH files. Scoping to one gpkg would have let a regression pass green.
      README + issue #5 wording corrected too. Zero-row layers now report `<no rows>`.

## Phase 2: Verify across all groups

- [x] `WSG=kisp` PASS — `kisp_ch_ff04`, ff02 210.86 / ff04 246.74 / ff06 274.74; loss/gain/net
      267.9 / 937.2 / +669.3 — matches the independent recompute exactly.
- [x] Looped all 16 groups: **16/16 passed**. After widening to both gpkgs, re-ran kisp + morr
      (the multi-target, 18-layer case) and swept `floodplain.gpkg` schema across all 16 — all ok.

## Phase 3: Snapshot → republish 17 → verify against S3

- [x] Snapshotted the 16 item JSONs + collection.json to scratch (publish start 2026-08-05T20:47:04Z).
- [x] `run_pipeline.sh` → 17 staged/68 COGs/17 items valid; collection.json links 17.
- [x] Snapshot diff: all 16 pre-existing items **unchanged** on id/bbox/geometry/9 properties.
- [x] From S3: 17/17 `floodplain_landcover.gpkg` objects refreshed after publish start; gpkgs
      downloaded back from S3 carry the right `wsg` (LCHL/PARS/KISP).
- [x] Positive check across 17: PASS (nested ff areas, both gpkg assets, no `floodplain_km2`,
      item-keyed hrefs); `kisp_ch_ff04` present.
- [x] Recovery path noted (re-run `05` alone) — not needed.

## Phase 4: Docs

- [x] `README.md` — KISP row; totals 7,036 / 21,553 / 17,428 / −4,126; "17 STAC items across 16
      watershed groups"; item model documents the attribute contract on **both** gpkgs.
- [x] `scripts/README.md` — attribute note, multi-target example, stale "all-8 publish" /
      "live 8-item collection" corrected.

## Phase 5: Reload + close out

- [x] Filed the rtj reload follow-on: **rtj#202**.
- [x] Reload run from the M4. Live verified: **17 items**, `kisp_ch_ff04` present (HTTP 200) on
      both `/items` and `POST /search`. KISP properties match the independent recompute exactly
      (ff02 210.86 / ff04 246.74 / ff06 274.74; loss 267.9 / gain 937.2 / net +669.3). All 17
      carry 6 assets + 3 positive ff areas, no stale `floodplain_km2`, every href item-keyed.
      Collection extent widened to include KISP.
- [x] `/planning-archive`; PR references both #5 and the KISP issue.

## Validation

- [x] All 16 groups + KISP pass the smoke test with the new assertion
- [x] `/code-check` clean on each commit
- [x] PWF checkboxes match landed work
- [x] Snapshot diff proves the 16 unchanged; S3 `LastModified` proves the refresh is non-silent
- [x] `/planning-archive` on completion
