# Code-check round 4 — `98-publish-in-wsg-and-in-open-water-items`

Base `affcd3144421b486884a4eab675c32a7cee3b053`. Reviewed `48d71eb` (the round-3 fix commit),
then re-checked every finding against `173831c`, which the parent session landed mid-review
("Apply the seventh copy my own round-3 fix asserted and skipped"). All seven findings below
survive `173831c`; one of them is sharpened by it (F4).

Working tree untouched. Everything measured on copies under the session scratchpad, or
read-only (`sqlite3 'file:…?immutable=1'`, `aws`-free `curl` against the live API). Nothing in
`data/` was written.

Verification method, for every numeric claim: re-derived from the artifact, never from another
copy of the sentence. The live catalogue was fetched item by item
(`https://images.a11s.one/collections/stac-floodplains-bc/items/<id>`, 23 × HTTP 200) so the
build/live comparisons are against what is actually served, not against another build.

---

## Findings

### F1 — **[bug]** `README.Rmd:80-85` — the new cache-vintage guard aborts **every** render, including the post-release one its own message prescribes

The guard added by round 3:

```r
if (!"floodplain_ff04_footprint_km2" %in% names(readRDS(CACHE)$props)) stop(...)
```

`scripts/readme_functions.R:261-282` (`fp_readme_props()`) builds the cache's `props` from a
**fixed column list** — `id, wsg, region, species, scenario, flood_factor,
floodplain_ff02_km2, floodplain_ff04_km2, floodplain_ff06_km2, gross_loss_ha, gross_gain_ha,
net_ha, deprecated` — and no `*_footprint_*` column is in it. So the tested key is absent from
every cache that can ever exist, and the guard is unconditional.

Measured two ways:

* the committed cache: `readRDS("data/readme_items.rds")$props` has those 13 columns,
  `"floodplain_ff04_footprint_km2" %in% names(...)` is `FALSE`;
* a simulated post-release fetch: the **23 built v2.1.0 items**, which carry all twelve
  figures, pushed through `fp_readme_props()` give the same 13 columns —
  `guard would fire: TRUE`.

Consequence: both release step 6 commands (`scripts/README.md:124-125`) abort — the
`github_document` render with `update_query = TRUE` and the `index.html` render with
`update_query = FALSE`. The stop() message's remedy ("Render with
`params$update_query = TRUE`, after the v2.1.0 release has published") **is** the command
that fails. `README.md` and `index.html` cannot be regenerated after the release, so the
landing page keeps its v2.0.1 text — including the pre-#98 footprint prose, which is exactly
the state the guard was written to prevent, reached by the guard itself. This is also what
would silently strand the round-3 and round-4 `README.Rmd` prose fixes (the `:192` rewrite in
`173831c` among them): they are in the source and unreachable in the artifact.

The guard's own comment states the confusion that produced it — *"Deliberately NOT a
`fp_req()` requirement: the figures themselves are not read from the cache's footprint
columns"* — true, because there are no such columns in `props` at all. Presence of the
footprint property discriminates **items**, which is what `item_create.py` publishes; the
cache is a hand-listed projection of an item, and the claim was checked against the wrong
artifact.

Two remedies, either of which works:

* discriminate on `cached$version`, which the cache already carries (`"2.0.1"` today) and
  which moves on the release; or
* add the six `*_footprint_*` columns to `fp_readme_props()` as `fp_req()` fields — then the
  guard as written is correct, and the README prose at `:160`/`:192` could cite the footprint
  totals from the cache rather than from literals.

A render of `README.Rmd` is not part of `run_pipeline.sh` or `catalogue_release.sh`, so no
existing guard catches this; it surfaces when a human runs release step 6.

### F2 — **[bug]** `scripts/item_create.py:437-438` — the rewritten `floodplain_landcover.gpkg` description's exhaustive claim is false, and the column it omits is the consequential one

Published on all 23 items:

> *"…read the `composition_*` table in this file, which is counted by cell centre; it carries
> `in_wsg`, `in_open_water`, `in_wetland` and `in_alr`, and no other context column."*

Measured on all 23 staged `floodplain_landcover.gpkg`, columns of
`composition_all_ff04_2017_2023` (identical on every item):

```
fid, from_code, to_code, from_class, to_class, status,
in_floodplain, in_wsg, in_wetland, in_alr, in_open_water,
cells, ha, wsg, species, scenario
```

`in_floodplain` is a fifth `in_*` context column, and upstream documents it as the one that
matters most: *"the cell CENTRE lies in the published floodplain polygon. Always present. It
is… every share's denominator"* (`floodplains/scripts/floodplain_lcc/fp_composition.R:27-29`;
`floodplains/CLAUDE.md:172` — *"`in_floodplain` … is every share's denominator"*). The table
spans **both** sides of it, because the producer rasterises with a `touches = TRUE` ring past
the floodplain polygon:

| item | Σ `ha` | Σ `ha` where `in_floodplain = 1` | overstatement |
|---|---:|---:|---:|
| BULK | 70,884.0 | 65,980.8 | +7.4% |
| UFRA | 33,025.3 | 30,170.8 | +9.5% |
| PCEA | 86,752.0 | 84,270.0 | +2.9% |

So a consumer who does exactly what the published description tells them — *"For an AREA by
land-cover class and `in_open_water` read the `composition_*` table in this file"* — and
trusts *"no other context column"* sums the raster window rather than the floodplain, and is
7–10% high on the groups measured. The description needs to name `in_floodplain` and say it
is the filter; `status` (three values: `change`, `sieved`, `stable`) is a second thing a
consumer summing `ha` has to know and the description does not mention it either.

This is new text: the pre-round-3 sentence said areas come from `composition_*` and made no
column claim. The exhaustive clause and the omission arrived together.

### F3 — **[fragile]** `scripts/item_validate.py:1015-1039` — round 3 grew a published column claim without growing the guard that the same commit's comment says must grow with it

`gpkg_required_columns()` adds `TRANSITION_COLUMNS` only for layers whose name starts
`transition`; `composition_*` is checked for `GPKG_BASE_COLUMNS` alone. Round 3's rewrite
added a published claim about `composition_*`'s four context columns (F2), and nothing checks
it — the validator's own summary line, measured on this build, reads:

> `gpkg columns: every data layer of 3 GeoPackages per item carries wsg, species, scenario,
> in_wsg … and every transition* layer also carries in_open_water, open_water_poly_id,
> in_fire, in_harvest, in_wetland, in_alr, which is what the asset descriptions claim`

The comment above `GPKG_BASE_COLUMNS` is explicit about the rule and about the history:
*"What the published asset descriptions CLAIM, per file, so the guard's scope is the claim's
scope. A single `in_wsg` constant was the first version, and it left the six columns the same
release started claiming watched by nothing — the B5 defect class re-introduced in the commit
that fixed it. `item_create.py` is the other copy; if a description grows a column name, it
grows here."* Round 3 is the third instance of that.

Related, smaller: the `transition` layer also carries `in_fire_prior` (plus `fire_prior_year`,
`fire_prior_number`), measured on BULK and UFRA. The rewritten `transition_vector.gpkg`
description enumerates *"`in_fire` / `in_harvest` / `in_wetland` / `in_alr`"* and then says
*"for those **two** the patch flag is all there is"* — it is three: `in_fire_prior` has no
`composition_*` coverage either.

### F4 — **[fragile]** "0.48% of that sum" names the wrong sum, in three copies

`CLAUDE.md:423`, `NEWS.md:58`, `scripts/item_create.py:535-536`.

Re-derived (`sf`, EPSG:3005, the 23 staged `floodplain.gpkg` `all_ff04` layers, one union
built once — `planning/active/neighbour-measure.R` reproduces exactly):

```
sum in_wsg 10092.2377   union 10092.2377   overlap -0.0000
outside total 519.1574   covered 50.5831 (9.74%)   nobody 468.5743 (90.26%)
footprint sum 10611.3951
```

* `50.5831 / 10,611.3951 = 0.4767%` → 0.48% **of the footprint sum**
* `50.5831 / 10,092.2377 = 0.5012%` → 0.50% **of the in_wsg sum**

In all three copies the nearest antecedent of *"that sum"* is the in_wsg sum, and in two of
them it is named in the same sentence:

* `CLAUDE.md:422-424` — *"the union of the 23 in_wsg pieces equals their sum (10,092.24 km2),
  so the unsuffixed total genuinely counts no ground twice; summing footprints double-counts
  by 0.48% of that sum."* 0.48% of 10,092.24 is 48.44 km²; the double-count is 50.58 km².
* `NEWS.md:57-58` — same sentence shape, same antecedent. This is the copy a consumer reads.
* `item_create.py:534-536` — *"of the 519.16 km2 by which the footprint **sum** exceeds the
  in_wsg **sum**, only 50.58 km2 (9.7%) … so summing footprints double-counts by 0.48% of
  that sum"*: two candidate antecedents, the nearer one wrong.

`173831c` sharpens this rather than fixing it: its new note in `planning/active/findings.md`
records the correct denominator — *"and 50.58 / 10,611.35 = 0.48%"* — in the same commit that
leaves the three prose copies attached to the other sum. The mutual-consistency check was run
on the digits and not on what they are a percentage of.

The **published** collection description (`item_create.py:774`) says *"about half a percent"*,
which is true against either denominator, so nothing is wrong in the served text. Fix the
three internal/NEWS copies by naming the denominator ("0.48% of the footprint sum") or by
quoting the km² (50.58 km²).

### F5 — **[fragile]** the 519.16 / 50.58 / 468.57 split is an **ff04-only** measurement, and no copy says so — including the published collection description

`planning/active/neighbour-measure.R` reads `layer = "all_ff04"` and nothing else, so the
split is a property of one of the six pairs. The per-pair differences on the published
properties, over the 23 items:

| pair | difference |
|---|---:|
| `floodplain_ff02` | 505.82 km² |
| `floodplain_ff04` | **519.08 km²** |
| `floodplain_ff06` | 528.90 km² |
| `gross_loss` | 908.4 ha |
| `gross_gain` | 620.2 ha |

The copies attach the figure to *"a pair's difference"* and to *"the footprint areas"*
generically:

* `item_create.py:770-773`, **served on the collection**: *"A pair's difference is ground
  outside the item's own group … of the 519.16 km2 by which the footprint areas exceed the
  in_wsg areas…"*
* `NEWS.md:54-56` — same.
* `README.Rmd:192` (new in `173831c`) — *"of the 519 km² by which they exceed the figures
  above"*, where "the figures above" are the table's four totals, only one of which is ff04
  area.

Two consequences for a consumer who checks it: against ff02 or the change figures they get a
different number, and against the **published ff04 properties** they get 519.08, not 519.16 —
the 0.08 km² being Albers geometry versus per-item UTM figures rounded to 2 dp. That gap is
small; the missing method is the point, and it is the same objection round 3 used to justify
withdrawing the Hausdorff figure ("a measurement restated without the method that produced it
cannot be re-derived"). Name the pair and the CRS: "measured on the ff04 delineations in BC
Albers".

### F6 — **[fragile]** `scripts/item_validate.py:957-961` — the polarity arm's comment names a case the arm cannot see, and the case nothing sees is a different one

```python
            else:
                if props[inw] < props[fp]:
                    straddle[inw] += 1
                # The polarity arm. Checked even where the two are equal, so a footprint of 0
                # with a positive in_wsg figure cannot slip through as "not straddling".
                if props[fp] and props[inw] < METRIC_SCOPE_MAJORITY * props[fp]:
```

Measured, by mutating a scratchpad copy of `bulk_all_ff04.json`:

* `floodplain_ff02_footprint_km2 = 0` with the in_wsg figure left at 598.52 → **1 problem**,
  raised by the **ordering** arm. `props[inw] > props[fp]` is true, so the `else` — and
  therefore the polarity arm — is never reached. And the polarity arm is explicitly gated off
  when `props[fp]` is falsy, so it cannot see a zero footprint under any branch. The comment's
  stated reason for the arm's placement describes a case the arm has no part in.
* `floodplain_ff02_footprint_km2 = floodplain_ff02_km2 = 0` → **0 problems** from
  `check_metric_scopes(census=False)`. Nothing fires: ordering passes, straddle does not
  increment, polarity is gated off, the net identity holds. With `census=True` the straddle
  count catches it (22 of 23), but `census` is off for a rebuild and for `--only`
  (`assert_straddle = args.expect_provenance is not None and not args.partial`,
  `item_validate.py:2467`), which are exactly the paths a single-item republish takes.

Not a defect in today's data — all 115 footprints are non-zero — but the comment is the only
written statement of this arm's scope, and it is wrong in both directions.

### F7 — **[low]** two self-contradictory restatements in `CLAUDE.md`

* `CLAUDE.md:440-441`: *"the unsuffixed sum is the right **provincial** total because it
  counts no ground twice, and it is NOT a total of the province's floodplain"*. Every other
  copy of this claim says "regional total" in the first clause; as written the sentence
  asserts and denies the same thing.
* `CLAUDE.md:171-174`: *"all **246** whole-network layers over the 23 rostered groups carry
  it … so the quantifier is about the staged set, not about the files"*. 246 is the
  **file**-side count (both upstream bundles, re-derived below); the staged set is **269**,
  which is what `item_validate.py:1001` says. Both numbers are right about their own scope
  and the sentence swaps them.

---

## Re-derived and **correct** (no finding)

All measured this session, from the artifacts.

**`METRIC_SCOPE_MAJORITY`, both bounds and both directions — exactly as claimed.**
Over 23 items × 5 pairs = 115 values on the staged build: minimum ratio **0.581080**
(`pcea_all_ff04` `floodplain_ff02_km2`, 488.2 / 840.16), maximum inverted value **0.418920**
(same pair). `0.5` passes **115 of 115** real and refuses **115 of 115** inverted. No
zero-footprint value exists. Confirmed by execution, not arithmetic: `check_metric_scopes()`
on `data/stac` returns **0 problems**, straddle 23/23/23/23/23, seen 23; on a scratchpad copy
with every unsuffixed figure replaced by its outside complement it returns **115 problems**,
and BULK's inverted `floodplain_ff04_km2` is **13.18** against a live 659.99 with `net_ha`
**+15.5** against a live −1474.6 — the figures the comment quotes.

**The neighbour measurement reproduces to the digit.** 519.1574 → 519.16; 50.5831 (9.74%) →
50.58 (9.7%); 468.5743 (90.26%) → 468.57 (90.3%); union of the 23 in_wsg pieces equals their
sum at 10092.2377 → 10,092.24 km²; footprint sum 10611.3951. `readme_functions.R:418`'s
rounded copy (10,611 → 10,092; 519 / 51 / 469) is right.

**Eight copies of the neighbour claim, no ninth.** `git grep` for `519|50\.58|468\.57|10,092|
10,611|90\.3%|9\.7%` outside `planning/`, `index.html` and the generated `README.md` finds
exactly `CLAUDE.md`, `NEWS.md`, `README.Rmd` ×2, `item_create.py` ×2 (one published),
`readme_functions.R`, `01_stage.R`. `173831c` closed the `README.Rmd:192` copy that round 3
asserted and skipped. `README.md` and `index.html` carry no `in_wsg` at all — correct, they
are the v2.0.1 renderings and release step 6 regenerates them (which F1 currently blocks).

**Every NEWS figure.**
*177 of 246 assets*: 246 assets staged (10 on 19 items, 14 on 4), 69 `style_*`, 177 others.
Against the **live** catalogue: 69 style assets byte-identical by `file:checksum` on all 23,
all 177 others changed, 0 new asset keys.
*246 of 468 layers split*: over the 23 rostered groups' two upstream bundles, 468 layers, 246
carrying `in_wsg` and 222 not — and all 222 are per-species (`bt_*`, `ch_*`, `co_*`), none
whole-network. The staged count is 269 = 246 + the 23 rewritten `transition` layers in
`transition_vector.gpkg`, and `item_validate.py`'s "11 on each of 19 items and 15 on each of
the 4" is exact.
*geometry changes, bbox does not*: all 23 geometries differ from live, none byte-identical;
coordinate values +8 (DUNC, 167,098 → 167,106, 0.0048%) to +364 (FRAN, 449,474 → 449,838),
max share 0.1312% (LCHL) → "0.00% to 0.13%"; BULK 433,852 → 434,116 as `01_stage.R` says;
`bbox` identical on 23/23; every `*_footprint_km2` equals the live item's unsuffixed area on
23/23 (69 of 69 comparisons).
*`patch_watercourse` is not a key*: BULK `patch_watercourse_all_ff04_2017_2023` has 29,986
rows, 9,275 distinct `(name_basin, patch_id, in_wsg)`, 9,275 distinct `(name_basin, patch_id)`
— so `in_wsg` adds **0** combinations — and 29,986 distinct
`(name_basin, patch_id, blue_line_key)`, so `blue_line_key` is what completes it.
*provenance on 22 of 23*: comparing all 23 live items against the build, `processing:datetime`
moves on exactly one — `dunc_all_ff04`, `2026-10-15T18:49:33Z → 2026-10-18T22:37:59Z`.
*the value table*: PCEA 843.34 → 491.38 (41.73%), LCHL 426.81 → 412.92 (3.25%), TABR 267.19 →
258.73 (3.17%), MCGR 355.33 → 344.61 (3.02%), UNTH 234.93 → 233.03 (0.81%), and the other 18
span 0.8285% (SLOC) to 2.6488% (BOWR) → "18 more between 0.8% and 2.6%". The "was" column
equals the live published value on all five.
*PCEA's 3.3×*: transition patches sum 754.4 ha at `in_wsg = 1` and 2454.6 ha unclipped
(3.254×); tree loss 227.7 → 238.5 (+4.74%), tree gain 225.4 → 292.5 (+29.77%).
*BULK's raw-sum trap* (`CLAUDE.md:195`): Σ`area_ha` over `in_wsg = 1` is **5584.9** against
2793.4 + 1318.7 = 4112.1.

**The withdrawal reached every copy.** `11.9 m2` / `Hausdorff 0.0099 m` survive only in
`CLAUDE.md:456-466` (the paragraph that withdraws them) and in `planning/`. `01_stage.R` and
`NEWS.md` carry neither — the copy round 3's own corollary predicted would be missed is
clean. `CLAUDE.md`'s supporting claim that the items are UTM is right: `proj:epsg` is 32610
(14), 32611 (6), 32609 (3), no 3005.

**PARS / PARA / FINA.** `config/regions/*.yml` in `floodplains` names `PARS` (peace.yml:25,
`[PCEA, PARS, PINE]`) and neither `PARA` nor `FINA`. The upstream log does say PARA and FINA
(`scripts/floodplain_lcc/logs/20261018_wsg_split_backfill.md:67`,
`20261017_whole_network_peace.md:47`). Both halves of the round-3 correction hold.

**The split layers behave as described.** `all_ff04` is exactly 2 features on all 23;
`all_ff04_by_blue_line_key` row count equals its distinct `(blue_line_key, in_wsg)` count on
all 23; `floodplain.gpkg` holds the same 4 data layers on all 23; the `transition_vector.gpkg`
description's negative claim is true — `composition_*` carries no `in_fire` or `in_harvest` on
any of the 23. README's PCEA figures are exact: `net_ha` −2.3, `net_footprint_ha` +54.1,
outside gain 67.1 ha, outside loss 10.8 ha, ff04 gap 41.73%; and "the gap is usually 1–3%"
holds for 16 of 23 strictly, 19 of 23 within 0.8–3.3%.

**The build is current.** `data/stac` carries the round-3 descriptions verbatim (checked on
`bulk_all_ff04` for all three GeoPackage assets and on `collection.json`), so the documents a
release would publish are the reviewed text and not an older build. The full validator run
over the build exits 0 with every line green.

---

## Observation, not a finding

The 90.3% / 9.7% split is an aggregate dominated by one group. Per item, the share of the
outside strip that **is** another item's own ground ranges from 0.35% (PCEA, 351.97 km² of the
519.16 total) to 89.0% (DUNC), 80.9% (SLOC), 67.8% (WILL), 62.9% (MORR). So
`NEWS.md:59-60`'s *"an earlier draft of this entry said the shared ground was a neighbour's,
which is true of a tenth of it"* is true **by area** and false **by item** — for 4 of 23
items the majority of the pair difference is a neighbour's ground. Excluding PCEA the split is
29.5% / 70.5%, so "most of it is published by nobody" survives either way. Nothing here is
wrong as written; it is worth knowing that the headline ratio is one group's reservoir.

---

## Inside a round-3 fix?

**Yes — six of the seven.**

| finding | round-3 fix it is inside |
|---|---|
| F1 | item 6, the `README.Rmd` cache-vintage guard |
| F2 | item 3, the rewritten `floodplain_landcover.gpkg` description |
| F3 | item 3 again — the published claim grew, the guard did not |
| F4 | item 2, the six rewritten neighbour copies |
| F5 | item 2, same rewrite (and carried into `173831c`'s seventh copy) |
| F6 | item 1, `METRIC_SCOPE_MAJORITY`'s polarity arm |
| F7 | item 2 (`CLAUDE.md` prose) — not inside a fix, a restatement beside one |

F1 is a blocker for release step 6. F2 is the only one that reaches a consumer's numbers.
The review loop should continue: F2 and F3 are the same claim unfixed in two places, which is
the shape that produced rounds 2 and 3.
