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

The two watched value-set arms stayed green across the whole build: `test_pipeline.R`'s
from->to pair arm (54 pairs on BULK, all named by the published classes) and
`item_validate.py`'s per-layer `distinct(table, attr)` coverage arm, which reported no
uncategorized value on any of the 23 items. All 23 items printed the expected #65 line (two
aspatial tables staged, undescribed here).
