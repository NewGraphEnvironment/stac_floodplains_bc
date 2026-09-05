# Findings — Publish all seven classified years for bulk, necr, lnth, kotl (#59)

## Premises established during plan-mode exploration (2026-09-05, m1)

All measured, none assumed.

| fact | evidence |
|---|---|
| Running on **m1**; all four areas hold 7 `classified_<yyyy>.tif` + `transition.tif` under `rasters/<scenario>/`, and a `provenance.json` with `landcover.<scen>.inputs.years = 2017..2023` | `find ../floodplains/data/<a>/rasters` |
| The four were produced by **drift 0.13.0**, which is what is installed on this machine | `provenance.json` `landcover.<scen>.inputs.drift.version` vs `packageVersion("drift")` |
| **Every other area is drift 0.8.0** — so these four are the only groups that can be staged without `ALLOW_DRIFT_SKEW=1` | scan of all 22 provenance-carrying areas |
| The collection document does **not** change: `summaries` carry `scenario`/`species`/`region`/`flood_factor`, nothing year-related | `scripts/item_create.py:616` |
| `floodplain_landcover.gpkg` now holds 7 `classified_*` layers (`data_type='features'`); `bulk` also carries the inert `patch_watercourse_co_ff04_2017_2023` table (#65, `attributes`), `kotl` does not — confirming #65's note that it is not a property of the annual span | `gpkg_contents` over the two files |
| `neexdzii` carries provenance upstream but is not in the published roster — which is why 22 provenanced areas reconcile with `PROVENANCE_FLOOR = 21` over 23 live items | live `POST /search` id list vs the provenance scan |

## `nge:landcover_key` reproduces exactly — this repo's own confirmation of floodplains#79

`scripts/fp_provenance.R:71` maps `landcover_key` to `inputs$classified_content_sha256`,
folded by `fp_fold_year_digests()`: `<year>=<digest>` lines, years ascending, newline-joined,
then `sha256:` of that text.

Recomputing that fold offline over **today's** producer file, restricted to the
2017/2020/2023 subset, reproduces the value each item is **currently serving** — 4 of 4:

| item | fold(2017,2020,2023) == live `nge:landcover_key` |
|---|---|
| `bulk_co_ff04` | yes |
| `necr_ch_ff04` | yes |
| `lnth_ch_ff04` | yes |
| `kotl_bt_ff04` | yes |

That is independent confirmation, from this repo, of floodplains#79's claim that the three
original years' `classified_content_sha256` are unchanged **element-wise**. It also means the
seven-year folds can be predicted before the build runs, which is what Phases 1–4 assert
against rather than reading the value back and calling it verified:

| item | predicted 7-year `nge:landcover_key` |
|---|---|
| `bulk_co_ff04` | `sha256:16cbe101e74c5c1876bd5b890d13e5e491efcf129377fdfccc24971f478f91ef` |
| `necr_ch_ff04` | `sha256:1635efbfe58ec14ff802480ea07f47a2d6a43ab195d60881160ed32b3d94571a` |
| `lnth_ch_ff04` | `sha256:a7cd994b621ed5aa3c05c62698013a7bc7a57479bb5471da72bf4c9842403e7c` |
| `kotl_bt_ff04` | `sha256:3c70e523394efb82632215d1b3cb4661c01e20e2df4676796ba6c7236be44af5` |

## The issue body is wrong about why `landcover_key` moves

Issue #59 says `scripts/fp_provenance.R` "maps it to `inputs$item_hash`, which is built from
the *requested* years". It does not. Line 71 maps `landcover_key` to
`inputs$classified_content_sha256`; line 73 maps `landcover_item_hash` to `item_hash`. The
two were split by #40 precisely so the fingerprint and the identity could not be confused.

So `landcover_key` moves for the four because **the item now publishes seven years and the
fingerprint covers seven years of content** — not because the key is built from a requested
year set. `CLAUDE.md`'s description of the key is accurate and needs no correction; the issue
body does. `landcover_item_hash` moves too, and there the issue's reasoning is right: 7
resolved STAC item ids where there were 3.

## Why four `--only` runs and no tag

`--only` never publishes `collection.json`, so it cannot stamp a version — the API keeps
serving `1.1.0`. Decision at the plan gate (airvine, 2026-09-05): publish that way anyway and
let the next full release fold it in, exactly as `bulk_co_ff04`'s #36 pilot was folded into
v1.1.0's notes. The alternative — a full rebuild and a tagged release — would need
`ALLOW_DRIFT_SKEW=1` for the 19 drift-0.8.0 areas and would re-sync and re-register items
nothing asked to move, putting their checksums at risk for a version string.

`01_stage.R` wipes `data/raw` and `data/stac` on every run, so the four are built and
published one at a time rather than as one tree.

## Phase 0 measurements (2026-09-05)

**Live baseline pinned** to `planning/active/baseline_live.json` at `2026-09-05T21:24:21Z`,
read one item at a time from the item endpoint so nothing is elided by a fields projection.
23 items, **10 assets each** (3 classified + transition + 3 GeoPackages + 3 styles). The
collection serves `version: 1.1.0`.

Three items serve **11** `nge:` keys rather than 12 — `kotl_bt_ff04`, `larl_bt_ff04`,
`sloc_bt_ff04`, all missing `nge:link_run_uid`. That is a published null, which the API
omits, not a lost key; `kotl_bt_ff04` is one of the four this issue republishes, so the
`--only` preflight's per-key comparison sees absent-vs-null and must treat them as equal —
which it does, by design (#36). Recorded here so the Phase 5 diff does not read it as
movement. `mcgr_ch_ff04` and `pine_bt_ff04` serve 0, as expected for the two
`deprecated: true` items.

**`style_drift-check.py` is clean**: the three committed styles are byte-identical to what
`classes.json` produces from the installed drift 0.13.0 (9 classes). So the class table has
not moved since `styles/` was committed at #46, and the RAT the four rebuilt COGs will carry
is the one already published. That is the premise the transition-checksum gate rests on — if
the table had moved, every rebuilt COG would differ for a reason unrelated to the year span.

## The issue's transition-checksum criterion is unsatisfiable — and the wrong question

Measured on `bulk_co_ff04`, 2026-09-05. The acceptance list asks for `transition_2017_2023`
to carry a `file:checksum` **equal to the currently published asset**, "the assertion that
proves [the transition inputs did not change]". It cannot hold, and it could never have held.

`02_raster_tag.py` stamps the item's whole provenance block into every COG's TIFF tags, so
widening the year set moves four of them by construction:

| tag | live | rebuilt | why |
|---|---|---|---|
| `NGE_LANDCOVER_KEY` | `sha256:66104a0f…` | `sha256:16cbe101…` | fold over seven digests, not three |
| `NGE_LANDCOVER_ITEM_HASH` | `sha256:c653b16d…` | `sha256:338282a6…` | seven resolved STAC ids, not three |
| `NGE_DRIFT_VERSION` | `0.8.0` | `0.13.0` | the producer re-ran on a newer drift |
| `NGE_PRODUCED_DATETIME` | `2026-09-02T20:46:08Z` | `2026-09-05T19:52:01Z` | the #79 re-run |

Every COG therefore moves bytes for reasons that have nothing to do with the raster. That is
v1.1.0's own warning arriving one release later: *a checksum answers "are my bytes current",
not "did the values change"* — and here the checksum could not answer the second question
even in principle, because the provenance the item publishes lives inside the file the
checksum covers.

**What does answer it is what a consumer reads.** Comparing the rebuilt COGs against the
bytes S3 was serving at that moment:

```
transition_2017_2023   pixels IDENTICAL, RAT identical, geometry identical, 4 tag(s) moved
classified_2017        pixels IDENTICAL, RAT identical, geometry identical, 4 tag(s) moved
classified_2020        pixels IDENTICAL, RAT identical, geometry identical, 4 tag(s) moved
classified_2023        pixels IDENTICAL, RAT identical, geometry identical, 4 tag(s) moved
```

sha256 over the decoded band, plus CRS, affine transform, shape, dtype, nodata, block shape,
overview levels, compression, and the RAT read out of TIFF tag 42112 through
`item_validate.py`'s own `_read_embedded_rat` rather than a second parser. The gate allows
exactly the four tags above to move and fails on any fifth — so a real difference cannot hide
behind the sanctioned ones.

Corroborating, and not asserted by the gate: `floodplain.gpkg`, `transition_vector.gpkg` and
all three `.qml` styles come back **byte-identical**, which is what says the build is
deterministic and the floodplain geometry is untouched. `floodplain_landcover.gpkg` moves, as
floodplains#79 predicted and floodplains#45 explains.

The gate is `scripts`-external (a one-off release gate, not a standing gaurd) and lives in the
session scratchpad; its logic and every result are recorded here, which is the durable copy.

## Phase 1 — bulk_co_ff04 published (2026-09-05)

Build `PASS`, gate `PASS`, release `RC=0`. Live item now serves **14 assets**, classified
2017..2023, and `nge:landcover_key = sha256:16cbe101e74c5c1876bd5b890d13e5e491efcf129377fdfccc24971f478f91ef`
— **equal to the fold predicted offline before the build ran**, which is the read-back
assertion that is not a round-trip through our own upload. `nge:landcover_item_hash` moved,
`nge:drift_version` is now `0.13.0`, every other `nge:` value is unchanged, and the
`floodplain` / `transition_vector` / three style assets carry unchanged checksums. The
collection stayed at 23 items, version `1.1.0`.

## Errors Encountered

| Error | Resolution |
|-------|------------|

## Issue context

## Context

drift v0.14.0's `dft_rast_break_class()` (drift#9) needs every year of the classified series, not the endpoints and midpoint. Run on BULK with all seven IO LULC years it found that only ~20% of the 2017 -> 2023 change the catalogue publishes is a switch sustained two years each side; 44% never settled. To see whether that holds beyond one group, floodplains is rerunning the areas with the full annual series (NewGraphEnvironment/floodplains#79). **This issue publishes them.**

## Four areas, not five — PINE is out

`bulk_co_ff04`, `necr_ch_ff04`, `lnth_ch_ff04`, `kotl_bt_ff04`.

floodplains#79 dropped PINE: `data/pine/` has no `provenance.json` and its floodplain rasters date to 2026-07-12, before `flooded` 0.5.0 — the bankfull-units vintage that repo's `CLAUDE.md` calls *dead, not merely superseded*. Publishing an annual series over it would ship a seven-year land-cover story on a floodplain already known to be wrong. PINE and MCGR are tracked by NewGraphEnvironment/floodplains#76 and will arrive with `lulc_annual` already on, so neither needs publishing twice.

## Both blockers are now clear — this is ready to start

1. **#61** — CLOSED 2026-09-05 (PR #62). `scripts/01_stage.R` no longer carries
   `YEARS <- c(2017, 2020, 2023)`: it derives the year set from the staged rasters and reconciles
   it against the item's provenance (`fp_years_reconcile`), and ships `stage_years-check.R` and
   `year_sets-check.py`. The #23 two-population decision was made there.
2. **floodplains#79** — CLOSED 2026-09-05 (floodplains PR #82, merge `2826240`). All four areas
   re-run step 3 only, so their floodplain geometry and sub-basins are untouched, and each passed
   the full acceptance set: the 2017/2020/2023 content digests unchanged element-wise,
   `transition_content_sha256` and `transition_patches` unchanged, seven `classified_*` layers and
   tifs with no eighth.

**The data lives on m1** (`~/Projects/repo/floodplains/data`, which is what `$FLOODPLAINS_DATA`
defaults to — `../floodplains/data`). m4 carries only `necr`, `kotl` and `neexdzii`, so the publish
has to run on m1.

## What floodplains#79 guarantees, so this issue does not have to re-establish it

Per-area, asserted there against a pre-run baseline:

- `transition_2017_2023` is **unchanged** — same content digest, same patch count. The transition is measured endpoint-to-endpoint from `change_interval`, never from the fetched year set.
- The 2017 / 2020 / 2023 `classified_content_sha256` values are unchanged **element-wise**, and every year was genuinely re-fetched (the baselines were built under drift 0.8.0, whose cache keys predate the 0.10.0 change, so nothing was cache-served).
- Provenance `years` is `2017..2023` and `inputs_hash` moves; `outputs_hash` does not.

Two consequences that are **not** defects and should not be read as drift:

- `floodplain_landcover.gpkg` **bytes** move for every area even where content does not — rewriting one layer into an existing GeoPackage is not byte-stable (floodplains#45). Byte equality answers "same build?", not "same content?".
- **`nge:landcover_key` moves** for all four areas with no land-cover change, because `scripts/fp_provenance.R` maps it to `inputs$item_hash`, which is built from the *requested* years. Seven year-lines instead of three, over an item set the widened request did not change. (Counts are per-AOI: necr and kotl each record 7 ids, one per year; the "14" is neexdzii's two-tile figure and does not describe these four.) If that key is documented anywhere as a content pin, this is the moment to correct it.

## Acceptance

- [ ] The four items republished with `classified_2017` … `classified_2023` present
- [ ] `transition_2017_2023` **checksum equal to the currently published asset** for each — the transition inputs did not change, and this is the assertion that proves it
- [ ] `item_validate.py` green on all four AND on an untouched three-year item
- [ ] Every other item byte-identical (provenance and checksums)
- [ ] `--only` republish naming exactly these four ids (#26: an arm must name an id the subset contains)
- [ ] README asset table and NEWS updated; release notes derived from the artifacts, not restated from this issue
- [ ] drift#62 can read the seven COGs per item straight from the published hrefs

## Related

- Year abstraction, blocking: #61
- Produces the rasters: NewGraphEnvironment/floodplains#79
- PINE / MCGR: NewGraphEnvironment/floodplains#76
- Analysis once published: NewGraphEnvironment/drift#62


