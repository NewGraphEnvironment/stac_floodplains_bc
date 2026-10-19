# Code-check round 3 — `98-publish-in-wsg-and-in-open-water-items`

Base `affcd31`, diff `git diff affcd31...HEAD`. Reviewer: code-check agent, 2026-10-19.
Read in full: the branch diff, repo `CLAUDE.md`, the concatenated soul code-check conventions,
`review-round1.md`, `review-round2.md`, `findings.md`, `progress.md`, `task_plan.md`, and every
changed script.

Nothing in the working tree or under `data/` was modified (`git status --porcelain` empty at the
end of the round). Every probe is read-only: `sqlite3 … mode=ro` over the published GeoPackages,
`json.load` over `data/stac`, `sf::st_read` over the published files and over
`$FLOODPLAINS_DATA`, module imports of `item_validate` / `only_preflight`, and one synthetic
tree built under the scratchpad.

**The live API answered this round** (it timed out for round 2). All 23 live items were fetched
from `https://images.a11s.one/collections/stac-floodplains-bc/items/<id>` and compared against
the build, so every claim round 2 had to take as stated is now independently measured.

---

## Mechanism

Your hypothesis is right about the *shape* and understates the *reach*. The mechanism is:

> **A claim is written by restating a source — the upstream issue body, a sibling copy of the
> same sentence, or an earlier draft of itself — and is then checked for the *presence* of the
> thing it names rather than re-derived from the artifact it is attached to. The sentence
> therefore ends up naming a quantity adjacent to the one anybody measured.**

Three things follow from that framing, and all three are load-bearing this round:

1. **The defect is a substituted quantity, not a wrong number.** Every one of the ten earlier
   findings and five of this round's nine are of the form "X is the measured value of *some*
   quantity, just not the one the sentence names": total patch area for tree change (round 2
   F1), the raw `area_ha` sum for the filtered one (round 2 F2), "no key" for "at least one key
   missing" (round 2 F4), and now *footprint-minus-in_wsg* for *ground a neighbour also
   publishes*, *columns present* for *key*, and *the landcover run stamp on 22 groups* for
   *`processing:datetime` on 23 items*. The discriminating probe is always one SQL query or one
   JSON read against the artifact the sentence is attached to, which is why presence-checking
   never catches it.

2. **A fix lands in the copies someone was looking at.** `01_stage.R`'s `st_union` comment was
   corrected in round 1 and `CLAUDE.md` rewritten with the measurement — and `NEWS.md:82` still
   says the geometry is unchanged, which is the only one of the three a consumer reads. The
   any-touch antecedent was corrected in `NEWS.md`, `CLAUDE.md` and the `transition_vector`
   asset description after round 2 — and `item_create.py:434`, the *published* landcover
   description, still says "both flags are any-touch". This is `code-check.md`'s "a fix lands in
   one of two callers" applied to prose: the branch carries one claim in up to six copies
   (the neighbour claim is in six), and nothing joins them, where the repo pins its literal
   duplications with `attribution_drift-check.py` and `prov_fields-check.py`.

3. **It is not confined to prose, and that is the part worth taking away.** The same
   presence-for-property substitution produced the new guards' blind spot.
   `check_gpkg_columns` asserts the six context columns are *present*; `check_metric_scopes`
   asserts the two scopes are *ordered* and *internally consistent*. Neither asserts the
   published figures are the ones this release's whole safety argument rests on
   ("the `in_wsg` change figures reproduce every live value"). Measured: an **inverted**
   `in_wsg` polarity publishes `bulk` `floodplain_ff04_km2 = 13.18` and `net_ha = +15.5` —
   a sign flip on the headline figure — and the full release gate reports **zero problems with
   the straddle census at 23/23** (finding 1, probed end to end). The census was built for a
   *dropped* filter; the adjacent mutation is a *mis-polarised* one, and it increases the
   straddle count instead of zeroing it.

So the enumeration below is over "every added claim naming a number, a quantifier or an
identity", as asked — and the New findings section adds the one code defect the same mechanism
produced.

---

## Enumeration

**Set size: 57 claims** across the five prose surfaces and the code comments named in the brief.
Verdicts: **44 correct**, **9 wrong** (measured value given), **3 overstated** (true of a subset
or on a strained reading), **1 not reproduced**.

Every "correct" below is a measurement taken this round, not a recollection; the three
unmeasurable-by-round-2 live-API claims are now measured.

### `scripts/item_create.py` — PUBLISHED on all 23 items and on the collection (11)

| claim | where | measured verdict |
|---|---|---|
| landcover: "every data layer carries wsg/species/scenario … and `in_wsg`" | `:430-433` | **correct** — 269 of 269 published data layers over 23 items carry all four (`PRAGMA table_info` over all 69 GeoPackages) |
| landcover: "Every data layer is split along that boundary, so a layer that was one row is now one per side" | `:433-435` | **correct** — `all_ff02/04/06` are exactly 2 features on 23/23; `classified_*` rows == distinct(class_name, in_wsg) on all 85; `*_by_blue_line_key` rows == distinct(blue_line_key, in_wsg) on 23/23 |
| landcover: "The transition patches also carry `in_open_water` and `open_water_poly_id`" | `:433-434` | **correct** — both present on all 46 `transition*` layers |
| landcover: "**both flags** are any-touch, so areas by flag come from the `composition_*` table" | `:434-435` | **WRONG** — `open_water_poly_id` is an identifier, not a flag (`item_validate.py:996-998` says so), and `composition_*` has no such column, so "areas by flag" is unavailable for it. Finding 2 |
| floodplain: "a delineation is one row per side rather than one row" | `:457-458` | **correct** — 2 features each on all 69 delineation layers |
| floodplain: "the item's `floodplain_ff0N_km2` is the `in_wsg` area and `floodplain_ff0N_footprint_km2` is both sides" | `:458-460` | **correct** — reproduced from the gpkg for BULK/PCEA; and 23/23 `*_footprint_km2` equal the live item's unsuffixed area exactly |
| transition_vector: "the layer this item's `gross_loss_ha`/`gross_gain_ha`/`net_ha` are aggregated from" | `:478-480` | **correct** — `SUM(area_ha) WHERE in_wsg=1 AND from_class='Trees' AND to_class<>'Trees'` = `gross_loss_ha` on BULK and PCEA |
| transition_vector: "the headline properties sum the TRUE rows while the `*_footprint_*` siblings sum every row" | `:481-483` | **correct** (under the stated filters) |
| transition_vector: "alongside the producer's existing `in_fire`/`in_harvest`/`in_wetland`/`in_alr` … **Those are any-touch, so read areas by one of them from `composition_*`**" | `:487-491` | **WRONG** — `composition_*` carries `in_wsg`, `in_open_water`, `in_wetland`, `in_alr`, `in_floodplain` and **no `in_fire`, no `in_harvest`** (measured on all 23). The instruction cannot be followed for 2 of the 4 columns it names. Finding 3 |
| transition_vector: "`in_wsg` … is a true partition of the patches" | `:493-495` | **correct** — `SELECT DISTINCT in_wsg` is exactly `(0,1)` with no NULL on all 269 layers |
| collection: "the difference between a pair is ground shared with a neighbour, **which that neighbour's own item also publishes**" | `:757` | **WRONG** — of the 519.16 km² total difference, only **50.58 km² (9.7%)** is covered by another item's own `in_wsg` floodplain; **468.57 km² (90.3%)** is ground no item publishes. On PCEA, the flagship case, **0.4%** (1.25 of 351.97 km²). Finding 4 |

### `README.Rmd` — the public landing page (10)

| claim | where | measured verdict |
|---|---|---|
| "**Every data layer is split at the watershed group boundary, and carries `in_wsg`**" | `:140` | **correct** — 269/269 |
| "A layer that would once have been one row is one row per side" | `:140` | **correct** |
| transition patches carry `in_open_water` + `open_water_poly_id`, FWA lakes + manmade waterbodies, no size cut-off | `:140` | **correct** — columns present on 46/46; provenance `composition.inputs.overlays.open_water.table` is `[fwa_lakes_poly, fwa_manmade_waterbodies_poly]` on all 23 |
| "Like `in_wetland`, **it** is an any-touch flag, so read areas by flag from the `composition_*` table" | `:140` | **correct on the intended antecedent** (`in_open_water`, present in `composition_*`); the nearest singular antecedent in the sentence is `open_water_poly_id`, which is why the same sentence is wrong in `item_create.py:434`. Overstated at worst here |
| "Every headline figure is published in two scopes" | `:146` | **correct** — all 12 present and numeric on 23/23 |
| "The difference between a pair is ground shared with a neighbour, **and that neighbour's own item publishes it too** — so summing the footprint figures across groups double-counts, while summing the unsuffixed ones does not" | `:146` | **first half WRONG, second half correct** — double counting is 50.58 km² (0.48% of the footprint sum), not 519; 468.57 km² is ground no item publishes. The unsuffixed sum *is* a true union: union of the 23 `in_wsg` pieces 10,092.24 km² against the published sum 10,092.27. Finding 4 |
| "The gap is usually 1–3%" | `:146` | **correct** — 16 of 23 in [1,3]%; 3 below (0.81/0.83/0.92%) and 4 above (3.02/3.17/3.25% + PCEA); 22 of 23 lie in 0.8–3.3% |
| "for `pcea_all_ff04` it is 42%, because that much of the item's floodplain lies in Williston Reservoir's arms **inside `PARS` and `FINA`**" | `:146` | **42% correct** (41.73%), **attribution wrong** — 1.28 of 351.97 km² (0.4%) is inside the PARS group polygon and 1.25 km² inside PARS's published floodplain; 350.69 km² is outside every rostered group, and FINA is not in the roster (`config/regions/*.yml`). Finding 4 |
| "`net_ha` is −2 ha, `net_footprint_ha` is +54 ha … that outside strip is strongly net-positive (67 ha of gain against 11 ha of loss) while the inside is not" | `:146` | **correct** — −2.3 / +54.1; outside gain 67.1 ha, outside loss 10.8 ha; inside 225.4 gain / 227.7 loss |
| coverage table: "Every figure in this table is the item's own watershed group … the column totals are real sums and count no ground twice" | `:179` | **correct of a post-v2.1.0 render, false of the committed cache** — `data/readme_items.rds` holds v2.0.1 footprint values (WILL `floodplain_ff04_km2` 351, build 342.50) and nothing mechanical refuses that render. Finding 8 |

### `NEWS.md` (16)

| claim | where | measured verdict |
|---|---|---|
| "**All 23 items republish, every asset**" | `:32` | **overstated** — the 3 `style_*` assets per item are byte-identical to live on 23/23 (`file:checksum` unchanged), i.e. 69 of the 246 published assets, which `aws s3 sync` will skip |
| "split **every** vector layer in both source bundles along the watershed group polygon and flagged each piece `in_wsg`" | `:33` | **WRONG** — 246 of the 468 data layers in those bundles carry `in_wsg`; **222 do not** (the retired `bt`/`ch`/`co` layers). `CLAUDE.md:174-177` says this explicitly: "the quantifier is about the staged set, not about the files". Finding 7 |
| `all_ff04` is two features / `*_by_blue_line_key` one row per (key, side) / each `classified_*` one per (class, side) | `:34-36` | **correct** — 0 violations across 23 items / 85 classified layers |
| `composition_*` gains `in_wsg` and `in_open_water` | `:39` | **correct** — both columns present on 23/23, and both overlays are *new* in provenance (pre-split backup diff) |
| "`patch_watercourse_*`'s key becomes (`name_basin`, `patch_id`, `in_wsg`)" | `:40` | **WRONG** — not a key (BOWR 7,183 rows vs 2,370 such triples; BULK 29,986 vs 9,275), and `in_wsg` adds **0** distinct combinations to `(name_basin, patch_id)` on all 23 items and in both tables. Finding 5 |
| "Every headline figure is now published in two scopes" + the six names | `:42-45` | **correct** |
| "the `in_wsg` change figures are exactly what was already live — BULK reproduces 2793.4 / 1318.7 / −1474.6 ha" | `:52-54` | **correct, and now measured on all 23** against the live API: `gross_loss_ha`/`gross_gain_ha`/`net_ha` equal live on **23 of 23**, zero mismatches |
| "PCEA's transition patches sum 754.4 ha inside its group and 2,454.6 ha unclipped, which is 3.3x" | `:56-58` | **correct** — 754.4 / 2454.6 = 3.254 |
| "tree loss, 227.7 -> 238.5 ha (+4.7%), and tree gain, 225.4 -> 292.5 ha (+29.8%)" | `:58-60` | **correct** — +4.74% and +29.77% |
| NEWS table: PCEA 843.34→491.38 41.7%, LCHL 3.3%, TABR 3.2%, MCGR 3.0%, "18 more between 0.8% and 2.6%", UNTH 0.8% | `:64-71` | **correct** — the 18 unnamed span 0.83%–2.65% (0.8%–2.6% to 1 dp), UNTH 0.81%, and the four named round as printed |
| "`net_ha` is **-2.3 ha** … `net_footprint_ha` is **+54.1 ha**" | `:76-78` | **correct** |
| "**`geometry`, `bbox` and `proj:bbox` are unchanged**" | `:82` | **WRONG for `geometry`** — 0 of 23 geometries are byte-identical to live; every one gains coordinates, +8 (DUNC) to +364 (FRAN). `bbox` and `proj:bbox` are unchanged on 23/23. `CLAUDE.md:83-98` and `01_stage.R:1006-1013` say the opposite of this line. Finding 6 |
| "**Both scopes are tagged into every COG**, which is why every raster's `file:checksum` moves even though no raster was re-derived" | `:85` | **correct** — every GeoTIFF asset's checksum differs from live on 23/23 (0 unchanged), while the 3 style assets are unchanged |
| "The collection description and all three GeoPackage asset descriptions say all of this" | `:98-100` | **overstated** — `floodplain.gpkg`'s description says nothing about any-touch flags, the `composition_*` route, or summing the unsuffixed figures; the collection description does not say `open_water_poly_id` is an identifier rather than a flag |
| "23 of 23 at this release … `test_pipeline.R` now also requires `in_wsg` on every staged data layer (all 246 whole-network layers over the 23 groups carry it)" | `:106-110` | **correct** — `check_metric_scopes(data/stac, census=True)` → straddle 23/23/23/23/23, seen 23; 246/246 upstream |
| "Provenance did not move: `run.datetime_utc` is unchanged upstream, so `processing:datetime` is too. **Only** `transition_patches` and its `outputs_hash` moved there" | `:112-114` | **WRONG on both halves** — `dunc_all_ff04`'s `processing:datetime` moves from live `2026-10-15T18:49:33Z` to `2026-10-18T22:37:59Z` (its landcover `run.datetime_utc` moved upstream after the backfill snapshot); and the pre-split diff shows **7 changed values and 8 added keys** per group, 6 of the 7 in the `composition` sub-record (`inputs_hash`, `outputs.rows` 535→858, `outputs.table_content_sha256`, `outputs_hash`, `composition.run.datetime_utc`) plus the two new `overlays`. Finding 9 |

### `CLAUDE.md` (15)

| claim | where | measured verdict |
|---|---|---|
| "**Six** staged-side readers exclude `layer_styles` BY NAME", enumerated | `:69-78` | **correct, and no seventh** — `04_gpkg_style.py:211`, `item_validate.py:1036` (new), `item_validate.py:1986`, `style_reach-check.py:162`, `gpkg_determinism-check.R:132`, `test_pipeline.R:441` |
| "`layer_styles` is one of its three `attributes` rows" | `:73-75` | **correct** — `composition_*`, `layer_styles`, `patch_watercourse_*` |
| "`check_gpkg_columns` … reads the `('features','attributes')` pair and so would otherwise pick the style table up" | `:71-73` | **correct** — `layer_styles` is registered `attributes` in all 69 published GeoPackages |
| "`all_ff04` is **two** features, `*_by_blue_line_key` one row per (key, side), each `classified_*` one per (class, side)" | `:167-169` | **correct** |
| "The `wsg`/`species`/`scenario` key is the item's own on **both** sides" | `:169-171` | **correct** — `DISTINCT wsg, species, scenario` is exactly 1 row on all 269 layers |
| "all **246** whole-network layers over the 23 rostered groups carry it, and the 222 that do not are the retired per-species layers" | `:173-176` | **correct** — 246 with / 222 without, and every one of the 222 is a `bt`/`ch`/`co` layer |
| "`composition_*` carries `in_wsg` + `in_open_water`" | `:181-182` | **correct** |
| "`patch_watercourse_*`'s key is now (`name_basin`, `patch_id`, `in_wsg`)" | `:183` | **WRONG** — see the NEWS row. Finding 5 |
| "`in_open_water` is **any-touch** … so an AREA by it comes from `composition_*` (cell centre)" | `:183-186` | **correct** — `composition_*` carries `in_open_water` and provenance records `membership: cell_centre` |
| "BULK 5584.9 against 4112.1" (the round-2 correction) | `:190-192` | **correct** — `SUM(area_ha) WHERE in_wsg=1` is 5,584.9 on BULK; `gross_loss_ha + gross_gain_ha` is 4,112.1 |
| "scoping loss/gain/net to `in_wsg` HELD every published value (BULK 2793.4 / 1318.7 / −1474.6, reproduced exactly)" | `:410-414` | **correct — now on all 23** against live |
| "a pair's difference is ground a neighbouring group's own item also publishes (floodplains#60)" | `:413-415` | **WRONG** — see the collection row. Finding 4 |
| "BULK 659.99 → 646.81; PCEA 843.34 → 491.38, 41.7% of its floodplain lying in Williston's PARS and FINA arms" | `:416-418` | **figures correct; "PARS and FINA" wrong** — PARS holds ≤0.4% of PCEA's outside piece. Finding 4 |
| "**every** item's geometry gains coordinates — 8 (DUNC) to 364 (FRAN), 0.00% to 0.13%, BULK 433,852 -> 434,116 — and **no** item's geometry is byte-identical … `bbox` and `proj:bbox` unchanged on all 23, and every `*_footprint_km2` equals the live item's unsuffixed area exactly" | `:85-90` | **correct in every part** — reproduced exactly against the live API: min +8 (DUNC, 167,098→167,106), max +364 (FRAN, 449,474→449,838), range 0.0048%–0.1312%, BULK 433,852→434,116, 0 of 23 byte-identical, bbox and `proj:bbox` 0 of 23 moved, footprint == live area 23 of 23 |
| "BULK … area 659.991642 -> 659.991640 km2 and a symmetric difference of **11.9 m2**, which is 1.8e-08 of the footprint, and a **Hausdorff distance of 0.0099 m**" | `:89-92` | **not reproduced** — an independent run over the live and built BULK geometries (GeoJSON → `sf`, `st_make_valid` both sides, `st_transform` 3005) gives area **659.991600 km² on both sides**, symmetric difference **0.01 m² (1.91e-11 of the footprint)** and Hausdorff **0.0000 m**. The claim's *direction* holds and is in fact stronger than stated (the ground does not move; the residual is numerical), but the two numbers are three orders of magnitude apart from mine and the claim records **no CRS and no method**, so it cannot be checked as written. Finding 10 |
| "Measured 23/23 on all five at v2.1.0" (`METRIC_SCOPE_CENSUS`) | `:424-426` | **correct** |

### `scripts/README.md` (4)

| claim | where | measured verdict |
|---|---|---|
| "Each of them, and each of the three `floodplain_ff0N_km2` areas, is computed **twice**" | `:264-268` | **correct** — `01_stage.R` writes 12 figures; 12 published on 23/23 |
| "`in_wsg_flag()` refuses an absent column and refuses an NA" | `:267-270` | **correct** (understated — it also refuses zero rows, a value outside {0,1,TRUE,FALSE}, and a cast that yields NA) |
| "BULK 659.99 → 646.81 km²; PCEA 843.34 → 491.38" | `:275-277` | **correct** |
| "the fourth, `METRIC_SCOPE_CENSUS`, is the only one that can catch an `in_wsg` filter **dropped** in staging, because two identical scopes satisfy the other three" | `:280-284` | **correct as written** — and note what it does not say: a *mis-polarised* filter satisfies all four. Finding 1 |

### Code comments stating a measurement or a count (11)

| claim | where | measured verdict |
|---|---|---|
| "measured on BULK: the 9,210 in_wsg rows and their 5,584.9 ha are the published layer exactly" | `01_stage.R:233-236` | **correct** — BULK `transition` has 9,210 `in_wsg=1` rows summing 5,584.9 ha; the backup's pre-split provenance records `transition_patches: 9210` |
| "measured on BULK: 659.99 -> 646.81; on PCEA 843.34 -> 491.38, 41.7% … in Williston's PARS and FINA arms" | `01_stage.R:727-731` | **figures correct; PARS attribution wrong** (Finding 4) |
| "rounding first published -1474.7 where the live item serves -1474.6" | `01_stage.R:252-256` | **correct** — live `net_ha` is −1474.6 and the build reproduces it |
| geometry comment: "BULK 433,852 -> 434,116; +8 to +364 … `bbox` unchanged on all 23 … 11.9 m2 out of 660 km2 … Hausdorff 1 cm" | `01_stage.R:1006-1013` | **correct on every part measured** (coords, range, bbox); the sym-diff/Hausdorff pair is the unmeasurable row above |
| "(PCEA is 491.38 of 843.34 km2; most groups are within 1-3%)" | `01_stage.R:1096-1099` | **correct** — 16 of 23 (70%) in [1,3]% |
| "byte-inert on the fields above (seventeen when measured, 23 since #98 added the six footprint figures)" | `01_stage.R:900-903` | **correct** — `test_pipeline.R`'s `meta_core` is 23 entries and matches `meta`'s non-provenance keys |
| "Measured on the floodplains#144 tree, 2026-10-19: all 23 rostered groups straddle on all five" | `item_validate.py:869-872` | **correct** |
| "A published claim about **23 items x 13 layers**" | `item_validate.py:969` | **WRONG** — no item has 13 data layers: 19 items have 11 and 4 have 15, 269 in total (23 × 13 = 299). Harmless as a comment, but it is the count the guard's scope is justified by |
| "`layer_styles` … one of its three `attributes` rows" (new sixth-reader note) | `item_validate.py:974-980` | **correct** |
| "Measured 2026-10-19, before v2.1.0: 0 of the 23 live items carry one [`*_footprint_*` key]" | `only_preflight.py:152-154` | **correct — now measured** — 0 of 23 live items carry any of the six, so `metric_drift`'s window is open on every item and expires on this release exactly as documented |
| "02_raster_tag.py writes the shared fields UNPREFIXED, so a shared tag … is invisible at runtime" | `prov_fields-check.py:349-356` | **correct** — `SHARED_FIELDS` == `SHARED_TAG_PROPERTIES` (16 names) and the static pin fires on a drop (reproduced in round 1) |

### Round 1 and round 2's own fixes — re-verified

| fix | verdict |
|---|---|
| R1-1 / R2 `metric_drift` window | **sound and now measured on the live catalogue**: 0 of 23 live items carry a footprint key, so the arm is live today and goes quiet on release |
| R1-2 / R2-1 `README.Rmd` PCEA sentence | **the quantities are now right** (−2.3/+54.1, 67 vs 11 ha); the *attribution* (`PARS` and `FINA`) is the part still wrong — Finding 4 |
| R1-3 `gpkg_required_columns()` | **sound and exact** — 0 missing columns over 269 layers; `startswith("transition")` matches exactly the 46 patch layers and nothing else |
| R1-4 `01_stage.R` `st_union` comment | **sound, and now independently confirmed** (0 of 23 byte-identical; +8..+364) — but `NEWS.md:82` was not brought along (Finding 6) |
| R1-5 `str(v)` sort | sound |
| R1-6 net-tolerance static pin | sound; `_tp_tols == ['0.15','0.15']` |
| R2-2 transition_vector description | **sound** — the filtered sums reproduce `gross_loss_ha`/`gross_gain_ha` exactly on BULK and PCEA |
| R2-3 `in_wsg_flag()` cast arm | sound — all four refusals and both valid spellings behave as documented |
| R2-4 `missing_footprint()` message | sound |
| R2-+ "both new flags are any-touch" in NEWS/CLAUDE | **fixed in those two, still present in the published landcover description** (Finding 2) |

---

## New findings

- **[fragile]** `scripts/item_validate.py:838-927` (`check_metric_scopes`) — **an inverted
  `in_wsg` filter passes all four arms, including the straddle census.** The census is
  documented as the arm that catches "a dropped `in_wsg` filter"; the adjacent mutation is a
  filter applied with the wrong polarity (an upstream flag inversion, or a `!inw` / `inw == 0`
  slip in `01_stage.R`'s `tot(is_loss & inw)` / `km2(inw)`), and it *raises* the straddle count
  rather than zeroing it. Probed end to end on a synthetic tree built from the real build
  (scratchpad copies; `data/stac` untouched): with each unsuffixed figure replaced by its
  outside complement, `check_metric_scopes(T, census=True)` returns **no problems** with
  `straddle` 23/23 on all five, while `bulk_all_ff04` would publish
  `floodplain_ff04_km2 = 13.18` (live and footprint 659.99), `gross_loss_ha = 28.4` and
  `net_ha = +15.5` — a **sign flip** on the headline change figure, on all 23 items at once.
  Arm 1 passes (present and numeric), arm 2 passes (`in_wsg <= footprint`), arm 3 passes
  (`gain − loss == net` holds in the complement too), arm 4 passes (the complement is still
  strictly below the footprint). `test_pipeline.R`'s `floodplain_ff04_km2 > 0` also passes on
  13.18, and it is not in the release path. `only_preflight.metric_drift` would catch it — but
  only under `--only`, and a full release makes **no** build-against-live value comparison at
  all: the pre-sync comparison is about item *presence*. So the continuity this release rests on
  ("the `in_wsg` change figures reproduce every published value", measured by hand into
  `findings.md`) is asserted by nothing in the gate.
  Two cheap closures, either of which the measured data supports: a lower bound in
  `METRIC_SCOPE_PAIRS`' arm (min measured `in_wsg/footprint` is **0.581** on the areas, 0.771 on
  gain, 0.920 on loss, so "at least half its footprint sibling" is satisfied by 23/23 and
  refuses the inverted build on all 23), or extend the `--only` preflight's value comparison to
  the full release (every item against its live twin), which is the stronger arm and is the one
  thing that would have made the hand measurement mechanical.

- **[bug]** `scripts/item_create.py:434` — the **published** `floodplain_landcover.gpkg` asset
  description, on all 23 items: *"The transition patches also carry `in_open_water` and
  `open_water_poly_id`; **both flags are any-touch**, so areas by flag come from the
  `composition_*` table."* `open_water_poly_id` is an identifier, not a flag, and "any-touch" is
  meaningless for it; `composition_*` carries **no `open_water_poly_id` column** (measured on
  all 23: `cells, from_class, from_code, ha, in_alr, in_floodplain, in_open_water, in_wetland,
  in_wsg, scenario, species, status, to_class, to_code, wsg`), so the instruction cannot be
  followed for one of the two columns it names. This is the exact sentence round 2 corrected in
  `NEWS.md`, `CLAUDE.md` and the `transition_vector` description (*"`open_water_poly_id` is an
  identifier rather than a flag"*, `CLAUDE.md:186-187`); the published copy was not brought
  along. Fix: "`in_open_water` is an any-touch flag, so areas by it come from `composition_*`;
  `open_water_poly_id` is an identifier, not a flag."

- **[bug]** `scripts/item_create.py:487-491` — the **published** `transition_vector.gpkg`
  description, on all 23 items: *"alongside the producer's existing `in_fire` / `in_harvest` /
  `in_wetland` / `in_alr` context lookups. **Those are any-touch, so read areas by one of them
  from `composition_*`** in floodplain_landcover.gpkg rather than summing `area_ha` over it."*
  `composition_*` has no `in_fire` and no `in_harvest` column (measured on all 23), so for half
  the columns the sentence names there is no area table to read — the consumer is sent to a file
  the item itself publishes, which disproves the instruction with one `PRAGMA table_info`. The
  columns that *are* there are `in_open_water`, `in_wetland`, `in_alr` and `in_floodplain`. Fix:
  name the ones `composition_*` actually carries, and say that fire/harvest areas are not
  available that way.

- **[bug]** `scripts/item_create.py:757` (PUBLISHED collection description),
  `scripts/item_create.py:526`, `README.Rmd:146`, `NEWS.md:47`, `CLAUDE.md:413-415`,
  `scripts/readme_functions.R:418` — six copies of *"the difference between a pair is ground
  shared with a neighbour, **which that neighbour's own item also publishes**"*, and the
  inference drawn from it (*"so summing the footprint figures across groups double-counts"*).
  Measured: intersecting each item's `in_wsg = 0` `all_ff04` piece with the union of the other 22
  rostered groups' own polygons (`$FLOODPLAINS_DATA/<wsg>/subbasins.gpkg`), over all 23 items —
  total outside-own-group **519.16 km²**, of which **91.69 km² (17.7%)** lies inside another
  rostered group and **427.47 km² (82.3%)** lies in a watershed group this catalogue does not
  publish at all. Tightened to the claim's own terms — intersecting each outside piece with the
  union of the other 22 items' **published `in_wsg` floodplains** — only **50.58 km² (9.7%)** is
  ground another item actually publishes, and **468.57 km² (90.3%)** is published by nobody; per
  item the covered share runs 0.4% (PCEA) to 89.0% (DUNC), and is under 50% on 19 of 23.
  The roster is 23 of BC's watershed groups (`config/regions/*.yml`:
  KOTL LARL SLOC DUNC / LCHL LSAL WILL TABR UFRA NECR MORK FRAN BOWR MCGR THOM LNTH UNTH /
  PCEA PARS PINE / BULK MORR KISP) and **FINA is not in it** — so PCEA, the case all six copies
  use as the illustration, is **99.6% outside the roster** (350.69 of 351.97 km²), with PARS
  accounting for at most 1.28 km². Per item the outside-the-roster share runs 4.7% (WILL) to
  99.6% (PCEA); 13 of 23 are above 50%.
  Two consequences, both for a consumer: the stated reason to prefer the unsuffixed sum is
  overstated by about 10x (double counting is 50.58 km², **0.48%** of the 10,611.35 km² footprint
  sum), and the thing that is actually true — the unsuffixed sum **omits 468.57 km² of modelled
  floodplain that no item then claims** — is said nowhere. The *other* half of the sentence does
  hold, and now has a positive measurement: the union of the 23 `in_wsg` pieces is 10,092.24 km²
  against the published sum of 10,092.27, so the unsuffixed figures really are a partition across
  items. Fix: say the difference is ground outside the item's own group, that a tenth of it falls
  in a neighbouring published group (and is then published twice), and that the rest falls in
  groups this catalogue does not publish.

- **[bug]** `CLAUDE.md:183` and `NEWS.md:40` — *"`patch_watercourse_*`'s key is now
  (`name_basin`, `patch_id`, `in_wsg`)"*. It is not a key, and `in_wsg` is not part of one.
  Measured on all 23 published `patch_watercourse_*` layers: rows far exceed distinct
  `(name_basin, patch_id, in_wsg)` triples (BOWR 7,183 vs 2,370; BULK 29,986 vs 9,275;
  PARS 46,925 vs 9,300), while `(name_basin, patch_id, in_wsg, blue_line_key)` equals the row
  count **exactly on all 23** — `blue_line_key` is the missing member. And `in_wsg` contributes
  nothing: `COUNT(DISTINCT name_basin, patch_id)` equals `COUNT(DISTINCT name_basin, patch_id,
  in_wsg)` on all 23 items (sum of the differences: **0**), in the `transition` layer too, because
  `name_basin` is NULL on exactly the `in_wsg = 0` rows (verified on all 23). So the sentence
  asserts a change the data does not show, in a claim about a *published* table's identity. The
  wording is carried verbatim from the upstream issue body (`findings.md`, "What changed
  upstream"), and round 2 checked that the three columns are *present* — presence for the
  property. Fix: either state the real row key (`name_basin`, `patch_id`, `blue_line_key`) or
  drop the claim; if upstream means "a patch is identified by `(name_basin, patch_id)`", say
  that, without `in_wsg`.

- **[bug]** `NEWS.md:82` — *"**`geometry`, `bbox` and `proj:bbox` are unchanged**"*. Measured
  against the live API on all 23 items: `bbox` and `proj:bbox` are unchanged on 23/23, and
  **0 of 23 geometries are byte-identical** — every one gains coordinates, +8 (DUNC) to +364
  (FRAN), 0.0048%–0.1312%. This is round 1's finding 4 in a third copy: `CLAUDE.md:83-98` leads
  with "**`geometry` does move, though, and not only in the last digit**" and `01_stage.R:1006`
  with "The split DOES move these bytes, which the first version of this comment got wrong", and
  the release note — the only one of the three a consumer reads — still carries the disproved
  version. It also removes the one instruction the measurement exists to give ("expect a geometry
  diff on this release and do not assert byte or vertex equality on it"). Fix: say the ground is
  unchanged (`bbox`, `proj:bbox`, area within 1.8e-08) and the geometry bytes are not.

- **[fragile]** `NEWS.md:33` — *"split **every** vector layer in both source bundles along the
  watershed group polygon and flagged each piece `in_wsg`"*. Measured over the 23 rostered
  groups' `floodplain.gpkg` + `floodplain_landcover.gpkg`: 246 of 468 data layers carry
  `in_wsg`; the other **222** do not, and every one is a retired `bt`/`ch`/`co` layer. The
  branch's own `CLAUDE.md:176-177` states the rule this breaks — "so the quantifier is about the
  staged set, not about the files". Harmless to the build (those layers are never staged), but it
  is the same quantifier error the other file was careful to avoid, in the public copy. Fix:
  "every whole-network vector layer", or "every layer this catalogue stages".

- **[fragile]** `README.Rmd:179` + `data/readme_items.rds` — the new sentence *"Every figure in
  this table is the item's own watershed group … the column totals are real sums and count no
  ground twice"* is false of the only render that is reachable today. The committed cache holds
  v2.0.1 properties (WILL `floodplain_ff04_km2` 351 against the build's 342.50; the ff04 total is
  10,611 km², the footprint sum), `params$rmd_on` and `update_query` both default to not reading
  the API, and nothing refuses that combination: `fp_req()` deliberately does not require the
  `*_footprint_*` keys (plan review G4), on the grounds that requiring them would hard-stop the
  `update_query = FALSE` render — which is precisely the render that is wrong. Today the risk is
  contained only by the instruction in `task_plan.md` not to render, and by `README.md` being
  untouched in this PR, so nothing false ships from the merge; the exposure is release step 6 and
  any interim knit. A one-line guard closes it: refuse (or fall back to the old prose) when the
  rows carry no `*_footprint_*` key, i.e. when the cache predates v2.1.0.

- **[fragile]** `NEWS.md:112-114` — *"Provenance did not move: `run.datetime_utc` is unchanged
  upstream, so `processing:datetime` is too. **Only** `transition_patches` and its
  `outputs_hash` moved there, under a `wsg_split` repair record, and nothing here reads either."*
  Both halves are wrong, measured. (a) `dunc_all_ff04`'s `processing:datetime` is
  `2026-10-15T18:49:33Z` live and `2026-10-18T22:37:59Z` in the build — DUNC's landcover
  `run.datetime_utc` moved upstream after the backfill snapshot (the backup's
  `dunc_after_backfill/provenance.json` still carries the live value), so this release *does*
  move a published provenance property, on 1 of 23 items, for a reason unrelated to #98. (b) The
  pre-split diff (`data/backup/20261018_wsg_split/<wsg>/provenance.json` against the current
  tree, all 23 groups) shows **7 changed values and 8 added keys** per group, not two: six of the
  seven are in the `composition` sub-record (`inputs_hash`, `outputs.rows` 535→858 on BULK,
  `outputs.table_content_sha256`, `outputs_hash`, and `composition.run.datetime_utc`
  2026-10-14→2026-10-18), plus the new `inputs.overlays.wsg` and `inputs.overlays.open_water`.
  The *safety* claim survives — nothing in this repo reads `composition.*`, `transition_patches`,
  `outputs_hash` or `run.repairs` (grepped), and `fp_provenance.R:69,581` read the landcover
  section's own `run$datetime_utc` — and the two literals are unaffected (presence, not value).
  But "provenance did not move" is what justified not re-taking them, and the release note should
  name DUNC's stamp, since it is a published value changing in this release.

- **[fragile]** `CLAUDE.md:89-92` (and the same pair in `01_stage.R:1011-1012`,
  `findings.md`) — **the BULK geometry residual does not reproduce, and the claim names no CRS.**
  Stated: area `659.991642 -> 659.991640 km2`, symmetric difference `11.9 m2` = `1.8e-08` of the
  footprint, Hausdorff `0.0099 m`. Measured independently on the live and built BULK geometries
  (each item's `geometry` written out as GeoJSON, read with `sf`, `st_make_valid()` on both
  sides, `st_transform(3005)`): area **659.991600 km² on both sides**, symmetric difference
  **0.000000013 km² = 0.01 m²**, i.e. **1.91e-11** of the footprint, and Hausdorff **0.0000 m**.
  The conclusion the numbers support is unaffected and is strengthened — the footprint is the
  same locus with a denser boundary and the residual is numerical, which is why the right things
  to pin are the bbox and the area (both now confirmed on 23/23). But a stated measurement that
  records neither the CRS it was taken in nor whether the geometries were validated first cannot
  be re-derived, and this is the one number in the branch that a second attempt disagrees with by
  three orders of magnitude. Either re-take it with the CRS written down, or drop the two figures
  and keep the sentence ("the ground does not move: bbox unchanged on all 23, area equal to
  within rounding"), which is the part every measurement agrees on. Note the possible
  methodological causes rather than asserting which side is right: a different CRS (the items are
  UTM — BULK's `proj:bbox` is a UTM grid, not BC Albers), and `st_make_valid()` on both sides,
  which rewrites geometry that was already valid (`code-check-spatial.md`) and could absorb
  slivers my run would otherwise have counted.

---

### Checked and clean (probed, not reasoned about)

- `check_gpkg_columns`'s vacuity arms: `compared == 0` over a tree with no GeoPackages fires; the
  `absent`/`continue` flow reaches the value arm for a layer missing only a context column;
  `vals <= {0, 1}` accepts REAL `0.0`/`1.0` (same hash) and refuses `'true'`.
- `in_wsg_flag()`: all four refusals reproduce; `as.character()` of integer/double/logical
  spellings maps onto the four accepted strings and nothing else.
- `METRIC_PROPERTIES` / `SHARED_TAG_PROPERTIES` / `SHARED_FIELDS` / `only_preflight.METRIC_PROPERTIES`
  are four copies of the same 12 and 16 names, all joined by `prov_fields-check.py`'s static arms.
- `assert_straddle = args.expect_provenance is not None and not args.partial` is exactly the
  release-time full build (`catalogue_release.sh:772` passes `--partial` under `--only`, `:774`
  passes `--expect-provenance` otherwise, `run_pipeline.sh:74` passes neither).
- Rounding is monotonic, so `in_wsg <= footprint` cannot invert under independent `round(x, 1)`;
  the net tolerance of 0.15 bounds three half-steps.
- The published `in_wsg` is a true partition: `DISTINCT in_wsg` is `(0, 1)` with no NULL on all
  269 data layers of all 69 published GeoPackages.
- Nothing else in the published documents moves: a full property diff build-against-live over 23
  items shows only the 9 new/rescoped metric properties (23/23) and DUNC's `processing:datetime`
  (1/23). `gross_loss_ha`, `gross_gain_ha` and `net_ha` appear nowhere in that diff.
