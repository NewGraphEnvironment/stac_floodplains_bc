# Progress — Publish in_wsg and in_open_water (#98)

## Session 2026-10-19

- Plan-mode exploration: three Explore agents over `01_stage.R` + `fp_provenance.R`,
  `item_create.py` + `item_validate.py`, and `readme_functions.R` + `README.Rmd` +
  `test_pipeline.R` + the `*-check` family.
- Measured the split on disk across all 23 rostered groups before planning (findings.md).
- Three decisions taken at the plan gate (airvine): `_footprint_` suffix, all six metrics get a
  sibling, release is v2.1.0.
- Created branch `98-publish-in-wsg-and-in-open-water-items` off main at `affcd31`.
- Scaffolded PWF baseline with approved phases.
- Next: Phase 1.

### Phase 1 — staged both scopes

- `01_stage.R`: new `in_wsg_flag()` refuses an absent column and an NA value (both proved);
  `tree_transition_metrics()` returns six numbers; `read_area_km2()` → `read_areas_km2()`
  returning both scopes; `meta` gains the six `*_footprint_*` fields; the STAGED line prints
  `in_wsg (footprint)` per figure.
- Verified against BULK's live item: in_wsg loss/gain/net = 2793 / 1319 / -1475 against live
  2793.4 / 1318.7 / -1474.6 (continuity holds), and footprint ff02/04/06 = 611 / 660 / 699
  against live 610.91 / 659.99 / 698.94. in_wsg areas are 599 / 647 / 685.

### Phases 2 + 3 - publish surface and guards

One commit, because `item_validate.py` carries both halves.

- `02_raster_tag.py` `SHARED_FIELDS` and `item_validate.py` `SHARED_TAG_PROPERTIES` both gain
  the six. Tagging both scopes rather than only the published one is deliberate: the
  unsuffixed tags CHANGED MEANING, and a COG downloaded before this release carries a
  whole-footprint value under a name that now means in_wsg. It is free - rescoping the three
  area values rewrites every COG anyway.
- `item_create.py` publishes the six, and the prose lands in three places because STAC items
  carry no per-property description: the module docstring, the collection `description`
  (APPENDED - `item_validate.py:247` tests `EXPECTED_DERIVATION_STATEMENT` by containment),
  and all three GeoPackage asset descriptions. `transition_vector.gpkg` had none and gains
  one: it is the file the change figures are aggregated from and the one whose row count
  changed meaning.
- `item_validate.py` `check_metric_scopes()`, wired in before the ~1.3 GB checksum re-read:
  (1) all twelve present and numeric, bool excluded explicitly since it subtracts as 1;
  (2) `in_wsg <= footprint` on the five non-negative pairs (net excluded - signed);
  (3) `gain - loss == net` in both scopes; (4) `METRIC_SCOPE_CENSUS`, the straddle count per
  metric. Arm 4 is the only one that catches a DROPPED in_wsg filter, because two identical
  scopes satisfy arms 1-3. Measured 23/23 on all five over the floodplains#144 tree; dropped
  under `--partial`.
- `test_pipeline.R`: `in_wsg` required on every staged data layer; its distinct values asserted
  to be a non-empty subset of {FALSE, TRUE}; `DISTINCT wsg, species, scenario` deliberately NOT
  widened (the split is geometric, both sides carry the item key); `meta_core` and the
  positive-metric arms extended.

Measurements taken this phase:

- 246 whole-network layers across the 23 rostered groups, all carrying `in_wsg`. The 222
  without it are the retired per-species layers #80 does not stage.
- `gross_gain_ha` in_wsg vs footprint differs on all 23 groups, as does loss and all three
  areas - hence 23 across the board in `METRIC_SCOPE_CENSUS`. BULK in_wsg gain is 1318.7,
  equal to the live item exactly.

Gap noted, out of scope: `only_preflight.py` compares PROVENANCE properties only, so a
`--only` republish would not see a changed metric value. That was already true before #98
(the metrics are unprefixed and `canon()` only reads the four prefixes).

### BULK smoke test, and one correction

`WSG=bulk Rscript scripts/test_pipeline.R` PASSED end to end (exit 0, 05:49:54Z), through the
real `item_validate.py --partial` gate. Published properties on `bulk_all_ff04`:

```
floodplain_ff02_km2  598.52   footprint  610.91   (live today: 610.91)
floodplain_ff04_km2  646.81   footprint  659.99   (live today: 659.99)
floodplain_ff06_km2  685.15   footprint  698.94   (live today: 698.94)
gross_loss_ha       2793.4    footprint 2821.8    (live today: 2793.4)
gross_gain_ha       1318.7    footprint 1362.6    (live today: 1318.7)
net_ha             -1474.6    footprint -1459.2   (live today: -1474.6)
```

The watched from->to arm stayed green: 54 upstream pairs, all named by the published classes.

**Correction caught by that run.** The first version of `tree_transition_metrics()` rounded
inside `tot()`, so `net_ha` came from rounded gain and loss and published -1474.7 where the
live item serves -1474.6. The net has always been `round(gain - loss, 1)` over the UNROUNDED
sums. Restored, and the net identity in both guards is now a tolerance of 0.15 (three
independent `round(x, 1)` calls, so three half-steps) rather than 0.05, with the constant
named `METRIC_NET_TOLERANCE` so the two copies say why. A tenth of a hectare is nothing; a
published figure moving for a reason that is not the one the release is about is not.

### Phase 4 - prose

- `README.Rmd`: a new paragraph on the group-line split and the two new flags (any-touch, so
  areas come from `composition_*`), a new paragraph on the two metric scopes naming PCEA as
  the 42% case, and the totals sentence now says the columns are in_wsg figures and that the
  footprints are deliberately not totalled.
- `scripts/README.md`: the metric-derivation paragraph now records the twice-computed shape,
  the opposite directions of the two families, and that `check_metric_scopes`'s census is the
  only arm that catches a dropped filter.
- `CLAUDE.md`: two new blocks under Collection model - the required `in_wsg` column with the
  246/222 measurement and why the DISTINCT arm is not widened, and the two scopes with the
  opposite-directions finding, the COG-tag reasoning and the census rule.
- `NEWS.md`: `## v2.1.0 (unreleased)`, dated at release.
- `test_pipeline.R`'s SUMMARY line now prints both scopes, matching the STAGED line.

### Phase 3b - the review fixes, with each guard proved to fire

- **B2** `METRIC_SCOPE_CENSUS` is now gated on `--expect-provenance`, like `PROV_CENSUS` and the
  floor, whose own comment says why: "a rebuild has no business asserting how many areas the
  producer has re-modelled". The old gate (`not --partial`) would have failed an
  `ALLOW_SKIPPED=1` 22-group rebuild - a documented state - on a tree nobody was releasing.
- **B3** The MEASUREMENT prints either way, on its own `straddle:` line, in the format a
  release sets the literal from. `check_metric_scopes` returns `(problems, straddle, seen)`.
- **B4** New static pin: `02_raster_tag.SHARED_FIELDS` against `SHARED_TAG_PROPERTIES`. It
  needs one more than the provenance half does, because `check_cog_tags`'s `managed` set unions
  only `NGE_`-prefixed tags and the shared fields are written unprefixed - so for these names
  the add direction had nothing watching it at all.
- **B5** New `check_gpkg_columns` in `item_validate.py`: `in_wsg` present on every data layer of
  all three published GeoPackages, holding only TRUE/FALSE. This is the arm that makes the
  published asset description true - it was a claim about 23 items x 13 layers checked on one
  item by a script the release path never runs.
- **Acc1** Five new cases in `prov_fields-check.py` drive `check_metric_scopes`, including the
  census arm, which is the only one that can see a dropped filter.
- **G2** `only_preflight.py` gains `metric_drift()` and REFUSES on a changed figure rather than
  counting it. A rescoping changes no KEY, so `canon()` would have printed `0 lost` and let
  `--only` publish one item measuring something different from the other 22, irreversibly.

### Phase 5 - every check, on the build a release would be cut from

| check | result |
|---|---|
| `run_pipeline.sh` (full, 23 groups) | exit 0, 06:12:21Z; tree verified unmodified for the whole run |
| `item_validate.py --expect 23 --expect-provenance 23` | exit 0; `gpkg columns` arm live; `straddle ... 23 of 23` asserted; `floor 23 and the per-field census asserted` |
| `prov_fields-check.py` | 58 assertions, 0 failed |
| `gpkg_determinism-check.R` | PASS, 3 arms byte-identical across rebuilds |
| `style_determinism-check.py` | PASS, 3 GeoPackages byte-identical, re-run a no-op |
| `year_sets-check.py` | 16 assertions, 0 failed |
| `attribution_drift-check.py` | PASS, citation 770 chars |
| `catalogue_release-check.sh` | ALL PASS (shimmed; `data/stac` intact after) |
| `stage_years-check.R` | 13 assertions, 0 failed, 1 skipped - exactly the predicted `PIN_META_SHA256` skip - and its own guard reports the repo `data/` tree untouched by all four runs |
| `prov_census-measure.R` | agrees with the build line field for field; `PROVENANCE_FLOOR` stays 23 and `PROV_CENSUS` does not move |

So **no literal needed re-taking** except the new `METRIC_SCOPE_CENSUS`, whose measured value
on the build is exactly the 23 I set it to before the build ran.

### code-check round 1 — 6 findings, all fixed

Findings in `planning/active/review-round1.md`. Every one reproduced before acting.

| # | finding | fix |
|---|---|---|
| 1 | `metric_drift()` refused **any** `--only` whose figures moved, permanently and with no override — but the hazard is #98's one-time rescoping, and after it the ordinary reason to republish one item is an upstream RE-RUN, which moves those same figures without redefining anything. The module's own docstring and its `gained`-arm comment both name that case | scoped to the un-rescoped window and it now **expires by its own mechanism**: refuse only while the live item carries no `*_footprint_*` key. Measured 2026-10-19, 0 of 23 live items carry one; after v2.1.0 all 23 will, and the arm goes quiet. Proved in all four directions, and `prov_fields-check.py` now has both the refusal case and the expiry case |
| 2 | `README.Rmd` said "**most** of that item's floodplain lies in Williston's arms" — 41.73% outside is a MINORITY, and the same sentence says 42% one clause earlier. The public landing page | rewritten. Most of PCEA's *change* is outside while most of its *floodplain* is inside, which is the real and sharper statement, so the sentence now says that and gives the two nets |
| 3 | the release began publishing a claim about `in_open_water`, `open_water_poly_id`, `in_fire`, `in_harvest`, `in_wetland`, `in_alr` that **nothing read** — `check_gpkg_columns` was hardcoded to `IN_WSG_COLUMN`. The B5 defect class, re-introduced in the commit that fixed it | `check_gpkg_columns` now takes its required columns from `gpkg_required_columns(layer)` — the item key plus `in_wsg` on every layer, plus the six context columns on every `transition*` layer. 0 problems on the real build; the success line no longer over-claims |
| 4 | `01_stage.R`'s new comment said `st_union()` "is the same geometry, so the split does not move this" — disproved by this branch own measurement | rewritten with the measurement (0 of 23 byte-identical, +8 to +364 coords, 11.9 m2 / 1 cm on the ground) |
| 5 | `check_gpkg_columns`'s failure path raised `TypeError` on a mixed-type `in_wsg`, which SQLite permits in any column — the guard died with a traceback instead of naming the values | sorted on `str(v)`. Fail-closed either way; the diagnosis was the point |
| 6 | `test_pipeline.R` hardcoded `0.15` while `item_validate.py` names it `METRIC_NET_TOLERANCE`, with the R comment claiming they are the same constant and nothing joining them | static arm in `prov_fields-check.py` reads both net tolerances out of R source with comments stripped and compares them to the Python constant |

Three minors, all taken:

- `in_wsg_flag()` validated presence and NA but not the VALUE SET, and `as.logical(2L)` is TRUE
  — a corrupt flag would have been counted as in-group with the figures silently wrong.
- **My own finding, independent of the review:** `in_wsg_flag()` accepted a **zero-row** layer.
  `anyNA(logical(0))` is FALSE and `sum(numeric(0))` is 0, so an empty layer published `0` for
  every figure, two zeroes satisfy `check_metric_scopes`'s inequality, and the only arm that
  would have caught it is `test_pipeline.R`'s `> 0` — which the release path does not run.
- `task_plan.md` claimed `stage_years-check.R` "exercises `in_wsg_flag()`'s refusals". It
  re-runs `01_stage.R` so the function executes, but restores none of them. Corrected to record
  the gap rather than paper over it.

All four refusals proved to fire (no column / zero rows / NA / value 2), both valid shapes
(`0`/`1` and `TRUE`/`FALSE`) pass, and the stricter function **reproduces every published
figure** on BULK, PCEA, DUNC and FRAN against the committed `meta.json` — so the staged tree
in `data/` is still the tree this code produces.

`prov_fields-check.py`: **60 assertions, 0 failed.**

### code-check round 2 — 4 findings, two of them INSIDE round 1's fixes

Report in `planning/active/review-round2.md`. The release gate passed throughout; every
finding was about a published CLAIM, not a gate.

| # | finding | verdict / fix |
|---|---|---|
| 1 | round 1's `README.Rmd` fix replaced a false "most" with a **different** false "most": "most of PCEA's gross change is outside its own group". Measured: **85.3% is inside** (453.1 of 531.0 ha), and the change is ~4x DENSER inside (0.92 vs 0.22 ha/km2). The 69%-outside figure belongs to total transition patch area (754.4 of 2454.6) — the exact conflation `NEWS.md` was written to stop and that the A2 row records as already corrected once | rewritten to drop the rationale entirely and give the measured reason: the outside strip is strongly net-positive (67 gain against 11 loss), which is why the two nets disagree |
| 2 | the `transition_vector.gpkg` asset description I added in round 1 said "`area_ha` summed over `in_wsg` is exactly this item's own headline figures". **False**: BULK 5584.9 against 4112.1, PCEA 754.4 against 453.1. The layer holds every changed patch, not only tree gains and losses; the figures are exact only under the `from_class`/`to_class` filters the same description mentions two sentences earlier. One SQL query on the attached file disproves it | rewritten to say `in_wsg` is a true partition so the figures are sums over its TRUE rows UNDER those filters |
| 3 | `in_wsg_flag()`'s new value-set arm validated `raw` and returned `as.logical(raw)` **unchecked**. A `character` or `factor` `in_wsg` of `"0"`/`"1"` clears both arms (`as.character` gives `"0"`/`"1"`) and yields an **all-NA mask**, so every in_wsg figure publishes 0 while the footprint siblings stay correct — and every downstream arm passes it (0 <= fp; 0 == 0-0; the straddle census *increments*). Latent only because all 269 staged columns are declared BOOLEAN | the cast is now checked (`anyNA(flag)` after `as.logical`). Both shapes refuse, proved. `test_pipeline.R`'s twin arm used `as.integer(iw) %in% c(0L,1L)`, which **accepted** `"0"`/`"1"` and truncated `1.5` despite its message claiming otherwise — now compared as strings against the four spellings |
| 4 | `only_preflight.py`'s refusal message claimed the live item "carries no `*_footprint_*` key" while the condition is "at least one missing" — wrong in exactly the half-rescoped case its own docstring reserves. Same class round 1 flagged on the previous version of that message | `missing_footprint()` extracted and named, and the message now reports WHICH keys put the item inside the window |

Plus the `NEWS.md` / `CLAUDE.md` "Both new flags are any-touch" sentence, where `in_wsg` is a
plausible antecedent and `in_wsg` being any-touch is flatly false — a reader taking it that
way stops trusting the one sum this release is built on. Both rewritten to separate the three
kinds of column: `in_open_water` any-touch, `open_water_poly_id` an identifier, `in_wsg` a
true partition.

**Round 2's own verdict on round 1's fixes:** 4 of 6 sound and probed (the `metric_drift`
window survived four attempts to fool it; `gpkg_required_columns()` is exact — `startswith`
matches exactly the two patch layers across 69 files, 0 missing columns on 269 layers; the
`absent`/`continue` flow is right; the tolerance regex survives a reflow).
