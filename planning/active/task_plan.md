# Task: Make the classified year set per-item from provenance, not a three-year constant (#61)

## Problem

The per-item classified year set is a **three-year constant**, not a property of the item.
`scripts/item_create.py` already iterates `meta["years"]` from the provenance, so the item
*body* is data-driven — but the staging layer that feeds it is not:

- `scripts/01_stage.R:29` — `YEARS <- c(2017, 2020, 2023)`, used for the raster-currency
  check (`fp_prov_rasters_current`), the `classified_%d.tif` staging list, and passed into
  `fp_prov_item()` (`:217, :228, :337, :357`).
- `scripts/fp_provenance.R:83, 369` — asserts the provenance `years` **against that
  constant**, so an item whose provenance legitimately carries seven years fails a guard
  that is measuring the constant rather than the item.
- `scripts/item_validate.py:141-155` and `scripts/item_create.py:8, 569` — description text
  says "three classified years".

The fix is the same everywhere: **the year set comes from the item's own provenance `years`
field, and the staged files are asserted against that, per item.**

## Context established before the baseline

**This is live, not hypothetical.** `../floodplains/data/lnth/provenance.json` records seven
years (2017-2023) with seven `classified_*.tif` on disk, stamped `2026-09-05T19:17:07Z` —
floodplains#79 is producing right now. The next rebuild changes `lnth_ch_ff04` whether or not
this issue lands, and `item_validate.py`'s cross-item asset-key check would refuse the build.

Verified against the tree, so nobody re-derives it:

- All 22 provenanced landcover sections carry `inputs.years`, and in every one
  `sorted(classified_content_sha256.keys()) == years` and `change_interval == [2017, 2023]`.
- Exactly two rostered items have no provenance at all: `mcgr_ch_ff04`, `pine_bt_ff04` — the
  two `DEPRECATED_ITEMS`. (`../floodplains/data/logs/` also lacks one; it is a log directory,
  in no region roster, and never stages. The coincidence is not the rule.)
- `02_raster_tag.py`, `03_cog.py`, `style_qml-write.py`, `04_gpkg_style.py`,
  `readme_functions.R` are already year-agnostic. **`styles/` stays three QMLs** — the issue's
  "seven QMLs" is wrong; `04_gpkg_style.py` maps by layer prefix, so a seven-year GeoPackage
  gets seven `layer_styles` *rows* from the one `classified.qml`.
- `PROVENANCE_FLOOR=21` is unaffected: `lnth` stays provenanced.

## The design decision that shapes everything: disk is the source, the record is the check

Reading `years` from provenance and then folding `classified_content_sha256` **against that
same file** makes `fp_fold_year_digests` circular — two adjacent keys written by one upstream
step, agreeing with each other. The comment at `fp_provenance.R:83-86` ("asserted against the
ITEM's published span, not against whatever the map happens to hold") stops being true.

So the order is:

1. `years_record` <- `landcover.<scenario>.inputs.years` (NULL when the section is absent)
2. `years_disk` <- anchored discovery of `classified_<yyyy>.tif` in the source raster dir
3. assert `setequal(years_disk, years_record)` **both directions**, naming the disagreement
4. publish `years_disk` as `meta$years`, and pass `years_disk` into `fp_prov_item()`

The independent assertion now lives at the disk/record boundary in `01_stage.R`, and the fold
keeps two different producers on its two sides. `fp_fold_year_digests` stays caller-supplied —
it must never read provenance itself, or `fp_provenance-check.R`'s "a missing year stops" /
"an extra year stops" cases lose their meaning too.

**Losing `YEARS` loses a refusal, so three absolutes replace it** (`TRANSITION_SPAN` stays a
constant and becomes the anchor — "the year set is data, the span is a contract"):

- `TRANSITION_SPAN` subset of `years` — both endpoints must be classified, or the transition
  asset describes a span the item does not carry
- `change_interval == TRANSITION_SPAN` when the landcover section exists (a second key,
  written for a different purpose, about the same span)
- `length(years) >= 2`, distinct, integer-valued. Not pedantry: `length(years) == 1` is a
  latent crash, not a refusal — `jsonlite` with `auto_unbox=TRUE` emits `{"years": 2017}` and
  `item_create.py:327`'s `for yr in meta["years"]` then raises `TypeError`.

Unprovenanced items (`mcgr`, `pine`) take `years_disk` with an explicit message that there is
no record to check against (airvine, 2026-09-05). The three absolutes above still apply to
them, so the path is not unguarded. The plan reviewer argued for a `YEARS_UNPROVENANCED`
literal instead, on #34/#35 grounds; recorded rather than silently dropped.

## Phase 1 — Read the year set per item, assert it against disk

- [x] Add `fp_prov_span(prov, species, scenario, where)` to `scripts/fp_provenance.R` —
      named for what it returns, which is BOTH `years` and `change_interval` from one
      `fp_prov_sections()` call rather than two. Sorted integer vectors, or NULL when the
      landcover section is absent. Section present but the key absent or wrong-shape ->
      `stop()`, matching `fp_prov_leaf`'s three-state discipline
- [x] Add the shape absolutes there too: distinct, integer-valued, `length >= 2`
- [x] `scripts/01_stage.R`: delete `YEARS`; discover `years_disk` with an **anchored** pattern
      `"^classified_[0-9]{4}\\.tif$"` (`list.files(pattern=)` is unanchored, and every source
      dir carries `classified_<yyyy>.tif.aux.xml` sidecars), asserting the file count equals
      the year count
- [x] Assert `setequal(years_disk, years_record)` both directions when the record exists;
      assert `TRANSITION_SPAN` subset of `years` and `change_interval == TRANSITION_SPAN`
- [x] Reorder the call site: read prov -> `fp_prov_years` -> discover -> assert ->
      `fp_prov_rasters_current(<discovered paths>)` -> copy -> `fp_prov_item(..., years_disk)`.
      Passing the *discovered* paths is a free widening — today the function filters
      `raster_paths[file.exists(...)]`, so a raster upstream wrote that the record does not
      name has never been mtime-checked. Add `transition.tif` to that list while it is open
- [x] Note in a comment that `fp_prov_sections()` now runs three times per target (it only
      stops earlier on a schema break), so the next reader does not wonder

## Phase 2 — Offline proof, including restore-the-bug

- [ ] `scripts/fp_provenance-check.R`: add `years` to `synthetic()`; keep the file's own
      `YEARS` fixture constant (the fold stays caller-supplied)
- [ ] New cases: NULL on absent section; stop on present-section-no-`years`; stop on
      non-distinct / non-integer / length-1 years; a seven-year fold; and the one nothing else
      in the file can reach — **`inputs.years` disagreeing with `classified_content_sha256`'s
      keys**
- [ ] Restore-the-bug, **three arms, three distinct messages**, each proved by grepping for
      *that guard's* message (a suite with N guards has N ways to exit 1):
      (a) a `classified_*.tif` deleted from a copied source tree;
      (b) `provenance.json` `years` naming a year with no raster;
      (c) a raster on disk the record does not name — the direction with no guard today
- [ ] Assert each mutation took before trusting the refusal, and say which copy of each
      deliberately-duplicated literal the guard reads (#26's mirror: a proof that mutates the
      wrong copy exits 0 and reads as a pass)

## Phase 3 — The #23 two-population decision

- [ ] `scripts/item_validate.py`: add `ALLOWED_YEAR_SETS` as a human-set literal, with the
      **partition written down beside it** — fixed keys identical across all items;
      `classified_*` keys per item against the literal
- [ ] Split `check_checksums`'s `expected_keys = max(asset_keys.values(), key=len)` accordingly
- [ ] Exact in both directions, like `EXPECTED_DEPRECATED`: arm (a) every item's classified key
      set equals some member; arm (b) every member is used by >=1 item (an unused entry is a
      literal nobody updated)
- [ ] **`--partial` partition** (#26): arm (a) names keys the subset *contains* -> stays on;
      arm (b) asks about items *absent* from the subset -> dropped. This matters more than it
      looks: `catalogue_release.sh:405` passes `--partial` under `--only`, and on a one-item
      tree the cross-item arm is vacuous, so the literal is the *only* thing checking `lnth`
- [ ] Add the independent arm the literal cannot give: each item's `classified_*` asset keys
      must equal the `classified_<yyyy>.tif` **files in `data/stac/<item_id>/`**, both
      directions. `aws s3 sync` uploads every file in that directory regardless of whether an
      asset describes it, so a stray COG reaching a public bucket is caught by nothing today
- [ ] Print per-set item counts, as `check_provenance` already prints per-section counts
- [ ] Do **not** derive the expectation from `data/raw/<id>/meta.json["years"]` —
      `item_create.py:327` builds the asset keys from that list

## Phase 4 — The downstream literals

- [ ] `scripts/test_pipeline.R:103` `length(cogs) == 4L` -> `length(meta$years) + 1`, with a
      set comparison against the expected names
- [ ] `scripts/test_pipeline.R:222` `length(item_assets) != 10L` -> per item. **Second literal,
      same file** — `WSG=lnth` fails here (14 assets) the moment `:103` is fixed
- [ ] `scripts/item_create.py:569` collection description: "three classified years" -> per-item
      wording. Unguarded prose in both directions (`EXPECTED_DERIVATION_STATEMENT` is a
      containment check; `attribution_drift-check.py` parses only `CITATION`), so no second copy
- [ ] `scripts/run_pipeline.sh:25-29`: `ALLOW_DRIFT_SKEW` has the same persistence hazard as
      the `ALLOW_SKIPPED` the banner already warns about, and a worse consequence. One line

## Phase 5 — Acceptance against the live catalogue, then the docs

- [ ] **The local A/B in the issue's last acceptance box cannot run as written.** Installed
      `drift` is **0.13.0**; 21 of 22 sections record `0.8.0`, so `01_stage.R:378` stops at
      *bowr* — there is no "before" build. Instead compare each rebuilt
      `data/stac/<id>.json` against the **live item from the API**, assets and properties
      wholesale, reusing the comparator that already exists at
      `catalogue_release.sh:576-594` (`--only`'s `live_state` block). Ground truth at the
      consumer, not one of our own builds against another
- [ ] Name in advance exactly what is expected to move, rather than "excluding lnth" —
      excluding the one item you changed hides a regression inside it. Expected: `lnth_ch_ff04`
      only, and within it `nge:landcover_key`, `nge:landcover_item_hash`,
      `nge:produced_datetime`, `nge:drift_version`, four new `classified_*` assets, and the
      area/loss/gain/net figures if upstream's re-run moved them
- [ ] Run `ITEM=lnth_ch_ff04` through `gpkg_determinism-check.R` and
      `style_determinism-check.py` once. Both default to `sloc_bt_ff04`, a three-year item;
      `lnth` has 8 styled feature layers instead of 4. Neither check is year-dependent, so
      this is varying the fixture along the axis it cannot reach — not a code change
- [ ] Write down (no code change): `lnth`'s `floodplain_landcover.gpkg` carries an extra table
      `patch_watercourse_ch_ff04_2017_2023`, registered `data_type='attributes'`. All three
      surfaces that walk layers filter on `features`, so it is inert — **verified, not
      reasoned** — but it ships inside a published asset that nothing here describes, and it is
      one upstream `data_type` value away from stopping a release
- [ ] `README.Rmd:129` asset table + the "Ten assets each" line -> per item. **Its own commit**,
      `update_query` off: both targets must render byte-identically from an unchanged cache
- [ ] `NEWS.md`: new entry only. The `v1.1.0` "Seven assets per item" line is history

## Validation

- [ ] `Rscript scripts/fp_provenance-check.R` green, including the three restore-the-bug arms
- [ ] `WSG=lnth Rscript scripts/test_pipeline.R` and `WSG=ufra ...` both green — one item from
      each population, end to end through the same gate a release uses
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work; `/planning-archive` on completion
