# Code check — round 2 (#59 release notes + regenerated landing page)

Reviewed against the live API (`https://images.a11s.one/collections/stac-floodplains-bc`, read
2026-09-05), the live bucket (`s3api list-objects-v2`, 270 objects), the published GeoPackages
and COGs fetched over HTTPS, `planning/active/baseline_live.json` / `baseline_full.json`, git
tags, and `scripts/01_stage.R`, `fp_gpkg.R`, `04_gpkg_style.py`, `02_raster_tag.py`,
`fp_provenance.R`, `item_validate.py`, `catalogue_release.sh`.

## Round 1's four fixes — all correct

1. **#36 / v1.0.0.** `5c94847` ("Archive planning files for #36", 2026-09-01) *is* an ancestor
   of `v1.0.0` (tagged 2026-09-02 11:40:51 -0700), and v1.0.0's own NEWS section is where
   version stamping begins ("From this release a full release is a tag"). So "folded into
   v1.0.0" and "at pilot time the collection carried no version at all" both hold. The
   corrected claim is consistent across NEWS.md, task_plan.md and findings.md.
   "This is the first time published items have moved ahead of a stamped version" also holds:
   every bucket object outside the four was last modified 2026-09-04T06:17–06:19 (the v1.1.0
   sync), and the only later writes are the four 15-object `--only` batches at 21:29 / 21:38 /
   21:39 / 21:41 on 2026-09-05.
2. **The `floodplain_landcover.gpkg` table.** Every figure re-derived and correct — see the
   caveat in finding 1 below, which is about the sentence above the table, not the table.
   Sizes match `baseline_live.json` → live `file:size` exactly (41,672,704→52,961,280;
   30,801,920→49,565,696; 11,362,304→23,314,432; 21,311,488→42,549,248) and the percentages
   round correctly (+27.1, +60.9, +105.2, +99.7). **The "3 → 7 classified layers" claim is true
   of the PUBLISHED file, not only of a local build**: `gpkg_contents` on the live
   `bulk_co_ff04` and `lnth_ch_ff04` GeoPackages shows seven `classified_*_<year>` rows
   (`data_type='features'`), and the 3-year control `bowr_ch_ff04` shows exactly three.
3. **`nge:produced_datetime`.** `scripts/fp_provenance.R:67` maps it to
   `landcover → run → datetime_utc`, and the comment at :40 says exactly what NEWS now says.
   See finding 4 for the one sentence around it that over-reaches.
4. **`transition_vector.gpkg` timestamp pinning.** Both writers confirmed:
   `scripts/fp_gpkg.R:34-37` sets `OGR_CURRENT_DATE` from `GPKG_EPOCH` for the `01_stage.R`
   OGR write, and `scripts/04_gpkg_style.py:89` reads `GPKG_EPOCH` out of `fp_gpkg.R` for the
   `sqlite3` style write. Verified in the artifact: the published `lnth_ch_ff04`
   `transition_vector.gpkg` has `layer_styles.update_time = 2000-01-01T00:00:00.000Z`.
   "Nothing in it that a widened span *could* move" also checks out — the file holds exactly
   `transition` + `layer_styles`, the layer name is year-free, its fields
   (`patch_id/transition/area_ha/name_basin/from_class/to_class/in_fire/fire_year/
   fire_number/in_harvest/harvest_start_year_calendar/wsg/species/scenario`) carry no
   span-derived value, and `04_gpkg_style.py:58` maps the whole file to one year-free
   `transition.qml`.

No new error was introduced by any of the four fixes.

## Also re-derived and correct

- 23 items, 22 watershed groups, 4 regions, collection `version: 1.1.0`, `license: CC-BY-4.0`
  — README's regenerated header line is right.
- 10 → 14 assets on exactly the four named items; the other 19 serve 3 classified assets.
- **Exactly four properties move** on all four items, measured against `baseline_live.json`:
  `nge:landcover_key`, `nge:landcover_item_hash`, `nge:drift_version` (0.8.0 → 0.13.0),
  `nge:produced_datetime`. Nothing else, including `floodplain_ff0*_km2`, the tree-change
  figures and the temporal window.
- `floodplain`, `transition_vector` and the three `style_*` assets: checksum **and** size
  unchanged on all four.
- `bbox` and geometry unchanged — recomputed `sha256(json.dumps(geometry, sort_keys=True))`
  for all 23 live items against `baseline_full.json`'s `geometry_sha256`; 23/23 match, with
  two known-unchanged items as the positive control that the digest method is the right one.
- The 19 untouched items: asset key sets, every `file:checksum`, every `file:size`, and every
  property identical to `baseline_full.json`.
- Bucket: 210 objects outside the four, ETag and size unchanged, none added, none removed;
  `collection.json` untouched (LastModified 2026-09-04T06:19, ETag `8910580c…`).
- The 30 stray tags: `necr_ch_ff04/classified_2017.tif` and `kotl_bt_ff04/classified_2018.tif`
  carry 54 GDAL metadata items where `bulk_co_ff04` and `lnth_ch_ff04` carry 24 — a difference
  of exactly 30, all `NC_GLOBAL#` / `NETCDF_` / `crs#` / `data#` / `time#` / `x#` / `y#`.
  `data#type = float64` and `data#_FillValue = nan` on files whose bands read `Byte` /
  nodata 255, with 5 overviews and a RAT. Absent from `necr` and `kotl` transition rasters.
- `PROVENANCE_FLOOR=21` in `catalogue_release.sh:60`, unchanged; 21 of 23 live items carry
  `nge:` values, `mcgr_ch_ff04` and `pine_bt_ff04` carry none and are `deprecated: true`;
  `--only` skips `--expect-provenance` (`catalogue_release.sh:397-401`).
- `ALLOWED_YEAR_SETS` (`item_validate.py:670`) carries both populations.
- No upstream number is restated: the drift measurement is deferred to drift#62, and the
  `~20%` / `44%` figures stay in the planning record, out of NEWS.
- `index.html` is genuinely regenerated — the popups list `classified_2017`…`_2023` for the
  four and three years for `bowr_ch_ff04`, so the download links match what is served.
- The collection document really is unaffected: summaries are `region/species/scenario/
  flood_factor`, temporal extent 2017–2023, no `item_assets`.

## Findings

- **[fragile]** `NEWS.md:34` — "**`floodplain_landcover.gpkg` roughly doubles**, because it now
  carries a polygon layer per year instead of three." Contradicted by its own table two lines
  below: `bulk_co_ff04` grows **+27%** and `necr_ch_ff04` **+61%**. Only two of the four roughly
  double. The bolded generalisation is the sentence a consumer sizing a download acts on, and
  it is wrong by a factor of ~4 for `bulk`, the largest file in the set. The stated cause is
  also not sufficient: file size is not proportional to layer count when layers are rewritten
  into an existing GeoPackage (this repo's own note on floodplains#45), which is why +27% and
  +105% can both come from the same 3→7 change. Suggested: "grows by 27% to 105%" and drop the
  causal "because", or keep the cause and say the growth is not proportional.

- **[fragile]** `NEWS.md:44` — "Nothing *else* about the four changed, and that is measured
  rather than assumed:". The enumerated list after the colon is all true and was verified, but
  the blanket sentence is contradicted by the release's own bullet at `NEWS.md:83`: `necr` and
  `kotl` classified COGs each gained 30 metadata tags and 3,568 bytes. A reader who stops at
  line 44 takes away something the notes go on to deny. Scope the sentence to what was
  measured ("Nothing else about the four's *published properties or the other assets*
  changed"), or forward-reference the stray-tag bullet.

- **[fragile]** `NEWS.md:88` — "each rebuilt COG was compared against the bytes S3 was serving
  before publish: decoded pixels, CRS, transform, shape, dtype, nodata, block shape, overviews,
  compression and the embedded RAT all identical." Four of the eight COGs per item —
  `classified_2018`, `_2019`, `_2021`, `_2022` — are **new** and had no prior S3 bytes to
  compare against; `findings.md` records the comparison over exactly four per item
  (`transition_2017_2023`, `classified_2017/2020/2023`). The sentence sits fifty words after
  "10 assets to 14", so it reads as covering all fourteen. What actually covers the new years
  is the `/vsicurl/` consumer read (`findings.md`, Phase 5) — dtype, nodata, overviews and a
  9-row RAT on one new year per item — and NEWS does not mention it at all. Say "each of the
  four COGs that already existed", and add the new-year check.

- **[fragile]** `NEWS.md:63` — "the catalogue offers no field that says so". Measured on the
  live API: `nge:produced_datetime` is 2026-09-05T19:14:08Z–19:52:01Z on the four, while every
  other item is ≤ 2026-09-03T20:16:31Z and the v1.1.0 bucket sync is 2026-09-04T06:17–06:19Z.
  So in *this* release that field cleanly separates the four moved items from the nineteen and
  does post-date the stamped version. The general caveat that follows (it is upstream's run
  time, so it does not move when this repo republishes an item upstream did not re-run) is
  correct and is the reason not to *rely* on it — but the absolute claim steers a consumer away
  from a check that works here. Weaken to "no field that reliably says so", and note that these
  four happen to be distinguishable by `nge:produced_datetime` because upstream re-ran them.

- **[fragile]** `NEWS.md:50` — "**The other nineteen items did not move at all.** These were
  published one at a time with `catalogue_release.sh --only` …". "These" attaches to "the other
  nineteen items", the noun phrase immediately before it; the four are meant. On the natural
  reading the sentence asserts the opposite of the paragraph it opens. Replace with "The four
  were published one at a time…".

- **[fragile]** `planning/active/task_plan.md:62-67` — Phase 6's four boxes are all `[ ]`
  while this same commit contains the NEWS entry, the regenerated `README.md`, `index.html`
  and `data/readme_items.rds`, and `progress.md` records Phase 6 as done including "issue #59
  body corrected (two marked corrections)". The two planning files contradict each other
  inside one commit, and under this repo's atomic-commit convention the checkbox is the record
  a later reader trusts. Flip the four boxes in this commit (or, if the issue-body edit has
  not actually happened yet, say so in `progress.md` rather than claiming it).

None of the six is a data defect: the published catalogue matches every number in the entry.
All six are statements in the release notes or the planning record that a reader cannot check
and that would mislead — which is the class the repo's own "release note is where this costs
the most" rule names.
