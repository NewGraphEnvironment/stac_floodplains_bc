# Code-check round 5 — `98-publish-in-wsg-and-in-open-water-items`

Base `affcd3144421b486884a4eab675c32a7cee3b053`. Scope: the round-4 fix commits `e42ca5e`
and `173831c`, every fresh claim they introduced, re-derived from the artifacts rather than
from the commit message. Measured 2026-10-19 on the staged v2.1.0 build in `data/stac`
(read-only, `sqlite3 -readonly` / `mode=ro` URIs) and on `../floodplains/data`. All mutation
work was done on copies under the session scratchpad; the working tree and `data/` were not
written to.

**Verdict: not clean. Eleven findings, and nine of them are inside a round-4 fix** — one is a
new wrong number in a published consumer-facing string, four are the fix landing only in the
copies the author was looking at, and two are the replacement comment being wrong in both
directions about the coverage it was written to state correctly.

---

## Findings

### F1 — **[bug]** `scripts/item_create.py:439` — the published `3-10%` range is false on 1 of 23 items, and it was taken from the three items round 4 sampled rather than from the population

Published on all 23 items and **already staged** (verified in `data/stac/bulk_all_ff04.json`,
so a release from this tree publishes it):

> *"the table also covers the ring the floodplain raster only touches, so an unfiltered
> `SUM(ha)` is **3-10%** above the floodplain itself (7.4% on this collection's BULK item)."*

Measured over all 23 staged `composition_all_ff04_2017_2023` tables —
`Σha ÷ Σha WHERE in_floodplain = 1 − 1`, which is exactly the arithmetic the sentence
describes:

| item | Σ ha | Σ ha, `in_floodplain = 1` | overstatement |
|---|---:|---:|---:|
| pcea | 86,752.00 | 84,270.04 | **2.95%** |
| kotl | 78,540.03 | 75,354.93 | 4.23% |
| fran | 115,074.67 | 109,638.84 | 4.96% |
| morr | 50,524.99 | 47,906.88 | 5.46% |
| mcgr | 37,604.89 | 35,517.38 | 5.88% |
| pars | 59,405.59 | 55,904.59 | 6.26% |
| bowr | 41,424.04 | 38,975.11 | 6.28% |
| necr | 80,782.87 | 75,909.09 | 6.42% |
| lsal | 30,948.89 | 29,064.58 | 6.48% |
| tabr | 28,566.19 | 26,698.42 | 7.00% |
| larl | 40,194.81 | 37,526.82 | 7.11% |
| will | 37,593.45 | 35,098.47 | 7.11% |
| mork | 71,490.72 | 66,677.16 | 7.22% |
| lchl | 45,772.06 | 42,647.57 | 7.33% |
| thom | 27,597.23 | 25,698.69 | 7.39% |
| **bulk** | 70,884.02 | 65,980.75 | **7.43%** |
| lnth | 41,840.57 | 38,861.97 | 7.66% |
| pine | 52,955.46 | 48,857.27 | 8.39% |
| dunc | 20,157.38 | 18,505.36 | 8.93% |
| sloc | 16,830.13 | 15,437.32 | 9.02% |
| ufra | 33,025.33 | 30,170.78 | 9.46% |
| kisp | 35,556.86 | 32,417.67 | 9.68% |
| **unth** | 26,100.61 | 23,490.67 | **11.11%** |

`unth_all_ff04` is **11.11%**, outside the published range by 1.1 points; `pcea_all_ff04` is
2.95%, below it. The parenthetical BULK figure (7.43% → 7.4%) is right.

The provenance of the error is in the round-4 report itself: `review-round4.md:94-99`
measured **three** items (BULK 7.4, UFRA 9.5, PCEA 2.9) and wrote *"7–10% high on the groups
measured"*; the fix published `3-10%` as if those three bracketed the range. Nothing was run
over the other twenty. This is the review class in its purest form — a quantifier written
from a sample and then checked for plausibility rather than re-derived.

Direction matters for a consumer: a UNTH user who corrects by the top of the published range
is still over-reading. `3-11%` (or `2.9-11.2%`) is the measured range; the median is 7.11%.

Two supporting facts, both measured and both fine: `in_floodplain = 1` really is the
floodplain (Σha ÷ 100 is within **0.08%** of the item's own `floodplain_ff04_footprint_km2`
on every one of the 23), and `status` really holds exactly `change` / `sieved` / `stable` on
all 23.

### F2 — **[bug]** `scripts/item_create.py:787-789` — the **collection** description still sends consumers to `composition_*` for areas with no `in_floodplain` filter

The collection description, staged in `data/stac/collection.json`:

> *"the flag is any-touch, so open-water AREAS are read from the `composition_*` table rather
> than summed off the patches."*

That is the instruction round 4 called *"the only finding that reaches a consumer numbers"*
(F2) and measured as 3-11% wrong. `e42ca5e` added **Filter it on `in_floodplain = 1`** to the
two item asset descriptions (`:438-441`, `:502-503`) and left the collection copy alone. The
collection description is the first text a consumer reads, and it is the one served on
`/collections/stac-floodplains-bc`.

Same uncorrected instruction, same words, in `README.Rmd:166` — the public landing page:

> *"read open-water **areas** from the `composition_*` table (counted by cell centre) rather
> than summing `area_ha` over the flagged patches."*

and in `CLAUDE.md:190`. Four copies of one instruction, two fixed.

### F3 — **[bug]** `scripts/item_create.py:778` — the published collection description still carries `519.16` with no method, which is the copy round-4's F5 named first

`review-round4.md:171-176` opened with *"`item_create.py:770-773`, **served on the
collection***". `e42ca5e` put the method statement into `CLAUDE.md:432-436`,
`NEWS.md:54-56`, and the `item_create.py` **comment** at `:539-542` — 240 lines above the
published string — and did not touch the string:

> *"of the 519.16 km2 by which **the footprint areas exceed the in_wsg areas**, 50.58 km2
> (9.7%) is another item's own ground…"*

The subject is plural and generic, and the figure is ff04-only. Measured in BC Albers over
the staged delineations, the three pairs differ by **505.80 (ff02) / 519.16 (ff04) / 528.88
(ff06) km²**; the change pairs differ by 908.40 ha (loss) and 620.20 ha (gain). A consumer
who checks 519.16 against the **published** ff04 properties gets 519.08. This is the exact
objection ("a measurement restated without the method that produced it cannot be
re-derived") that the same commit used to justify the CLAUDE.md and NEWS edits.

### F4 — **[bug]** `README.Rmd:172` and `README.Rmd:204` — the two landing-page copies kept the unscoped claim, and `:204` was named in the round-4 report

* `:172` — *"of the 519 km² by which the footprint areas exceed the in_wsg areas across the
  catalogue"*: same plural subject as F3, no ff04, no CRS.
* `:204` — *"The `*_footprint_*` properties are the same figures unclipped … of the 519 km²
  by which **they** exceed **the figures above**"*. "The figures above" are the table's four
  totals (km², loss, gain, net); only one of them is ff04 area, and the other three differ by
  908.40 ha, 620.20 ha and 288.0 ha. `review-round4.md:192-194` flagged this line by name
  (as `:192`, pre-reflow). Unchanged in `e42ca5e`.

`README.Rmd` renders `README.md` and `index.html`, so these are the copies most consumers
read.

### F5 — **[bug]** `NEWS.md:62` — the self-contradiction `e42ca5e` removed from `CLAUDE.md` survives in `NEWS.md`, inside the paragraph the same commit rewrote

The commit message names this defect: *"`CLAUDE.md` said 'provincial total' two lines above
'not a total of the province'"*. `CLAUDE.md:427` and `:451` were both reworded. `NEWS.md:62`
— six lines below the hunk `e42ca5e` edited — says it in **one sentence**:

> *"The unsuffixed **provincial total** is therefore a total of the **rostered** floodplain,
> not of the **province's**"*

Also unreworded, by the commit's own criterion: `NEWS.md:52`, `item_create.py:534` (comment)
and `item_create.py:774` (the **published** collection description), all *"a regional or
provincial total is their plain sum"*.

### F6 — **[bug]** `scripts/item_validate.py:962-968` — the replacement comment's new scope claim is wrong in the other direction: the census **does** see `footprint == in_wsg == 0`

The comment `e42ca5e` wrote to correct the previous comment's wrong scope claim:

> *"What NOTHING here sees is `footprint == in_wsg == 0`, which passes every per-item arm and
> **is invisible to the census too** (a zero pair does not straddle, and the census is
> release-gated). Measured by mutation."*

Measured by mutation, on a copy of the 23 item documents in the scratchpad, importing
`check_metric_scopes` directly:

```
BASELINE problems: 0  seen 23  straddle {ff02 23, ff04 23, ff06 23, gross_loss 23, gross_gain 23}
MUTATED (bulk floodplain_ff04_km2 = 0, floodplain_ff04_footprint_km2 = 0)
  census=True : problems=1
    "floodplain_ff04_km2: 22 of 23 item(s) straddle their group line … expected exactly 23"
  census=False: problems=0
```

Not straddling is precisely what the census counts, so *"a zero pair does not straddle"* is
the reason the case **is** visible, not the reason it is invisible — the clause is inverted.
The census arm refuses it on any full release. What is genuinely blind is only the
`census=False` path (`--only`, a rebuild, a partial tree), which is a much narrower and much
less alarming statement than the one published in the comment. The first half of the same
comment — that `footprint == 0` with a positive `in_wsg` is caught by the ordering arm above
— is correct.

### F7 — **[bug]** `scripts/item_validate.py:967` and `scripts/test_pipeline.R:142` — the staged-side mitigation that comment leans on does not exist for 2 of the 5 pairs, and the arm comment says it does

The same comment continues: *"and `test_pipeline.R`'s `> 0` arms catch it on the staged
side, outside the release path."*

`test_pipeline.R` has positivity arms for three of the five pairs only — `:137-139`,
`floodplain_ff02/04/06_km2 > 0`. For the change pairs the arms are
`!is.null(meta$gross_loss_ha)` (`:141`), `footprint >= in_wsg` (`:153-156`) and the net
identity (`:162-166`). All of them pass for `gross_loss_footprint_ha == gross_loss_ha == 0`
(measured in R: `TRUE TRUE TRUE TRUE`), because `isTRUE(0 >= 0)` is `TRUE` and
`|(0 − 0) − 0| ≤ 0.15`. There is no `> 0` arm on any of the six `*_footprint_*` figures
either, in either scope.

And the arm's own comment, new on this branch in `b4cd317`, misdescribes it:

> `# The footprint scope (#98). Positive AND at least its in_wsg sibling: …`

The arms it introduces are `>=` only. Nothing in that block tests positivity. So across four
rounds the branch has carried a comment claiming a check that was never written, and round 4
then cited that comment as the reason a gap could be left unguarded.

### F8 — **[fragile]** `scripts/item_validate.py:1049-1051` — `TRANSITION_COLUMNS` did not grow with the claim this very commit grew: a fourth instance, not a third

`e42ca5e` added `in_fire_prior` to the published transition description (`:498-501`):

> *"but NOT for `in_fire`, `in_harvest` or `in_fire_prior`, which it does not carry, so for
> **those three** the patch flag is all there is."*

"The patch flag" asserts the column exists on the patches — and it does, measured on all 23
items in both transition layers. `TRANSITION_COLUMNS` was not extended, although the comment
directly above `GPKG_BASE_COLUMNS` (`:1023-1028`) states the rule the commit message itself
quotes: *"if a description grows a column name, it grows here."* The commit message counts
this class to three in this issue; adding `in_fire_prior` to the claim and not to the map is
the fourth.

Three further column names the two descriptions now depend on and the map does not cover
(all present on all 23, so this is coverage rather than data): `area_ha`, `from_class` and
`to_class` on the transition layers — the transition description says the headline figures
*"are sums of `area_ha` over its TRUE rows … under the `from_class`/`to_class` filters
above"* — and a land-cover class column on `composition_*`, which the landcover
description's *"For an AREA by land-cover class … read the `composition_*` table"* requires.

`COMPOSITION_COLUMNS` itself is exact: `("in_floodplain", "in_open_water", "in_wetland",
"in_alr", "status", "ha")` plus `GPKG_BASE_COLUMNS`' `in_wsg` is neither more nor less than
the flags and fields the landcover description names, and it over-claims nothing.

### F9 — **[fragile]** `CLAUDE.md:435-436` and `NEWS.md:59-60` — the sentence written to state the method quotes the **other** method's numbers

> *"The other two flood factors differ by 505.82 (ff02) and 528.90 (ff06) km2, so the figure
> is a property of ff04 and not of 'a pair'."*

505.82 and 528.90 are the sums of the **published per-item UTM** differences. The paragraph's
whole point is that 519.16 is a BC-Albers geometry measurement and 519.08 is the UTM sum, so
it compares an Albers figure against two UTM ones in the sentence that distinguishes them.
Measured the way 519.16 was (`st_transform(3005)`, over the staged `all_ff02`/`all_ff06`
layers): ff02 **505.80**, ff04 519.16, ff06 **528.88**.

The spread between the two definitions is 0.02 km² against a 13 km² separation between flood
factors, so the **conclusion survives** — this is the shape of the error, not a wrong number.
Quote 505.80 / 528.88, or say the two are the published UTM sums.

### F10 — **[fragile]** `CLAUDE.md:437` — the round-4 insertion left a sentence with no antecedent, on a 132-character line

The new paragraph ends *"Stating the method is the remedy a withdrawn measurement in this
same issue earned."* and the pre-existing sentence was concatenated onto that same line:
*"The opposite directions are the part worth writing down, because it is the reason two
functions read them rather than one: …"*. "The opposite directions" now resolves to nothing
in its own paragraph — its antecedent is *"the two families moved in opposite directions"* two
paragraphs up at `:417`. The line is 132 characters where the rest of the file wraps at ~94,
which is the artefact that shows the join was accidental.

### F11 — **[fragile]** `README.Rmd:59-73` — the fetch overwrites two **tracked** artifacts before the version guard can refuse, and the guard's own error message tells a human to run it

Under `params$update_query = TRUE` against a catalogue still below 2.1.0, `fp_readme_fetch()`
and `fp_readme_fig()` run first: `saveRDS(..., CACHE)` overwrites `data/readme_items.rds`
(tracked — negated in `.gitignore`) and `fp_readme_fig()` overwrites `fig/coverage.png`
(committed). Only then does the new guard read `cached$version` and abort. So a human who
runs release step 6 before the release has published — which is exactly what the guard's
message prescribes, and the one mistake it exists to catch — loses the committed cache and
figure to a run that then reports a stop. Recoverable from git, but the failure leaves a dirty
tree and the old guard's "aborts every render" defect means this path has never been exercised
cleanly.

The guard cannot simply move above the fetch (the fetch is what produces the version), but the
same comparison can be applied to `res$version` **before** `saveRDS()` and `fp_readme_fig()`.

---

## Checked and clean, with the measurement

These are the round-4 claims that re-derive exactly. Recorded so round 6 does not re-run them.

**The README cache-vintage guard (brief item 1) is correct.** Proved by mutation on synthetic
caches, not by reading: it fires on `"2.0.1"`, `"2.0.10"` and `NULL` (message *"…version
<none>…"*) and passes on `"2.1.0"`, `"2.1.1"`, `"3.0.0"`, `"10.0.0"`. `cached` is assigned at
`:73`, one line above its first use, and nothing else in `README.Rmd` or
`readme_functions.R` reads `CACHE` (the only references are `:16` in `readme_functions.R` and
`:67/70/71/73/93` in `README.Rmd`). `package_version()` can raise only on a non-`X.Y.Z`
string, which `collection_version.py`'s `SEMVER` refuses to stamp and `fp_readme_fetch()`
refuses to cache empty — and it raises, so it fails closed. The literal matches the release:
`NEWS.md:28` is `## v2.1.0 (unreleased)`.

Round 4's diagnosis of its own round-3 guard is confirmed on the artifact: the committed
cache carries `version = "2.0.1"` and `props` with 13 columns — `id, wsg, region, species,
scenario, flood_factor, floodplain_ff02/04/06_km2, gross_loss_ha, gross_gain_ha, net_ha,
deprecated` — and no `*_footprint_*` column, so the old test was `FALSE` for the only cache
that exists.

**The composition claim's other clauses (brief item 2), on all 23.** The column list is
byte-identical on every item: `fid, from_code, to_code, from_class, to_class, status,
in_floodplain, in_wsg, in_wetland, in_alr, in_open_water, cells, ha, wsg, species, scenario`.
`in_floodplain` and `in_wsg` hold `{0, 1}` as integers; `status` holds exactly
`{change, sieved, stable}`. All 23 items carry a `composition_*` table, registered
`attributes`.

**"Three" is right (brief item 3).** The transition patches carry seven `in_*` flags —
`in_wsg, in_fire, in_harvest, in_wetland, in_alr, in_open_water, in_fire_prior` — and
`composition_*` carries four of them plus `in_floodplain`. The three absent from
`composition_*` are exactly `in_fire`, `in_harvest`, `in_fire_prior`, measured on all 23
items in both the `transition_vector.gpkg` and `floodplain_landcover.gpkg` copies.

**`gpkg_required_columns()`'s dispatch (brief item 4) matches only what it should.** Fifteen
distinct layer names exist across the staged tree; `startswith("transition")` matches
`transition` and `transition_all_ff04_2017_2023` and nothing else,
`startswith("composition")` matches `composition_all_ff04_2017_2023` alone, and
`patch_watercourse_*`, `classified_*`, `all_ff0N` and `all_ff04_by_blue_line_key` all fall to
`()`. The reader filters `data_type IN ('features','attributes')`, so the aspatial table is
genuinely in scope rather than silently skipped. `check_gpkg_columns` returns **0 problems**
on the build, and the whole validator passes: `uv run python scripts/item_validate.py --base
data/stac --expect 23 --expect-provenance 23` is green on every arm.

**The denominator fix (brief item 5) is right in both directions.**
`50.5831 / 10,611.3951 = 0.4766%` → 0.48% of the footprint sum;
`0.48% × 10,092.2377 = 48.44 km²`; `50.5831 / 10,092.2377 = 0.5012%`.

**The neighbour measurement reproduces to the digit** (`planning/active/neighbour-measure.R`
re-run, plus a per-item variant): outside strip **519.1574** → 519.16; covered **50.5831**
(9.7433%) → 50.58 (9.7%); nobody **468.5743** (90.2567%) → 468.57 (90.3%); union of the 23
`in_wsg` pieces **equals** their sum at **10,092.2377** → 10,092.24; footprint sum
**10,611.3951** → 10,611.40. Published ff04 difference 519.08 (brief item 6).

**Every per-item neighbour share in `NEWS.md` (brief item 7) is right.** PCEA strip
**351.9686** km² = **67.80%** of the 519.16 total, with **0.3540%** of it covered by another
item; DUNC **88.998%**, SLOC **80.934%**, WILL **67.805%**, MORR **62.853%**; excluding PCEA
the split is **29.51 / 70.49**.

**The 246-vs-269 arithmetic (brief item 8) is exact.** Walking the 23 rostered groups in
`../floodplains/data` and reading each layer's own `species`: **468** data layers in the two
source bundles, of which **246** are whole-network (`species = 'all'`) and **222** are the
retired per-species ones. The staged tree holds **269** data layers — 11 on each of the 19
three-year items and 15 on each of the 4 annual-span ones (bulk, kotl, lnth, necr) — which is
246 + one `transition_vector.gpkg` copy per item. The `CLAUDE.md` rewording is internally
consistent in both places (`:427` "the right **regional** total"; `:451` "the right total
**across the groups this collection covers**"); only the other four copies were missed (F5).

**115 footprint values, none zero** (brief item 9), across 5 pairs × 23 items — so the gap
named in that comment is unreachable on this build, as stated.

**Unrelated published figures spot-checked and correct:** PCEA's ff04 gap 41.73% → "42%",
`net_ha` −2.3 → "−2 ha", `net_footprint_ha` +54.1 → "+54 ha", outside-strip gain 67.1 → "67
ha" and loss 10.8 → "11 ha". `scripts/attribution_drift-check.py` passes.

---

## Inside a round-4 fix?

**Yes — nine of the eleven.**

| # | which round-4 fix |
|---|---|
| F1 | the `composition_*` description rewrite (F2's remedy) — the new range is the fresh claim |
| F2 | the same rewrite, applied to 2 of 4 copies of one instruction |
| F3 | the F5 method statement, applied to 3 of 4 copies — and not to the one F5 named first |
| F4 | the same, in the two `README.Rmd` copies, one of which F5 cited by line |
| F5 | the "provincial total" rewording, applied to `CLAUDE.md` and not to `NEWS.md`/`item_create.py` |
| F6 | the replacement polarity-arm comment, wrong in the opposite direction |
| F7 | the same comment's mitigation clause, plus the `b4cd317` arm comment it rests on |
| F8 | the `COMPOSITION_COLUMNS` / `in_fire_prior` fix — the claim grew, the map did not, again |
| F9 | the method-statement paragraph itself |
| F10 | the same paragraph's insertion |

F11 predates round 4 (the ordering has been there since `48d71eb`) but only became reachable
once round 4 made the guard capable of passing.

The shape is unchanged from rounds 1-4 and now has a fifth confirmation: **the claim is
rewritten, the rewrite is checked against the sentence it replaced rather than against the
artifact, and the copies that were not open in the editor keep the old text.** F1 adds a new
instance of the sampling half — a range inferred from three members of a 23-member population
that nothing then enumerated. Terminating this by enumeration rather than by another round
means, for F1-F5, grepping each claim's shape across every non-planning file and re-measuring
it per copy (as `173831c` did for the 519/51/469 triple and no later commit has done for the
others), and for F6-F8, a mutation table: one planted defect per arm, with the arm that is
supposed to catch it named, run on a copy.
