# Findings — Publish in_wsg and in_open_water (#98)

## Measured before planning (2026-10-19, UTC)

Upstream tree: `../floodplains` at `2fe7a74`, floodplains#144 merged (`0e4cbf9`).
Backfill log: `floodplains/scripts/floodplain_lcc/logs/20261018_wsg_split_backfill.md`.

### The split is on disk, and the item key is uniform across it

`bulk/floodplain.gpkg`:

```
all_ff02  2 features   in_wsg=1: 598.5193 km2   in_wsg=0: 12.3881 km2
all_ff04  2 features   in_wsg=1: 646.81   km2   in_wsg=0: 13.1816 km2
all_ff06  2 features   in_wsg=1: 685.146  km2   in_wsg=0: 13.7913 km2
all_ff04_by_blue_line_key  2454 features, in_wsg present
```

`wsg`/`species`/`scenario` are `BULK`/`all`/`all_ff04` on **both** sides of the split, on the
scenario layer and on the transition layer. So `fp_gpkg.R:156-166`'s `nrow(k) != 1L` arm and
`01_stage.R:312-330`'s key refusals all still pass — **nothing refuses, the change is silent.**

New columns confirmed present:

| layer | new columns |
|---|---|
| `all_ff0N`, `all_ff04_by_blue_line_key`, `classified_*` | `in_wsg` |
| `transition_*` | `in_wsg`, `in_open_water`, `open_water_poly_id` |
| `composition_*` | `in_wsg`, `in_open_water` |
| `patch_watercourse_*` | `in_wsg` |

### The two headline-metric populations move in opposite directions

`transition_all_ff04_2017_2023`, BULK: `in_wsg=1` is 9,210 rows / 5,584.9 ha, `in_wsg=0` is 76
rows / 82.1 ha. The upstream log's "(was)" column is 9210 / 5,584.9 — so **the inside rows are
exactly the layer that was published**, and scoping loss/gain/net to `in_wsg` holds today's
published values. `name_basin` is NULL on all 76 outside rows and on none of the inside rows.

`floodplain_ffNN_km2` is the opposite: the delineation layer was **never** clipped, so today's
published value is the whole footprint. Measured per group, `all_ff04`, `in_wsg` / total km²
and `gross_loss_ha` `in_wsg` / total:

```
bowr  379.66 / 389.99     586.5 / 609.1
bulk  646.81 / 659.99    2793.4 / 2821.8
dunc  183.17 / 185.21     116.9 / 122.2
fran 1084.07 / 1096.31  10139.8 / 10323.6
kisp  321.14 / 324.4      350.5 / 355.5
kotl  744.90 / 754.14     643.1 / 658.4
larl  372.07 / 375.51     379.4 / 380.9
lchl  412.92 / 426.81    1526.4 / 1631.9
lnth  379.47 / 388.56     746.5 / 762.4
lsal  284.73 / 290.88    1003.9 / 1038.1
mcgr  344.61 / 355.33     776.7 / 818.1
mork  655.52 / 667.04    1063.0 / 1086.8
morr  473.37 / 479.32     659.5 / 684.7
necr  749.44 / 759.59    4463.8 / 4598.4
pars  553.11 / 559.44    1753.0 / 1775.1
pcea  491.38 / 843.34     227.7 / 238.5
pine  479.00 / 488.87    1033.0 / 1081.8
sloc  153.21 / 154.49     119.7 / 123.0
tabr  258.73 / 267.19     634.6 / 659.3
thom  251.43 / 257.04    1169.1 / 1247.9
ufra  298.00 / 301.73     827.2 / 840.0
unth  233.03 / 234.93     672.9 / 678.6
will  342.50 / 351.24     679.3 / 738.2
```

Every total above equals the item's live `floodplain_ff04_km2` / `gross_loss_ha`? **No** — only
the floodplain column does. BULK live `floodplain_ff04_km2` is 659.99 (= total) while live
`gross_loss_ha` is 2793.4 (= `in_wsg`). That asymmetry is the whole point of the issue, and it is
why the two metric families need opposite handling.

PCEA is the outlier the issue names: 41.7% of its floodplain is outside the group, in Williston's
PARS and FINA arms, and 1,700.3 ha of its change against 754.4 ha inside.

### Provenance moved only where the issue says

`bulk/provenance.json`, section `landcover.all_ff04`:

- `outputs.transition_patches` 9210 → 9286, `outputs_hash` moved.
- `run.repairs[0]` records `kind: wsg_split`, `issue: 53`, `previous_outputs.transition_patches:
  9210`, `repaired_utc: 2026-10-18T20:55:31Z`.
- `run.datetime_utc` unchanged at `2026-10-14T13:33:49Z` — so `processing:datetime`
  (`nge:produced_datetime`) does not move, and `fp_prov_rasters_current()`'s mtime arm still has
  its reference.
- `composition.inputs.overlays.wsg` added; `overlays.open_water` names
  `whse_basemapping.fwa_lakes_poly` + `fwa_manmade_waterbodies_poly`.

**Nothing in this repo reads `transition_patches`, `outputs_hash` or `run.repairs`**, and
`fp_provenance.R:165-173`'s unknown-key refusal is at the document root only, so the new
section-level siblings are inert. `schema_version` is still 2.

## Why there is no "property description" to write

Item properties in `item_create.py:479-503` are a bare `dict` — no per-property description,
no `item_assets`, no property metadata block. So the issue's "state that in the property
description" has to land in the collection `description` and the GeoPackage asset descriptions.
`item_validate.check_citation_premise` tests `EXPECTED_DERIVATION_STATEMENT` by **containment**,
so appending sentences is safe; rewording the existing text is not.

## The coupling that decides the COG re-upload

`02_raster_tag.py:69-73` `SHARED_FIELDS` writes the six metrics into every COG as
`NGE_<FIELD>`, and `item_validate.py:461-465` `SHARED_TAG_PROPERTIES` is its absolute twin
(`check_cog_tags`, `:916-922`). Changing a metric's **value** therefore rewrites every COG's
bytes and so every published `file:checksum`. Measured bucket composition:

```
tif   108    154.6 MB
gpkg   69   1179.2 MB
other  93    257.1 MB      total 270 objects / 1.5 GiB
```

The GeoPackages change regardless (the split), so the COG rewrite adds ~155 MB to a sync that
was always going to be ~1.3 GB. That makes adding the six sibling tags free, and
`flood_factor` is the standing precedent for a published property with no tag if we had wanted
to avoid it.

`prov_fields-check.py:97-101` pins a static `SHARED` fixture against all three copies, so the
six names have to land in four places at once.

## Errors Encountered

| Error | Resolution |
|-------|------------|

## Issue context

## What changes if we do it

Published items say which of their ground is inside their own watershed group (`in_wsg`) and which is open water (`in_open_water`). A regional total becomes a sum over `in_wsg`, and the double count between neighbouring items is a query a consumer can run.

## What happens if we never do

The gpkg assets already carry the new columns once they are restaged, but the item schema does not describe them. The headline metrics also switch silently from clipped to whole-footprint figures: PCEA's gross change would roughly triple, because most of the change in that item lies in Williston's arms in PARA and FINA.

## What changed upstream

floodplains NewGraphEnvironment/floodplains#53 and NewGraphEnvironment/floodplains#138, in NewGraphEnvironment/floodplains#144. The outputs of all 23 region groups were backfilled on 2026-10-18 (log `scripts/floodplain_lcc/logs/20261018_wsg_split_backfill.md`).

- **Every vector layer is split along the group polygon.** Each piece carries `in_wsg` (logical; TRUE inside the item's own group):
  - `<wsg>_all_ffNN` is now **two rows** (inside and outside), not one. Both stay MULTIPOLYGON.
  - `all_ff04_by_blue_line_key` has one row per (key, side).
  - Each `classified_*` layer has one row per (class, side).
- **`transition_*` change patches are no longer clipped to the group.** The outside pieces are new rows with `name_basin` NA. Inside rows are byte-identical to what was published (WKB, `patch_id`, `area_ha`). `transition_patches` in provenance now counts pieces (rows).
- **New context columns on the patches:** `in_open_water` (logical) and `open_water_poly_id`. They come from FWA `fwa_lakes_poly` + `fwa_manmade_waterbodies_poly`, with no size cut-off. Lakes and reservoirs share one flag because FWA files a dammed lake as a lake. Like `in_wetland`, the flag is any-touch, so areas are read from the composition table.
- **`composition_*` gains `in_wsg` and `in_open_water` columns,** counted by cell centre.
- **`patch_watercourse_*` gains `in_wsg`.** The patch key is now (`name_basin`, `patch_id`, `in_wsg`).
- **Provenance changes:**
  - `landcover[<scen>].outputs.transition_patches` and its `outputs_hash` moved. `run.repairs` records a `wsg_split` repair holding the previous values.
  - `run.datetime_utc` (`nge:produced_datetime`) did **not** move: no raster was rewritten.
  - The composition sibling was rebuilt and records the group polygon under `inputs.overlays.wsg`.
  - The rasters, their digests and every `inputs` field are unchanged.

## What to do here

- [ ] Item schema: describe `in_wsg`, `in_open_water` and `open_water_poly_id`.
- [ ] Headline metrics: compute gross loss/gain/net (`01_stage.R`'s patch sums) and `floodplain_ffNN_km2` over `in_wsg` rows, and state that in the property description. The whole-footprint figure can sit beside it under its own name.
- [ ] Any README or region sum in this repo that adds per-item floodplain areas: sum over `in_wsg`. Today's sums count shared ground twice (floodplains#60).
- [ ] Restage and republish every whole-network item (`run_pipeline.sh` rebuild, then `catalogue_release.sh`).
- [ ] Any reader of a scenario layer that assumes one row: union the rows, or filter to `in_wsg`.



---

## Plan review (Plan agent, spawned at scaffold, landed mid-Phase-4)

Reproduced every finding I acted on. Verdicts below; the remedies are tracked as Phase 3b in
`task_plan.md`.

### Confirmed, acted on

| # | finding | how I confirmed it |
|---|---|---|
| B1 | Phase 5's ordering destroyed the build it then measured | `01_stage.R:92-93` wipes both trees, `:196` drops `PARTIAL_STAGE`; `gpkg_determinism-check.R` and `style_determinism-check.py` both default `ITEM=sloc_all_ff04`. My actual execution order happened to be right (smoke first, then rebuild); the plan TEXT was wrong, and is rewritten |
| B2 | the straddle census is asserted on a plain rebuild | read `item_validate.py:715-718`: *"Both the census and the floor are release-time: a rebuild has no business asserting how many areas the producer has re-modelled, and `floor is None` is how the release says this is a rebuild"*. My arm used `not args.partial`, so an `ALLOW_SKIPPED=1` 22-group rebuild would fail spuriously |
| B3 | measured straddle counts never printed | confirmed: reported only on mismatch, and the success print names the literal. `PROV_CENSUS`'s own comment records the trap |
| B4 | nothing pins `02_raster_tag.SHARED_FIELDS` to `item_validate.SHARED_TAG_PROPERTIES` | confirmed, and the reason it matters: `check_cog_tags`'s `managed` set is `want | {NGE_-prefixed tags} - bridged`, so an unprefixed tag absent from the literal is in neither half and is invisible. **My own `findings.md` claim that the fixture "pins against all three copies" was wrong** — it pins against one |
| B5 | the published `in_wsg` claim is checked on one item by a script the release path never runs | `grep -n in_wsg scripts/item_validate.py` returns comments only; no `test_pipeline` reference in `run_pipeline.sh` or `catalogue_release.sh`. This is the sharpest finding: the asset descriptions now assert something about 23 items x 13 layers that the gate does not read |
| Acc1 | nothing proves `check_metric_scopes` fires | the `SHARED` fixture is deliberately built to satisfy it, and there is no breaking case. The newest guard in the release path had no restore-the-bug proof |
| G2 | `--only` is blind to the whole change | `only_preflight.py:60` filters on four prefixes and every metric is unprefixed, so a `--only` republish would print `0 lost` and leave one item redefined against 22 others, irreversibly |
| A2 | "PCEA's gross change would roughly triple" names the wrong quantity | measured: PCEA transition patch area 754.4 -> 2454.6 ha (3.3x), but published tree loss 227.7 -> 238.5 (+4.7%) and tree gain 225.4 -> 292.5 (+29.8%). The issue's phrase is about total change; I had repeated it of the published figures. Corrected in NEWS |
| A1 | the `st_union` no-change is approximate, not exact | the split/union round trip perturbs coordinates at ~1e-11 and `01_stage.R` writes `digits = 10`, which sits on that boundary. Softened in `CLAUDE.md` and moved into the Phase 5 measurement rather than asserted |
| G1 | two `7,273 km2` comment literals in `readme_functions.R` were already stale | independently computed from the per-group table: footprint sum **10,611.35**, in_wsg sum **10,092.27**, difference **519.08** km2. The committed `README.md:81` reads 10,611 - the double-counted figure |
| O1 | do not re-render the landing page in this PR | the new prose asserts the no-double-count property; the cache is v2.0.1 and would render 10,611 beside it. Regen stays at release step 6 |
| S1 | `year_sets-check.py` needs no fixture change | already measured and corrected before the review landed: it imports `check_checksums` alone |
| S2 | the containment test is in `check_collection_metadata`, not `check_citation_premise` | confirmed. The conclusion (append safe, reword not) was right; the attribution was not, which matters to anyone restoring the bug against it |

### Confirmed, deliberately not acted on

- **G3** `in_wsg_flag()` covers two layer families, not every data layer. True, and B5 is the
  fix rather than a second staging arm: a check in `item_validate.py` runs in the rebuild AND
  is the release gate, where a staging arm is neither.
- **O2** No `styles/` regeneration. Checked both paths it could have forced:
  `EXPECTED_STYLE_CATEGORIES` is 10 / 91 and the outside rows draw from the same 10-class
  vocabulary, so the coverage arm cannot find a new uncategorized value; `EXPECTED_RAT_ROWS`
  describes drift's encoding, not any item's data. Recorded as a checked non-change.
- **O3** Expect **no** `PROVENANCE_FLOOR` / `PROV_CENSUS` movement rather than re-taking
  blind: `run.datetime_utc` is untouched upstream, so `processing:datetime` cannot move. Phase 5
  now says to run the release-shaped validate and re-take only a number that moved.
- **G4** `data/readme_items.rds` carries no footprint columns, so `fp_req` must NOT start
  requiring them or the `update_query = FALSE` render becomes a hard stop. It does not.
- **Acc4** Nothing compares a published area against a bbox, geometry or raster window, so the
  scoping asymmetry is internally consistent. `proj:*` comes off the raster.
- **Acc2** `stage_years-check.R` added to Phase 5, with a note that its `PIN_META_SHA256` arm
  is expected to SKIP (the pin is `ufra_ch_ff04` and floodplains#125 moved UFRA to `all_ff04`).

### Quantifiers the review checked against the data

"Every data layer carries `in_wsg`" is TRUE for the 8 published families x 23 groups and FALSE
for the retired per-species layers still on disk upstream — which is the same split my own
246 / 222 measurement found, from the other direction. The asset descriptions scope the claim
to the item (*"every data layer"* of a file that holds only this item's layers), which is the
true reading; `CLAUDE.md` says so explicitly.

---

## Phase 5 continuity measurement (2026-10-19, build vs the live API)

Full rebuild: 23 items, exit 0, all 23 groups staged, 108 COGs, tree verified unmodified for
the whole run (five script snapshots byte-compared before and after).

Compared every one of the 23 built items against the live API item of the same id.

| question | result |
|---|---|
| `in_wsg` `gross_loss_ha` / `gross_gain_ha` / `net_ha` == live | **23 of 23 exact**, zero mismatches |
| `*_footprint_km2` == live's unsuffixed `floodplain_ffNN_km2` | **23 of 23 exact**, zero mismatches |
| item `bbox` and `proj:bbox` moved | **0 of 23** |
| geometry byte-identical to live | **0 of 23** |
| geometry coordinate count moved | **23 of 23**, +8 (DUNC) to +364 (FRAN), 0.00%-0.13% |

So the two continuity claims the whole design rests on are now measured on the catalogue, not
on one group: scoping the change figures to `in_wsg` holds every published value, and the
footprint siblings reproduce every published area.

### The geometry finding, and a review claim it disproves

The plan review reported the split/union round trip as an **identical vertex count** with a
~1e-11 perturbation, measured on BULK. That is wrong, and the reason is instructive: it
compared a union of the split pieces against **another build**, not against the live item.
Measured against live, BULK goes 433,852 -> 434,116 coordinate values (+264) and every one of
the 23 items gains some. The union keeps the nodes the cut inserted where the group boundary
crosses the floodplain outline.

The ground does not move. On BULK, against the live geometry:

```
live area             659.991642 km2
built area            659.991640 km2
symmetric difference    0.000011918 km2  = 11.9 m2 = 1.8e-08 of the footprint
hausdorff distance      0.0099 m         = no point on either boundary is >1 cm from the other
```

Plus `bbox` unchanged on all 23 and every footprint area equal to live. So: same locus,
denser boundary, residual numerical. **Nothing should assert byte or vertex equality on this
geometry** — the bbox and the area are the right things to pin, and `item_validate.py` already
compares neither against an area, which is why no guard objects.

### Proofs that the new guards fire

Not inferred from a green run — each defect restored and the arm watched:

| guard | defect restored | result |
|---|---|---|
| `prov_fields-check.py`'s new static pin | dropped `net_footprint_ha` from `02_raster_tag.SHARED_FIELDS` | `FAIL ... disagree on ['net_footprint_ha']`, 58 assertions 1 failed; file restored and byte-compared |
| `check_gpkg_columns` absent-column arm | `ALTER TABLE transition DROP COLUMN in_wsg` on a COPY of `transition_vector.gpkg` | fired, naming the layer |
| `check_gpkg_columns` value arm | `in_wsg = NULL` on `composition_*`, `in_wsg = 2` on `patch_watercourse_*` | both fired, naming the values |
| `check_metric_scopes` (4 arms) | swapped pair; net off by 5; footprint net off; two identical scopes across the tree | all four fired, each matched on its own message |
| `only_preflight.metric_drift` | a live `floodplain_ff04_km2` one higher than the build, driven through `main()` | refused, naming the figure |

The mutations on real GeoPackages were done on **copies** under the scratchpad, never on
`data/stac`. One incidental finding: a plain `sqlite3` `UPDATE` on a *spatial* layer fails with
`no such function: ST_IsEmpty`, because the GeoPackage triggers call it — so the value-arm
proof had to use an aspatial table. Same leak `code-check-spatial.md` records.

### A sixth `layer_styles`-by-name exclusion

`check_gpkg_columns` reads `data_type IN ('features','attributes')`, so it would pick up the
style table. Measured on a published `floodplain_landcover.gpkg`: `layer_styles` is one of its
**three** `attributes` rows, beside `composition_*` and `patch_watercourse_*`. Excluded by
name, and `CLAUDE.md`'s written-down count moves from five to six.

### The two scopes on the build, for the two groups that matter

```
STAGED bulk_all_ff04: ff02 598.52 (610.91) / ff04 646.81 (659.99) / ff06 685.15 (698.94) km2,
                      loss 2793.4 (2821.8) ha, gain 1318.7 (1362.6) ha, net -1474.6 (-1459.2) ha
STAGED pcea_all_ff04: ff02 488.20 (840.16) / ff04 491.38 (843.34) / ff06 494.61 (846.59) km2,
                      loss  227.7 ( 238.5) ha, gain  225.4 ( 292.5) ha, net    -2.3 (   54.1) ha
```

**PCEA's two nets disagree on the direction of change** — -2.3 ha inside its own group against
+54.1 ha over the whole footprint. That is the strongest single argument for publishing both
scopes rather than picking one, and it is also the concrete reason `net` is excluded from the
in_wsg-at-most-footprint arm: a signed difference can legitimately sit either side.

**The reason is the outside strip, not a concentration of change out there** — which is a
correction, twice over (code-check rounds 1 and 2). Measured: PCEA's outside strip carries
67.1 ha of gain against 10.8 ha of loss, so it is strongly net-positive while the inside is
roughly balanced. The *change* is actually ~4x DENSER inside (0.92 ha/km2 against
0.22 ha/km2), and **85.3% of PCEA's published gross tree change is inside** its own group
(453.1 of 531.0 ha). The 69%-outside figure belongs to **total transition patch area**
(754.4 of 2454.6 ha), which is a different quantity — the very conflation the A2 row above
records as already corrected once in NEWS, and which round 1's own README fix then
reintroduced in the other direction.

The two watched value-set arms stayed green across the whole build: `test_pipeline.R`'s
from->to pair arm (54 pairs on BULK, all named by the published classes) and
`item_validate.py`'s per-layer `distinct(table, attr)` coverage arm, which reported no
uncategorized value on any of the 23 items. All 23 items printed the expected #65 line (two
aspatial tables staged, undescribed here).

---

## The mechanism, and the enumeration that terminates it

Across the plan review and two code-check rounds, **ten of the fourteen findings were one
class**, and two of them were found *inside* the previous round's fix:

> **A prose claim that names a quantity which is not the one measured.**

The instances: "most of that item's floodplain" (41.7% is a minority); "most of PCEA's gross
change is outside" (85.3% is inside — total patch area is the quantity that is 69% outside);
"`area_ha` summed over `in_wsg` is exactly this item's headline figures" (5584.9 against
4112.1 — true only under the `from_class`/`to_class` filters); "the live item carries no
`*_footprint_*` key" (the condition is *at least one* missing); "both new flags are any-touch"
(`in_wsg` is a partition, not a flag); "`st_union()` … does not move this" (all 23 move);
"PCEA's gross change would roughly triple" (total change, not the published figures); the two
`7,273 km2` literals; "identical vertex count" (from the plan review); "stage_years-check.R
exercises `in_wsg_flag()`'s refusals" (it does not restore them).

Why this branch and not others: it adds **310 claim-bearing lines across 12 published or
durable files** — the collection description and four asset descriptions that go out on all 23
items, the public landing page, NEWS, CLAUDE.md, `scripts/README.md`, and code comments that
state measurements. Every one of them names a figure, and the figures now come in two scopes
over two different row sets, with a third quantity (raw `area_ha`) that looks like both.

### Terminating by enumeration, not by a reviewer saying it is complete

A reviewer's quiet round and an exhausted reviewer look identical, so the loop is ended by a
count over an enumerated set instead. Mechanically extracted every added line in those 12
files carrying a number or a quantifier (`every`, `each`, `all`, `both`, `only`, `most`,
`exactly`, `none`, `never`, `always`, `cannot`, `the same`), then resolved the distinct
numeric/identity assertions and **measured each against the artifacts** — `data/stac`,
`$FLOODPLAINS_DATA`, the GeoPackages through `sqlite3`, the item JSON, and the live API
snapshot.

**70 claims measured. 70 correct.** The full run is committed as
`planning/active/claim-enumeration.txt`. It covers: the six named per-group area pairs and
their outside shares; BULK's and PCEA's loss/gain/net in both scopes; the raw-`area_ha` sums
that the round-2 finding was about (5584.9 / 4112.1 / 754.4 / 2454.6 / 3.3x); PCEA's
+4.7% / +29.8% / 85.3%-inside / 67-vs-11 ha strip; the provincial totals
(10,092.27 / 10,611.35 / 519.08); the layer counts (246 / 222 / 269 / 69); every geometry claim
against the **live** items (433,852 -> 434,116, min +8 = DUNC, max +364 = FRAN, 23 of 23
gaining, 0 byte-identical, max 0.13%, 0 bbox moves); the two continuity claims (23 of 23 each);
the straddle census (115 = 23 x 5); and the distribution claims (22 groups in [0.8, 3.3], PCEA
41.7, 18 unnamed groups inside their stated bounds).

One claim was **loose but true** and has been tightened: NEWS said the 18 unnamed groups span
"0.8% to 2.7%" where the measured maximum is BOWR at 2.6488%, so the table now reads 2.6%. A
round-2 note had called that span "0.8%-2.6%", which as a *span* would have been false — which
is itself the mechanism, one more time, in a reviewer's own sentence.

### What the enumeration deliberately excludes, and why

`planning/active/*.md` — 448 of the 757 candidate lines. Those are the record of the work, not
claims the repo makes about its data: they carry the corrections themselves, dated, and a
reader is meant to see the wrong turn as well as the verdict (`planning.md`, "Keep the wrong
turns"). Numbers there are historical by construction; the files above are the ones a consumer
or a future session reads as current.

---

## code-check round 3 — the mechanism confirmed, and a blind spot in my own guard

Report: `planning/active/review-round3.md`. Round 3 enumerated **57 claims** against its own
mechanism statement and found **9 wrong, 3 overstated** — against my numeric enumeration's
70/70. The two enumerations are not in conflct: mine covered NUMBERS, which were all right;
round 3's covered **attributions and identities**, which were not. That is itself the lesson —
I enumerated the dimension I had already been burned on.

Its mechanism statement is sharper than mine and I have adopted it:

> A claim is written by restating a source — the upstream issue body, a sibling copy of the
> same sentence, or an earlier draft of itself — and is then checked for the PRESENCE of the
> thing it names rather than re-derived from the artifact it is attached to.

Two consequences it names that mine missed: **a fix lands in the copies someone was looking
at** (round 1 fixed the geometry claim in `01_stage.R` and `CLAUDE.md` and left `NEWS.md`, the
only copy a consumer reads; round 2 fixed the any-touch sentence in three places and left the
published landcover description), and **it is not confined to prose**.

### The blind spot, which is the finding that matters

`check_metric_scopes` — my own Phase 3b guard — **passes an inverted `in_wsg` filter on all 23
items**. Reproduced on a scratchpad copy of the real build with every unsuffixed figure
replaced by its outside complement:

```
inverted bulk: floodplain_ff04_km2 = 13.18   (live 659.99)
               net_ha              = +15.5   (live -1474.6)   <- sign flip
check_metric_scopes: 0 problems, straddle 23/23/23/23/23, seen 23
```

The census was built for a filter that was DROPPED, which makes the scopes equal and the
straddle count fall to 0. A filter applied with the wrong POLARITY does the opposite: the
ordering still holds, the net identity still holds, and the straddle count RISES. And a full
release makes no build-vs-live value comparison at all — `metric_drift` runs only under
`--only` — so the continuity this release rests on was asserted by nothing in the gate.

**Closed with `METRIC_SCOPE_MAJORITY = 0.5`**, a per-item arm: each in_wsg figure must be at
least half its footprint sibling. Measured over 23 items x 5 pairs = 115 values: the real
minimum is **0.5811** (PCEA ff02) and the maximum inverted value is **0.4189**, so 0.5 passes
115 of 115 real and refuses 115 of 115 inverted, with margin on both sides. Proved: 0 problems
on the real build, **115** on the inverted tree. A roster property, like `ALLOWED_YEAR_SETS` —
a group whose floodplain lay mostly outside its own line would fail it honestly.

**Still open, and filed rather than fixed:** a full release compares no VALUE against the live
catalogue. That gap predates #98 (step 0's containment arm compares id sets only), but this
release is the first whose safety argument is a continuity claim, which I had to measure by
hand. Named in the PR.

### The neighbour claim — six copies, 9.7% true

*"the difference between a pair is ground shared with a neighbour, which that neighbour's own
item also publishes"* — in the PUBLISHED collection description, the properties comment,
`README.Rmd`, `NEWS.md`, `CLAUDE.md` and `readme_functions.R`. Measured independently
(`planning/active/neighbour-measure.R`, BC Albers, one union built once):

```
sum of in_wsg areas    10092.24 km2
UNION of in_wsg areas  10092.24 km2   -> the items' own ground does not overlap at all
total outside strip      519.16 km2
covered by some item      50.58 km2  ( 9.7%)
published by NOBODY      468.57 km2  (90.3%)
```

So the sentence was right that the unsuffixed sum counts no ground twice — positively
confirmed, union equals sum — and wrong about why: 90.3% of the difference is outside **every
rostered group** and in nobody's `in_wsg`. The real caveat was said nowhere: **the unsuffixed
provincial total is a total of the ROSTERED floodplain, not of the province's.** All six copies
now say both halves. My figures reproduce round 3's to the hundredth.

### The others, each measured before fixing

| claim | verdict |
|---|---|
| published landcover description: "both flags are any-touch, so areas by flag come from `composition_*`" | **wrong** — `composition_*` has no `open_water_poly_id` (measured: its columns are `in_wsg`, `in_wetland`, `in_alr`, `in_open_water` and no other context column) |
| published transition description: read `in_fire`/`in_harvest` areas from `composition_*` | **wrong** — that table carries neither, on all 23. Rewritten to say so explicitly: for those two the patch flag is all there is |
| "PCEA ... Williston's `PARS` and `FINA` arms" | **wrong attribution, twice.** FINA and PARA are in no roster (`config/regions/*.yml` names PARS and neither of the others), and I had "corrected" the upstream log's PARA to the rostered-looking PARS. The real statement is that the ground is in groups this collection does not cover |
| "`patch_watercourse_*`'s key is now (`name_basin`, `patch_id`, `in_wsg`)" | **wrong twice over** — BULK 29,986 rows against 9,275 distinct triples, `blue_line_key` completes it, and `in_wsg` adds **0** combinations. Carried verbatim from the issue body |
| `NEWS.md` "`geometry`, `bbox` and `proj:bbox` are unchanged" | **wrong for geometry**, and the copy a consumer reads. Rounds 1 fixed the other two copies and left this one |
| `NEWS.md` "Provenance did not move ... Only `transition_patches` ... moved" | **wrong both halves** — `dunc_all_ff04`'s `processing:datetime` moves 2026-10-15T18:49:33Z -> 2026-10-18T22:37:59Z (DUNC was separately re-run upstream), and the backfill also added `composition` fields |
| `NEWS.md` "split **every** vector layer in both source bundles" | **wrong** — 246 of 468; the other 222 are the retired per-species layers. The exact quantifier `CLAUDE.md` warns about |
| `NEWS.md` "All 23 items republish, every asset" | **overstated** — 177 of 246 assets change; the 69 `style_*` QMLs are byte-identical on 23/23 |
| `NEWS.md` "all three GeoPackage asset descriptions say all of this" | **overstated** — `floodplain.gpkg`'s says none of the transition part |
| `item_validate.py` comment "23 items x 13 layers" | **wrong** — 269 layers: 11 on each of 19 items, 15 on each of the 4 annual-span ones |
| `README.Rmd` "counts no ground twice" against the only reachable render | **true of the data, false of the page** — the committed cache is pre-#98 and holds whole-footprint values, so an `update_query = FALSE` knit would state the property while displaying its negation. Closed with a cache-vintage guard in the query chunk, proved to fire on the committed cache |

### And one of my own measurements withdrawn

`CLAUDE.md` and `01_stage.R` carried a BULK geometry residual — symmetric difference 11.9 m2,
Hausdorff 0.0099 m. An independent pass over the same two geometries got **0.01 m2 and
0.0000 m**, three orders of magnitude apart, and neither run had recorded its CRS or whether
`st_make_valid()` had rewritten already-valid geometry (`code-check-spatial.md` says it does);
the items are UTM, not BC Albers, so the projection choice moves both figures. **Both numbers
are dropped rather than carried.** The conclusion they supported is unchanged and is what every
run agrees on: same locus, denser boundary, bbox unchanged on 23/23, area equal to live on
23/23. A measurement restated without its method cannot be re-derived, so nothing downstream
can disagree with it — which is the mechanism in its weakest form, and it was mine.

### The corollary caught in my own round-3 fix, by my own check

Round 3's second corollary is *a fix lands in the copies someone was looking at*. My round-3
fix did exactly that, in the same commit that wrote the corollary down: the README paragraph at
`:192` still read *"neighbouring groups share ground, so a sum of footprints would count it
twice"*.

The cause is worth recording because it is not a reasoning error. The batch asserted
`s.count(old) == 1` for the third replacement and then wrote the file **without applying it** —
`assert` and no `s = s.replace(...)`. The assertion passed, so the run reported success, and
the two replacements either side of it did land. An assert that proves the target EXISTS is not
an assert that the edit happened; the write needs `s2 != s`, which this one now does.

Found by grepping for the claim's shape across every non-planning file rather than by
re-reading the diff. Eight copies exist in all and all eight now carry the measured statement:
`CLAUDE.md`, `NEWS.md`, two in `README.Rmd`, two in `item_create.py` (one PUBLISHED), plus
`readme_functions.R` and `01_stage.R`. Checked for mutual consistency: the precise copies read
519.16 / 50.58 (9.7%) / 468.57 (90.3%) / 0.48% / 10,092.24, the two rounded copies read
519 / 51 / 469, and 50.58 / 10,611.35 = 0.48%.

---

## code-check round 4 — 7 findings, SIX inside round-3 fixes

Report: `planning/active/review-round4.md`. The round that most earned itself.

### F1, the worst: my cache guard could never pass, and it blocked release step 6

The round-3 cache-vintage guard tested for a `*_footprint_*` column in `cached$props`.
`fp_readme_props()` builds a **fixed 13-column tibble** and the footprint figures are not among
them, so the test is FALSE for every cache that can exist — measured both ways: the committed
v2.0.1 cache lacks the column, and the 23 **built v2.1.0 items** pushed through that function
give the same 13 columns. So the guard aborted *every* render including the
`update_query = TRUE` one its own error message prescribes as the remedy, leaving the page on
the pre-#98 prose: **the exact state it was written to prevent, reached by the guard itself.**
A guard that refuses its own remedy is worse than no guard.

Fixed to discriminate on the cache's own `version`, which it already carries, against a
`README_MIN_VERSION <- "2.1.0"` literal. Proved across versions: fires on 2.0.1 (the committed
cache), passes on 2.1.0, 2.1.1 and 3.0.0.

### F2, the only finding that reaches a consumer's numbers

The round-3 landcover description said `composition_*` "carries `in_wsg`, `in_open_water`,
`in_wetland` and `in_alr`, and no other context column". It also carries **`in_floodplain`**,
and that is the consequential one — the table spans the touched ring as well as the floodplain,
so an unfiltered `SUM(ha)` reads high:

```
BULK  70,884.0 all   vs 65,980.8 at in_floodplain=1   (+7.4%)
UFRA  33,025.3        vs 30,170.8                      (+9.5%)
PCEA  86,752.0        vs 84,270.0                      (+2.9%)
```

A consumer doing exactly what the published description said would be 3-10% high. `status`
(`change` / `stable` / `sieved`) was unmentioned too. Both now named, with the filter.

### F3, the third instance of one class in one issue

Round 3 grew the published `composition_*` claim and did **not** grow
`gpkg_required_columns()` — which is the defect the comment directly above `GPKG_BASE_COLUMNS`
describes, in the commit that fixed its second instance. `COMPOSITION_COLUMNS` added
(`in_floodplain`, `in_open_water`, `in_wetland`, `in_alr`, `status`, `ha`); 0 problems on the
build. Also "for those **two** the patch flag is all there is" is three — the transition layer
carries `in_fire_prior` as well as `in_fire` and `in_harvest`.

### F4 and F5, the measured-but-misattributed pair

- **"0.48% of that sum" named the wrong sum.** 50.5831/10,611.3951 = 0.4767% (footprint sum)
  but 50.5831/10,092.2377 = 0.5012% (in_wsg sum), and the nearest antecedent was the in_wsg
  one — named in the same sentence in two of the three copies. 0.48% of that is 48.44 km2, not
  50.58. All three copies now name the denominator.
- **519.16 is an ff04, BC-Albers figure and no copy said so**, while the prose attached it to
  "a pair's difference". The published per-pair differences are ff02 505.82, **ff04 519.08**,
  ff06 528.90 km2, gross_loss 908.40 ha, gross_gain 620.20 ha — so a consumer checking against
  the published ff04 properties gets 519.08, the gap being Albers geometry against rounded
  per-item UTM areas. Exactly the "restated without its method" objection that withdrew the
  Hausdorff figure one round earlier, and I had written the remedy down and not applied it
  here. Method now stated in every copy.

### F6, a comment that described coverage the arm does not have

The polarity arm's comment claimed it covered "a footprint of 0 with a positive in_wsg
figure". It cannot: that case never enters the `else`, because the ordering arm catches it
first. The case **nothing** sees is `footprint == in_wsg == 0` — it passes every per-item arm
and does not straddle, so the census misses it too. Unreachable on this build (all 115
footprint values non-zero) and caught on the staged side by `test_pipeline.R`'s `> 0` arms,
which are outside the release path. Recorded as a known gap rather than guarded, and the
comment now states the arm's real scope.

### F7, two internal contradictions

`CLAUDE.md` asserted "the right **provincial** total" two lines above "it is NOT a total of the
province's floodplain" — the same word for two different things. And it quoted the 246
source-bundle count while concluding "the quantifier is about the staged set", which is 269.
Both fixed.

### Re-derived and correct

Round 4 independently reproduced, to the digit: `METRIC_SCOPE_MAJORITY`'s separation (min
0.581080, max inverted 0.418920, 115/115 both ways, by EXECUTING the check on an inverted
copy); the neighbour measurement (519.1574 / 50.5831 / 468.5743 / union == sum 10,092.2377);
**eight** neighbour copies and no ninth; 246 assets = 69 style + 177 others, and against live
69 byte-identical / 177 changed / 0 new; 468 = 246 + 222; 269 = 11x19 + 15x4; the geometry
deltas and the 23/23 bbox identity; `patch_watercourse` 29,986 / 9,275; `dunc`'s datetime as
the only mover; the NEWS value table; PCEA's ratios; and that the withdrawal of the 11.9 m2
figure reached `01_stage.R` **and** `NEWS.md`.

### One observation worth keeping

The 90.3/9.7 split is dominated by PCEA — 351.97 of the 519.16 km2, and only 0.35% of PCEA's
own strip is another item's ground. Per ITEM the neighbour-covered share runs to 89.0% (DUNC),
80.9% (SLOC), 67.8% (WILL), 62.9% (MORR), so `NEWS.md`'s "true of a tenth of it" is true by
AREA and false by item for 4 of 23. Excluding PCEA the split is 29.5/70.5, so "most of it is
published by nobody" survives either way.
