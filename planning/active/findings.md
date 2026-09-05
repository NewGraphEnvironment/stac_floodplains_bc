# Findings — Make the classified year set per-item from provenance (#61)

## Issue context

Split out of #59, which bundled three things with different blockers: this code
generalization (blocked on nothing, testable offline), a collection-wide policy decision,
and the actual republish of four items (blocked on NewGraphEnvironment/floodplains#79).
#59 keeps the operation.

Acceptance, from the issue body:

- No `YEARS` constant remains in the staging path; every year set is read from the item's
  provenance
- `item_validate.py` green on a seven-year item **and** on an untouched three-year item,
  with the year-set rule written beside the guard
- The #23 two-population decision made, implemented, and stated in the guard's own comment
- Restore-the-bug proof: a staged item whose rasters do not match its provenance `years` is
  **refused**, and the proof greps for that guard's message rather than reading an exit code
- Style writer produces seven QMLs for a seven-year item, idempotent across two passes
- Every existing three-year item byte-identical — this issue changes code, not data

Related: publishes the four areas once this lands (#59); produces the rasters
(NewGraphEnvironment/floodplains#79); analysis (NewGraphEnvironment/drift#62).

## Measured before the baseline (2026-09-05)

Everything here was read off the tree, not reasoned. Dates matter: floodplains#79 was
running during this session.

| fact | how measured |
|---|---|
| `lnth/ch_ff04` carries seven years (2017-2023), stamped `2026-09-05T19:17:07Z` | `provenance.json` |
| seven `classified_<yyyy>.tif` on disk for `lnth`, three for every other area | `find .../rasters/<scen> -name 'classified_*'` |
| all 22 provenanced landcover sections carry `inputs.years` | walked every `provenance.json` |
| in all 22, `sorted(classified_content_sha256.keys()) == years` | same walk, 0 mismatches |
| in all 22, `change_interval == [2017, 2023]` | same walk, 0 mismatches |
| exactly two **rostered** items lack provenance: `mcgr_ch_ff04`, `pine_bt_ff04` | the `DEPRECATED_ITEMS` pair |
| `../floodplains/data/logs/` also lacks provenance but is a log directory, unrostered, never staged | `find logs/ -maxdepth 1` |
| installed `drift` is **0.13.0**; 21 of 22 sections record `0.8.0`, only `lnth` records 0.13.0 | `packageVersion("drift")` |
| `lnth`'s `floodplain_landcover.gpkg` holds an extra `patch_watercourse_ch_ff04_2017_2023` table, `data_type='attributes'` | `gpkg_contents` query |

## The three blockers a plan review surfaced, all confirmed against the tree

**B1 — a full rebuild has no runnable "before".** `01_stage.R:378` stops when the producer's
`drift_version` differs from the installed one. Installed is 0.13.0, 21 of 22 sections record
0.8.0, so the very first area (bowr) stops unless `ALLOW_DRIFT_SKEW=1`. The issue's last
acceptance box ("every existing three-year item byte-identical") therefore cannot be a local
A/B; the live API is the baseline instead.

**B2 — `test_pipeline.R` has a *second* hardcoded count.** `:103` (`length(cogs) == 4L`) is
the one the issue names; `:222` (`length(item_assets) != 10L`) is not, and `WSG=lnth` fails
there with 14 assets the moment `:103` is fixed. Two literals, one file, one commit —
CLAUDE.md's "a fix that reaches one enforcement surface reads as complete on all of them".

**B3 — `--only` passes `--partial`.** `catalogue_release.sh:405`. On a one-item tree
`expected_keys = max(asset_keys.values(), key=len)` is that item's own set, so the cross-item
arm is **vacuous** and `ALLOWED_YEAR_SETS` is the only thing checking a seven-year item at
release. The #26 partition applies: an arm naming keys the subset *contains* stays on; an arm
asking about items *absent* from the subset must be dropped.

## Circularity: why disk is the source and the record is the check

Sourcing `years` from provenance and then folding `classified_content_sha256` against it
compares two adjacent keys written by one upstream step into one section of one file. The
existing comment at `fp_provenance.R:83-86` claims the fold is asserted against "the ITEM's
published span, not whatever the map happens to hold" — which stops being true.

Fix costs nothing: publish the **disk-derived** set and hand *that* to the fold. The
independent assertion then lives at the disk/record boundary in `01_stage.R`, and the fold
keeps two different producers on its two sides. `fp_fold_year_digests` must stay
caller-supplied; if it read provenance itself, `fp_provenance-check.R`'s "a missing year
stops" / "an extra year stops" cases would lose their meaning too.

## What replaces the refusal `YEARS` used to give

With `YEARS` a literal, upstream dropping 2020 stopped at `01_stage.R:235`
(`Missing source raster`). Afterwards, upstream dropping 2020 from *both* `years` and disk
publishes a two-year item, green. Three absolutes replace it:

- `TRANSITION_SPAN` subset of `years` — both endpoints must be classified
- `change_interval == TRANSITION_SPAN` when the landcover section exists
- `length(years) >= 2`, distinct, integer-valued

The third is a latent crash, not pedantry: `jsonlite` with `auto_unbox=TRUE` emits
`{"years": 2017}` for a length-1 vector, and `item_create.py:327`'s `for yr in meta["years"]`
then raises `TypeError: 'int' object is not iterable`.

## The population moved during the session

floodplains#79 converts areas one at a time, and it did so while this work was in flight:

| time (UTC) | state |
|---|---|
| 19:17 | `lnth` at seven years — the only one |
| 19:25 | first scan: 1 of 22 sections annual |
| 19:52 | `bulk` converted; `kotl` 19:46, `necr` 19:14 — 4 of 22 |

Two fixtures rotted as a direct result, both inside one hour (see the error table). Anything
in this repo that pins a value taken from a producer file now needs a currency gate beside
it, or it will fail as "the code broke" when it means "upstream re-ran". Two are now gated
that way: `neexdzii`'s `landcover_key` pin and `ufra`'s `meta.json` digest, each on its own
area's `produced_datetime`.

## Corrections to the issue body

- **"Style writer produces seven QMLs for a seven-year item" is wrong.** `styles/` holds three
  committed QMLs and `04_gpkg_style.py` maps them by layer prefix, so a seven-year GeoPackage
  gets seven `layer_styles` *rows* from one `classified.qml`. `style_qml-write.py` needs no
  change; the fixture work is running the two determinism checks against `lnth`.
- **`item_validate.py:141-155` does not say "three classified years".** That range is
  `EXPECTED_CITATION`. The "three classified years" prose is `item_create.py:569` only.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `fp_provenance-check.R` real-file case died: `classified_content_sha256 covers year(s) 2017..2023 but the item publishes 2017, 2020, 2023` | The fixture `YEARS` constant was standing in for the real file's span, and floodplains#79 converted `bulk` to seven years mid-session. Real-file cases now read the span with `fp_prov_span()`; the synthetic cases keep the constant, so the fold's two-producer property is still proven where it can be |
| `stage_years-check.R` byte-identity control failed against a correct build | The sandbox region roster said `region: test`, and `region` is a published `meta.json` field. Copy the real region name out of the upstream roster; never invent a value a fixture then asserts is stable |
| The reference build vanished between two measurements | `01_stage.R:80-81` unlinks `data/raw` and `data/stac` **wholesale** on every run, so staging any single group destroys the previous full build. A before/after comparison against `data/` is present or absent depending on what was run last, and absent reads as a pass — hence the gated pin |

## Acceptance: what "changes code, not data" was actually measured against

The issue asks for "every existing three-year item byte-identical". The local A/B the phrasing
implies is not available — `01_stage.R:80-81` wipes `data/` on every run, and installed `drift`
is 0.13.0 against a recorded 0.8.0 on 18 of 22 sections, so a full "before" build stops at the
first area without `ALLOW_DRIFT_SKEW=1`. Three measurements were taken instead, weakest first:

1. `ufra_ch_ff04`'s `meta.json` restages byte-identical to the pre-change build
   (`22c2460f…`), now a standing assertion in `stage_years-check.R` rather than a one-off.
2. Both populations round-trip stage → tag → COG → style → build → validate:
   `WSG=lnth` (seven years, 14 assets, 13 style rows) and `WSG=ufra` (three years, 10 assets).
3. **The strongest, and it is ground truth at the consumer rather than one of our own builds
   against another:** the rebuilt `ufra_ch_ff04.json` compared field-by-field against the LIVE
   item at `images.a11s.one`. 10 assets on each side, identical key sets, **0 asset fields
   moved** (href, `file:checksum`, `file:size`, roles, type, title), **0 properties moved**,
   geometry and bbox identical. The comparison treats an absent live property as equal to a
   published null, because pgstac stores the null and the API omits it (measured 2026-09-02).

What IS expected to move, named in advance rather than excluded: `lnth_ch_ff04`,
`bulk_co_ff04`, `kotl_bt_ff04` and `necr_ch_ff04` — the four areas floodplains#79 had
converted by 19:52 UTC — and within each, four new `classified_*` assets,
`nge:landcover_key`, `nge:landcover_item_hash`, `nge:produced_datetime`,
`nge:drift_version`, and any area/loss/gain/net figure the upstream re-run moved. Publishing
those is #59, not this PR.

## Two things worth knowing that are not code changes

- `lnth`'s `floodplain_landcover.gpkg` carries an extra table
  `patch_watercourse_ch_ff04_2017_2023`, registered `data_type='attributes'`. All three
  surfaces that walk layers (`04_gpkg_style.py`, `item_validate.check_layer_styles`,
  `test_pipeline.R`) filter on `features`, so it is inert — verified against the file, not
  reasoned. It still ships to a public bucket inside a published asset that nothing in this
  repo describes, and it is one upstream `data_type` value away from stopping a release.
- `test_pipeline.R` could not validate any watershed group but `mcgr`/`pine` since #26
  landed — confirmed by stashing this branch and reproducing on `main`. Fixed here because
  the issue's own acceptance criterion ("green on a seven-year item and on an untouched
  three-year item") is untestable without it.
