# Code-check round 2 — #80 branch diff (`git diff f8003ef...HEAD`)

Reviewer: code-review subagent, 2026-10-14. Round 1's five fixes were read as the primary
subject. Every claim below was reproduced locally (R probes, `sqlite3` over
`../floodplains/data`, byte comparisons against the staged tree) before being written.

Independently re-measured first, so the findings rest on my own numbers and not the diff's:
23 rostered groups (4+3+13+3 across the four region files), no live `targets:` block in any
`area.yml`; foreign-layer groups exactly `bulk` 14 / `kisp` 9 / `morr` 25; whole-copy volume
826,941,440 B = **826.9 MB**; 18 of 23 items publish a `patch_watercourse_*` and 5 a
`composition_*`; 18 of 23 publish exactly one extra floodplain layer and it is
`<sp>_ff04_by_blue_line_key` on every one of them (no rostered item carries `_by_gnis_name`);
all 30 `attributes` layers in the catalogue live in `floodplain_landcover.gpkg` and **none** in
`floodplain.gpkg`. Every shipped prose number I could reach is right.

---

## The mechanism

Round 1's five findings are two mechanisms, not five bugs, and both are properties of what #80
*did* rather than of how it was written. #80 took work that had always been **per target,
inside the staging path** and moved it to **group scope, before the staging path** — and it
converted a **copy** into a **write**, which turned several artifacts that had been inputs into
outputs of this repo's own code.

**M1 — a statement hoisted across a control-flow boundary keeps its old reasoning about what
the boundary can still excuse.** `01_stage.R`'s group body is fenced by a per-target
`next` (`no rasters`) and by the `PARTIAL_STAGE` / `ALLOW_SKIPPED` interlock at the end of the
script. Everything #80 added sits *above* those fences. Round 1 finding **2a** (a hard `stop()`
upstream of the escape hatch) and **2b** (the claim accumulated downstream of the skip) are the
same fence crossed in the two possible directions, and finding **1** is the same shape inside
one expression: the `stop()` that was meant to report the warning sat below the point where
`gdal_utils()` unwound the frame.

**M2 — a check whose reference is produced by the thing it checks.** Converting the copy into a
write made `data/stac/<item>/floodplain*.gpkg` an *output*. Round 1 finding **3** (the test's
expectation came from `gpkg_own_layers()`, the selector) and the layer-order defect found while
chasing its minor note (`gpkg_determinism-check.R` proved the reproducibility of a byte order
the stage never writes) are the same mechanism: two readings that had to agree, where one was
derived from the other. Finding **5** (an `NA` `data_type` inflating the vector the refusal
measures) is the degenerate case — a guard measuring a population it had itself widened.

### Every place each mechanism still reaches in this diff

| place | mechanism | above or below its source of truth |
|---|---|---|
| `01_stage.R:278-296` — the two group-level `stop()` arms (`nokey`/`multi`, foreign `wsg`) | M1 | **Above.** Finding 1 below. The sibling arm three lines up was converted to a SKIP; these two were not. |
| `01_stage.R:243-250` — the two `gpkg_layer_keys()` reads themselves | M1 | **Above.** A raw GDAL read of both bundles of every rostered group, executed before the no-rasters skip. Finding 1. |
| `01_stage.R:336-358` — `own_fp`/`own_lc`/`claimed_*` | M1 | **Below** (fixed). Computed from declared targets, before the skip. Correct. |
| `01_stage.R:486-508` — the aspatial report + the `unfamiliar` cross-check | M1/M2 | **Above** its claimed scope: the report reads `keys_lc` only, while the selection covers both files. Finding 3. |
| `01_stage.R:552-569` — `missing_layers` against the staged file | M2 | **Below.** Names from `needed`, bytes from the staged copy; the two readings have different ancestors. This one is right, and it is the model the others should follow. |
| `gpkg_copy_layers():219` — `sort(unique(layers), method = "radix")` | M2 | **Below** (fixed). Verified: `sort(c("b_ff06","B_ff02","a_ff04"), method="radix")` gives `B_ff02 a_ff04 b_ff06` where the default gives `a_ff04 B_ff02 b_ff06`, so the C-locale claim holds and the published checksum no longer depends on `LC_COLLATE` or on `st_layers()` order. |
| `fp_gpkg.R:241-244` — the comment justifying the handler nesting | M1 | **Above.** The code is correct; the recorded reason for it is false. Finding 5. |
| `test_pipeline.R:395-404`, `:430-437`, `:470` — the ff-set rule, three times | M2 | **Above.** Two of the three copies already disagree. Finding 4. |
| `test_pipeline.R:440-458` — the SQL set arm | M2 | **Below** (fixed) for the selector, **above** for its own escape hatch (`next` on a missing source). Finding 6. |
| `test_pipeline.R:468-480` — the absolute floor from `meta.json` | M2 | **Below.** Correct, and the only arm in the file with no shared ancestor. |
| `test_pipeline.R:24-27` — the `source()` of `fp_gpkg.R` | M2 | **Above.** Its stated reason is the two selector functions, which the fix removed; the import and its justification survived them. Finding 4. |
| `gpkg_determinism-check.R:114-117` — layer set from the staged file | M2 | Accepted tradeoff per the brief; not re-flagged. |
| `gpkg_determinism-check.R:38-43` — the existence precondition over both files | M1 | **Below** (fixed). |

---

## Findings

### 1. [fragile] `scripts/01_stage.R:243-296` — the escape hatch round 1 restored for one arm is still bypassed by the three statements beside it

Round 1 finding 2a was that the missing-bundle `stop()` sat upstream of the no-rasters skip and
of `PARTIAL_STAGE` / `ALLOW_SKIPPED`. The fix converted **that one arm** to a group SKIP
(`:252-258`). The three statements immediately after it are in the same position and were not:

- `:249-250` — `gpkg_layer_keys(gpkg_src[["floodplain"]])` and `…[["landcover"]]`. These are raw
  `sf::st_layers()` + `st_read(query=)` reads. A bundle that exists but is truncated,
  mid-write or locked raises a bare GDAL error naming only a path, and it aborts the **whole
  roster** — including the 22 groups that would have staged.
- `:281-287` — the `nokey`/`multi` refusal.
- `:288-295` — the foreign-`wsg` refusal.

The *dispositions* (refuse, not report) are the user's decision and I am not re-litigating them.
What was never decided is their **position relative to the per-target skip**. Before #80 neither
bundle was opened until after `SKIPPED <item> — no rasters`, so a rostered group that is
un-modelled or mid-recompute cost one skip line; now it can cost the run, and
`ALLOW_SKIPPED=1` cannot reach it because the `stop()` is upstream of the marker block at
`:745-762`. The comment at `:252-257` states this reasoning explicitly for the arm above —
"before #80 these two files were only touched inside the target loop, after the no-rasters skip
— so a hard stop here would sit UPSTREAM of both" — and then three lines of hard stops follow it.

Note the asymmetry this creates with the thing the refusal is for: the `nokey` arm exists to
catch "a backfill regression stripped the key", which is a **whole-catalogue** event; the case it
actually fires on first is **one group** being half-written, where a group-scoped skip is the
proportionate answer. Cheapest fix: hoist the two reads and the two refusals inside the target
loop's post-skip region, or keep them at group scope and make the refusal a recorded SKIP of
that group the way `:252-258` now does, reserving the `stop()` for the case where *every* group
is affected.

Measured reachable today only through a corrupt/locked file: all 23 rostered groups currently
have both bundles, and 0 of 276 layers are `nokey`/`multi` (re-derived here).

### 2. [fragile] `scripts/README.md:191-195` — the premise #80 overturned is still stated, as documentation of the guard this branch changed

> "It also asserts the attribute contract: every layer of all three published GeoPackages
> carries a `wsg` column matching the item. Only `wsg` is asserted, not `species`/`scenario` —
> **the whole-WSG bundles are copied into each item dir**, so a multi-target group ships the
> other species' layers too and `wsg` is the one key invariant under that copy."

Both halves are now false: the bundles are written, not copied, and `test_pipeline.R:383-416`
asserts all three key columns. Phase 4's sweep listed `scripts/README.md:30` and `:293-294` and
updated both; this paragraph — the one that *describes the assertion the branch strengthened* —
was missed. A reader of `scripts/README.md` now concludes that `species`/`scenario` go
unchecked, which is exactly the belief #80 exists to retire, stated in the file a contributor
reads first.

This is the ninth copy of the premise, in a sweep that recorded "the premise this issue
overturned was quoted or reasoned from in nine files" — so the count in `progress.md` is right
and the enumeration behind it was one short. The lesson is the enumeration one:
`grep -n "copied whole\|whole-WSG\|verbatim\|whole copy"` over the tracked tree finds it in one
command, which is how the remaining nine were found and is what the tenth needed.

### 3. [fragile] `scripts/01_stage.R:486-491` and `CLAUDE.md:62-65` — the aspatial report covers one of the two files it is claimed to cover

`CLAUDE.md` states the hole and the cover in one sentence:

> "What still has no cover is a **new** aspatial family: the 'matches no style rule' refusal
> runs after the `features` filter, so one would ship undescribed — which is why `01_stage.R`
> names the aspatial tables it staged, per item, on every run."

The report reads `keys_lc` only:

```r
aspatial <- keys_lc$layer[keys_lc$layer %in% own_lc & keys_lc$data_type %in% "attributes"]
```

So the cover exists for `floodplain_landcover.gpkg` and not for `floodplain.gpkg`, whose layers
#80 now **selects** rather than inherits. Walk a new upstream `bt_ff04_reach_summary` table
(`data_type='attributes'`, carrying the item's key) through every surface:

| surface | verdict |
|---|---|
| `gpkg_own_layers()` | selected — it carries `(wsg, species, scenario ∈ needed)` |
| `01_stage.R:486` aspatial report | silent — reads `keys_lc`, not `keys_fp` |
| `01_stage.R:498-502` `unfamiliar` | silent — `^bt_ff[0-9]{2}` is unanchored at the end, so `bt_ff04_reach_summary` is "a known family" |
| `04_gpkg_style.py:117-126` | invisible — `WHERE c.data_type = 'features'` |
| `04_gpkg_style.py:132-138` "no style rule" | unreachable — runs after that filter, and `floodplain.gpkg`'s rule is a catch-all anyway |
| `item_validate.check_layer_styles:1620` | invisible — same `data_type='features'` filter |
| `test_pipeline.R` | asserts its key, says nothing about it being undescribed |

Published, unstyled, unreported, undescribed — the precise state `CLAUDE.md` says is covered.
Latent today and verified so: all 30 `attributes` layers in the catalogue are in
`floodplain_landcover.gpkg`, 0 in `floodplain.gpkg`. That is also why the arm looked complete —
it was written against the file where the population lives, and the selection it guards now
covers a second file where the population is empty. Same reasoning as the `nokey` arm beside it,
which does iterate both files (`for (nm in names(gpkg_src))`), so the idiom for fixing it is
already in the function.

Also worth noting while the subject is open: the `unfamiliar` cross-check is the *only* cover
`CLAUDE.md` claims for a new **feature** family in `floodplain.gpkg`, and a prefix test that
`<sp>_ff0N<anything>` satisfies is a thin one. Anchoring it
(`^<sp>_ff(02|04|06)(_by_[a-z_]+)?$`) would make the claim true; widening it is what keeps
`_by_blue_line_key` passing, so the anchor has to name the known suffixes rather than drop.

### 4. [fragile] `scripts/test_pipeline.R:395-404`, `:430-437`, `:470` and `:24-27` — the ff-set rule is implemented three times in one file, and two of the copies already disagree

Round 1 finding 3 was that the expectation came from `gpkg_own_layers()`. The fix re-derived it
in SQL — correctly — but it re-derived the *scenario-set rule* beside it, and that rule now
exists three times in `test_pipeline.R` alone:

```r
# :398  (per-layer arm, inline)
want_scen <- if (gp == "floodplain.gpkg") unique(c(meta$scenario, paste0(sub("_ff.*$","",meta$scenario), "_ff", c("02","04","06")))) else meta$scenario
# :431  (set arm, as a function)
want_scen_for <- function(gp) { ... identical body ... }
# :470  (floor arm, third time)
floor_fp <- paste0(sub("_ff.*$", "", meta$scenario), "_ff", c("02", "04", "06"))
```

`want_scen_for()` is defined *after* the arm that computes the same thing inline and is not used
by it. And the two copies have already drifted on one axis:

| arm | `wsg` comparison |
|---|---|
| `01_stage.R` selector (`gpkg_own_layers`) | `toupper(keys$wsg) == toupper(wsg)` — case-folded |
| `test_pipeline.R:441-452` set arm | `identical(toupper(k$wsg[1]), toupper(meta$wsg))` — case-folded |
| `test_pipeline.R:410` per-layer arm | `identical(k$wsg[1], meta$wsg)` — **case-sensitive** |

So an upstream backfill that wrote `wsg = 'larl'` instead of `'LARL'` is selected by the stage,
accepted by the set arm, and **refused by the per-layer arm**, which would report it as "a
published GeoPackage must hold only its own item's layers (#80)" — a red naming the wrong
defect. That is not fatal (it fails safe), but it is the two-lists-that-agree mechanism already
showing as two-lists-that-don't, in the file the fix was written into.

Related, same mechanism: `:24-27` still carries

```r
# Explicit for the same reason (#80): the layer-set arm calls gpkg_layer_keys() and
# gpkg_own_layers(), and relying on 01_stage.R having sourced them would make this test
# pass or fail on whether an earlier block happened to run.
source(file.path("scripts", "fp_gpkg.R"))
```

Verified: `test_pipeline.R` calls neither function, nor `gpkg_pin_date()`, `GPKG_EPOCH`,
`gpkg_write_layer()` or `gpkg_extract_layer()`. The `source()` is dead and its comment advertises
exactly the coupling round 1 removed — so the next person tightening this test has a standing
invitation to reach for the selector again. Drop the `source()` and the comment, or keep the
`source()` and say what it is for.

Cheapest fix for the triplication: one `want_scen_for(gp)` defined before the per-layer loop and
called by all three arms — noting that the floor arm must keep deriving its *names* from
`meta$years` and `meta$scenario` independently, which it does; only the ff-set expression is
shared.

### 5. [fragile] `scripts/fp_gpkg.R:241-244` — the fix for round 1 finding 1 records a false reason for itself, and cites the wrong convention rule

```r
# Flag-then-raise rather than a stop() inside the handler: the warning comes up through sf's
# C++ frames, and aborting from the handler longjmps past their destructors. The tryCatch is
# INSIDE withCallingHandlers so the warning is seen before the error unwinds; nesting them
# the other way loses it (code-check-r.md, "tryCatch() nests its handlers").
```

The first sentence is right. The second and third are not. Measured:

```
f <- function() { warning("W1"); stop("E1") }
withCallingHandlers(tryCatch(f(), error=…), warning=…)   ->  warn= W1  err= E1
tryCatch(withCallingHandlers(f(), warning=…), error=…)   ->  warn= W1  err= E1
```

Both nestings capture both conditions. A `withCallingHandlers(warning=)` established anywhere up
the stack from the `warning()` call runs before the later `stop()` is signalled, so the order of
the two wrappers is immaterial here. The round-1 defect was **not** nesting order — it was that
the `stop()` sat *after* `gdal_utils()` in the same frame the raise unwound, which is the M1
shape, and the fix (capture the error too) is the right fix for it.

`code-check-r.md`'s "`tryCatch()` nests its handlers, so a `stop()` in one is caught by a later
one" is about raising from inside a `tryCatch` handler — a different hazard, and the one the
*first* sentence of the comment is really guarding against. Citing it for the nesting claim
attaches a convention rule to a false statement, which is the shape that makes wrong rules
travel. Keep the first sentence, delete the second and third, or replace them with the measured
fact: "the capture must survive the raise, which is why the error is caught rather than reported
after the call."

### 6. [fragile] `scripts/test_pipeline.R:441-442` — the set arm disables itself silently

```r
src_gpkg <- file.path(fp_data, meta$wsg_lower, gp)
if (!file.exists(src_gpkg)) next
```

This is the arm that round 1 finding 3 was about, and the one arm that can see a *lost* layer
family against an independent reference. A missing source file turns it off with no message, so
a green `test_pipeline.R` does not distinguish "the staged set matches the source" from "the
source was not there". Everything else in this file reads `$FLOODPLAINS_DATA` unguarded
(`:101` reads `config/<wsg>/area.yml` from `dirname(fp_data)` and `:253` reads
`provenance.json`), so the guard is not buying portability — it is only removing the voice. The
determinism check solved the identical problem four files over and did it out loud
(`gpkg_determinism-check.R:101`, `upstream_skipped` + the `NOT PROVEN` line): `message()` the
skip, or drop the guard and let the arm fail where the rest of the file already would.

### 7. [low] `scripts/fp_gpkg.R:118-120` — the new precondition names the wrong table

```r
layers <- sf::st_layers(src)$name
if (!length(layers)) stop("gpkg_layer_keys: ", src, " declares no layers in gpkg_contents", …)
```

`layers` comes from `st_layers()`, which lists tables **irrespective** of `gpkg_contents` — the
whole reason `data_type` is read separately eight lines down, and verified here: on a styled
file `st_layers()` returns `layer_styles`, which has no `gpkg_contents` row. So the one case this
precondition fires on is "GDAL sees no tables at all", and the message sends the operator to a
table that is not the subject. The precondition was added because the raw error "named neither
the file nor the condition"; it names the file and mis-names the condition. `"declares no
layers"` alone is correct and sufficient.

---

## Claims in the planning files the code or the tree does not support

The brief asked for these specifically. None changes shipped behaviour; all four are
evidence-record defects, and the first two are the kind that make a later session believe a path
was exercised when it was not.

1. **`progress.md`, round-1 table, row 2a** — "full run, one group's bundle removed:
   `PARTIAL_STAGE written — 22 target(s) skipped`". For a full-roster run with **one** group's
   bundle removed the code appends one entry to `skipped` (`01_stage.R:255`, the group name, not
   its targets) and `:757` prints `PARTIAL_STAGE written — 1 target(s) skipped`. `22` is
   self-consistent with a *one-group* data tree (22 groups missing both bundles, 1 staged), which
   is a different mutation from the one described. So the quoted string does not demonstrate what
   the row claims it demonstrates — the proof that the restored escape hatch is reachable on a
   full roster still needs taking. (Worth re-taking rather than reasoning about: the fix itself
   looks right.)

2. **`progress.md`, "A second defect came out of chasing…"** — "The determinism arms' md5s now
   equal the staged files' md5s exactly (`7152a8bde62f…`, `c74432f94f21…`)". That holds only
   against a tree that has not reached step 04. Measured here on `larl_bt_ff04`:

   | file | md5 | bytes |
   |---|---|---|
   | fresh `gpkg_copy_layers(upstream, …, c(bt_ff02, bt_ff04, bt_ff06))` | `846f3700cef306cf…` | 2,691,072 |
   | `data/stac/larl_bt_ff04/floodplain.gpkg` (staged **and styled**) | `ea5791b48af00ed4…` | 2,707,456 |

   `04_gpkg_style.py` adds `layer_styles` to all three bundles after staging, so the published
   asset's `file:checksum` is the styled file's and the determinism arm's md5 is the pre-style
   writer's. Nothing is broken — `style_determinism-check.py` pins the styling step and
   `gpkg_determinism-check.R` pins the writer — but as written the sentence invites the belief
   that this one check pins the published checksum of both bundles, and it does not. "equal the
   md5s of the staged files before step 04" is the true form.

3. **`findings.md` ("Size effect") and `task_plan.md` ("What was measured")** — "the 21 groups
   with no foreign layers" / "the other 21 rostered groups have none". 23 rostered − 3 = **20**.
   21 is the count over the 24 upstream *area dirs* (which includes the unrostered `neexdzii`),
   and in a sentence about "every item's `file:checksum`" only rostered groups have items.
   `NEWS.md` has 20, which is the shipped number and is right.

4. **The working `data/` tree still carries round 1's planted mutation.** `data/raw/larl_bt_ff04/meta.json`
   has `years = [2017, 2020, 2023]` and all three `classified_*.tif` are staged, while
   `data/stac/larl_bt_ff04/floodplain_landcover.gpkg` holds only `classified_bt_ff04_2017` and
   `classified_bt_ff04_2023` — i.e. the state the round-1 table describes as "selector made to
   drop every `classified_*` … the floor arm fires". The upstream source has all three, so the
   mutation was reverted there and not in the build tree. `data/` is gitignored so nothing ships,
   but the next `test_pipeline.R` or `item_validate.py` run against this tree without a re-stage
   goes red on somebody else's planted defect (`code-check.md`, "Restore the bug and prove the
   guard fires" — the restore is the second half). One `Rscript scripts/01_stage.R` clears it.

---

## Minor notes (not findings)

- `scripts/01_stage.R:486` / `:498` — the selection population (`st_layers()`, via
  `gpkg_layer_keys()`) is wider than **every** verification population in the repo
  (`gpkg_contents WHERE data_type IN ('features','attributes')` in `test_pipeline.R:376`,
  `gpkg_determinism-check.R:116`; `= 'features'` in `04_gpkg_style.py:126` and
  `item_validate.py:1620`). A layer in that gap — registered in no `gpkg_contents` row but
  carrying all three key columns — is selected, published, and excluded identically by all four
  checks, so nothing disagrees. Round 1 finding 4 made the *guards* NA-safe; the *selection* is
  still NA-blind. Exotic (verified: `layer_styles`, the one real instance of an unregistered
  table, lacks the key columns and so lands in `nokey` and refuses), and GDAL writes a
  `gpkg_contents` row for whatever it translates, so the staged copy self-heals. Mentioned only
  because it is the same axis as finding 4 and costs one `%in%` to close in
  `gpkg_own_layers()`.
- `scripts/fp_gpkg.R:193-195` — "a caller that swapped the arguments would delete upstream data".
  `stage_years-check.R:171` symlinks the producer's files, and `unlink()` removes a symlink, not
  its target, so the stated blast radius is one link. The warning is still worth having; its
  consequence is overstated.
- `README.Rmd:130` — the `floodplain` asset is "the delineated floodplain at three flood
  factors", while 18 of 23 items ship four layers (measured). `item_create.py:427-431` was
  corrected for exactly this in round 1's minor notes; the public landing page was not. Arguably
  fine as a description of flood factors rather than layers.
- `scripts/item_create.py:428-430` — "the producer's per-blue-line-key breakdown of **the
  headline scenario**". The selection keys `floodplain.gpkg` on the item's whole ff set, so an
  item whose headline is `ff06` would also publish an `ff04`-keyed `_by_blue_line_key` layer and
  the description would be wrong for it. Inert today: every rostered item's
  `primary_scenario` is `*_ff04` and every extra layer measured is `<sp>_ff04_by_blue_line_key`.
- `scripts/catalogue_release.sh:481` — "LCHL's `floodplain.gpkg` is byte-identical in size to its
  S3 copy" survives #80 (LCHL is rostered, and a deterministic rebuild reproduces the size), so
  the `--size-only` reasoning still stands. Checked rather than assumed, since it is one more
  place `floodplain.gpkg` is reasoned about.

## Checked and correct

- `sort(method = "radix")` on character: accepted by `sort.default`, and verified C-locale
  (`B_ff02 a_ff04 b_ff06` vs the default's `a_ff04 B_ff02 b_ff06`). The sort is inside the writer,
  so no caller can reintroduce the order dependency, and the `setequal()` backstop compares
  against the sorted-unique set it actually wrote.
- `gpkg_own_layers()`: `ok` leads the `&` chain, so `FALSE & NA` is `FALSE` and no `NA` reaches
  `keys$layer[hit]`; `keys$scenario %in% scenarios` is `FALSE` not `NA` for an `NA` scenario.
- Round 1 finding 4's fix: `%in% "features"` / `%in% "attributes"` at `01_stage.R:470` and `:486`
  both remove the `x[c(TRUE, NA)]` NA element. No remaining `== "features"` on a `match()`-filled
  column anywhere in the diff.
- `stop(..., if (length(x)) paste0(...))` at `01_stage.R:556-565` — the `NULL` from a `FALSE` `if`
  is dropped by `stop()`, verified in the diff's own style and consistent with round 1.
- `$` is exact on every list/data.frame access added (`sel$f/own/keys/want`, `r$label/source/md5_a/md5_b/size`,
  `f$gp/want`, `k$wsg/species/scenario`, `meta$wsg_lower`, `dt$data_type`); no name in any of
  those lists is a prefix of another.
- `gpkg_determinism-check.R:119-124` — the `local({ u <- up; l <- layers; … })` capture avoids the
  lazy-loop-variable trap, and `results[[length(results) + 1L]] <<- …` resolves `results` in the
  global frame with the index evaluated locally. The `NO_PIN` arm's `any(same)` is the right
  direction (every arm must differ) and `!all(same)` the right one for the warm path; both degrade
  correctly to one arm when `$FLOODPLAINS_DATA` is absent, and the skip is printed unconditionally
  at `:135-137` so the cold path's verdict is not silently narrowed.
- `test_pipeline.R` floor arm: `unlist(meta$years)` on a `read_json` list gives an integer vector
  and `sprintf("%s", 2017L)` is `"2017"`; `meta$transition_span[[1]]` / `[[2]]` are scalars. The
  `sprintf` zero-length trap (`sprintf("c_%s_%s","s",integer(0))` is `character(0)`, verified)
  cannot fire because `years` is non-empty by the time `meta.json` is written.
- `keyed_layers()` excludes `layer_styles` structurally — verified on the styled staged file that
  `layer_styles` gets no `gpkg_contents` row while all three real layers do — so the filter change
  is a strengthening, as the comment claims, and the `if (!length(lyrs)) stop(...)` vacuity guard
  survived the rewrite.
- `04_gpkg_style.py`, `item_validate.check_layer_styles` and `style_determinism-check.py` are all
  unaffected by the aspatial tables (`data_type='features'` filters, all three bundles in
  `GPKGS`/`STYLED_GPKGS`), matching `CLAUDE.md`'s claim.
- No assertion reads an asset `title` or `description`, so `item_create.py`'s two new
  descriptions are inert on every gate; `item_create.py:600-630`'s asset lists name the two
  bundles by filename only and do not care what is inside them.
- Shipped prose numbers re-derived independently and all correct: 826.9 → 643 MB, 184 MB,
  MORR −70% (116.3 → 35.4), BULK −36% (169.0 → 107.8), KISP −35% (57.2 → 37.1), 18/5 aspatial,
  18 of 23 `_by_blue_line_key`, 3 foreign-layer groups, 20 groups unaffected by foreign layers,
  "three or four" floodplain layers per published item.
