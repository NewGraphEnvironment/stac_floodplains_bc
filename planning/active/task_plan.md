# Task: Publish all seven classified years for bulk, necr, lnth, kotl (#59)

`drift`'s `dft_rast_break_class()` needs every year of the classified series, not the
endpoints and midpoint — on BULK only ~20% of the published 2017→2023 change turned out to be
a switch sustained two years each side. `floodplains#79` re-ran four areas onto the full
annual span (step 3 only, so floodplain geometry and sub-basins are untouched) and closed
2026-09-05. **This issue publishes them.** PINE is deliberately out: no `provenance.json`,
rasters predate `flooded` 0.5.0.

Both blockers are clear. #61 already made the year set a property of the item, and its own
NEWS records `lnth_ch_ff04` — the first seven-year item — round-tripping stage → tag → COG →
style → build → validate with 14 assets and 13 style rows. So **no code change is expected
here**: this is a publish plus the documentation that goes with it.

**Decision taken at the plan gate (airvine, 2026-09-05):** publish with **four `--only` runs,
no tag**. `--only` never publishes `collection.json` so it cannot stamp a version; the served
version stays `1.1.0` until the next full release folds this in, exactly as `bulk_co_ff04`'s
#36 pilot was folded into v1.1.0. The 19 untouched items are never re-synced or
re-registered, so *every other item byte-identical* holds by construction rather than by luck.

## Phase 0: Baseline and premises

- [x] Pin the live baseline for **all 23 items** to `planning/active/baseline_live.json` — per item, every asset key with its `file:checksum` and `file:size`, plus every `nge:` property. Taken before anything is published; this is what Phase 5 measures against.
- [x] `uv run python scripts/style_drift-check.py` — proves `data/raw/classes.json` from the installed drift still byte-matches the committed `styles/`, i.e. the RAT the rebuilt COGs will carry is the one already published.
- [x] Record the premises in `findings.md`, with the fold reproduction as the headline (this repo's own independent confirmation of floodplains#79's element-wise claim).

## Phase 1: bulk_co_ff04

- [x] `WSG=bulk Rscript scripts/test_pipeline.R` — stage → tag → COG → style → build → validate (`--partial`). **No `ALLOW_DRIFT_SKEW`**.
- [x] Gate before publishing. **Corrected mid-run**: byte equality is unsatisfiable — every COG carries the item's provenance block in its TIFF tags, and four of those move when the year set widens. The gate instead asserts `transition_2017_2023` and `classified_2017/2020/2023` are **pixel-, geometry- and RAT-identical** to the bytes S3 is serving, allowing exactly those four tags to move and failing on any fifth. See `findings.md`.
- [x] `bash scripts/catalogue_release.sh --only bulk_co_ff04`
- [x] Read back: 7 `classified_*`, transition pixels/RAT unchanged, `nge:drift_version = 0.13.0`, `nge:landcover_key = sha256:16cbe101e74c5c1876bd5b890d13e5e491efcf129377fdfccc24971f478f91ef`

## Phase 2: necr_ch_ff04

- [ ] `WSG=necr Rscript scripts/test_pipeline.R`
- [ ] Gate before publishing (as Phase 1 — pixel/geometry/RAT identity, not byte equality)
- [ ] `bash scripts/catalogue_release.sh --only necr_ch_ff04`
- [ ] Read back; `nge:landcover_key = sha256:1635efbfe58ec14ff802480ea07f47a2d6a43ab195d60881160ed32b3d94571a`

## Phase 3: lnth_ch_ff04

- [ ] `WSG=lnth Rscript scripts/test_pipeline.R`
- [ ] Gate before publishing (as Phase 1 — pixel/geometry/RAT identity, not byte equality)
- [ ] `bash scripts/catalogue_release.sh --only lnth_ch_ff04`
- [ ] Read back; `nge:landcover_key = sha256:a7cd994b621ed5aa3c05c62698013a7bc7a57479bb5471da72bf4c9842403e7c`

## Phase 4: kotl_bt_ff04

- [ ] `WSG=kotl Rscript scripts/test_pipeline.R`
- [ ] Gate before publishing (as Phase 1 — pixel/geometry/RAT identity, not byte equality)
- [ ] `bash scripts/catalogue_release.sh --only kotl_bt_ff04`
- [ ] Read back; `nge:landcover_key = sha256:3c70e523394efb82632215d1b3cb4661c01e20e2df4676796ba6c7236be44af5`

## Phase 5: three-year control and whole-catalogue verification

- [ ] `ALLOW_DRIFT_SKEW=1 WSG=ufra Rscript scripts/test_pipeline.R` — build and validate only, **never published**; the flag is needed only because `ufra` is a drift 0.8.0 area. Satisfies "green on an untouched three-year item" on real data, not only `year_sets-check.py`'s synthetic trees.
- [ ] Re-read all 23 live items and diff against `baseline_live.json`. Assert the **19 untouched items are identical** in asset key set, every `file:checksum`, every `file:size` and every `nge:` property — and that the four moved in exactly the predicted places and nowhere else.
- [ ] Fetch every published `classified_*` href for the four over HTTP — `gdalinfo /vsicurl/…` on one to confirm the RAT survived, a ranged read on the rest (drift#62's acceptance).

## Phase 6: documentation

- [ ] **Correct issue #59's body** (edit, do not append) — the `landcover_key` / `item_hash` mapping, and that `CLAUDE.md` therefore needs no correction.
- [ ] `NEWS.md` **Unreleased**: a data entry for the four republishes, every number derived from the artifacts.
- [ ] Regenerate `README.md` and `index.html` from `README.Rmd` with `update_query: true`. **No hardcoded list of which items are annual.**
- [ ] Confirm `fig/coverage.png` did not move and both render targets are byte-stable on a second render.

## Phase 7: close out

- [ ] `/planning-archive` — archive README carries the measurement record.
- [ ] `/gh-pr-push`.

## Validation

- [ ] Every gate in Phases 1–4 passed *before* its publish, not after
- [ ] `item_validate.py` green on all four annual items and on `ufra_ch_ff04`
- [ ] The 19 untouched items diff clean against the Phase 0 baseline
- [ ] The four items' seven COGs readable over `/vsicurl/` from the published hrefs
- [ ] `/code-check` clean on each commit; PWF checkboxes match landed work
- [ ] `PROVENANCE_FLOOR` still `21` and untouched
- [ ] `/planning-archive` on completion
