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
