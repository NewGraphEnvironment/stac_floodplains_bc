# Review round 3 — the round-1 fixes, and the mechanism behind them

Scope: `a0b6573` (the round-1 fold-in) against `main...HEAD`, plus the **uncommitted round-2
work** that appeared in the working tree during this review (`scripts/item_validate.py`,
`scripts/item_create.py`, `scripts/year_sets-check.py` are all `M`). Everything below was
measured on this machine, not reasoned.

Suites run: `fp_provenance-check.R` → **72 assertions, 0 failed, 0 skipped**;
`stage_years-check.R` → **14, 0 failed, 0 skipped**; `year_sets-check.py` → **14, 0 failed**.

---

## Findings

### 1. [bug] `scripts/item_validate.py:1406-1425` (uncommitted) — the new whole-directory stray arm does not model the sync's own excludes

The round-2 fix widened arm (d) from "classified COGs" to "every file in the item directory",
with the message *"the release syncs the directory, so these would reach the public bucket with
nothing pointing at them"*.

That is false for three file classes, because `catalogue_release.sh` excludes them from **every**
sync — the full path at `:458` and the `--only` path at `:430`:

```
--exclude '.*' --exclude '*/.*' --exclude '*.json' --exclude '*.aux.xml'
```

and the comment two lines above `:458` records *why*: **"macOS drops .DS_Store into item dirs"**,
and *"GDAL writes PAM sidecars whenever a read triggers statistics computation … the pipeline now
makes two extra GDAL passes over these files"*. So the repo already knows both files appear.

Measured — a synthetic item with a valid 10-asset set plus `.DS_Store` and
`classified_2017.tif.aux.xml`:

```
aaa_ch_ff04: 2 file(s) in …/aaa_ch_ff04 that no asset describes
  (['.DS_Store', 'classified_2017.tif.aux.xml']) — the release syncs the directory,
  so these would reach the public bucket with nothing pointing at them
```

Consequences, in order of cost:

- A release is **refused** for a file that provably cannot ship. Opening `data/stac/<item>` in
  Finder is enough to trigger it, and the operator is told to delete something the sync already
  ignores.
- The message states something untrue about the bucket, which is the "a guard that fires
  correctly and then points at the wrong fix" row in `code-check.md`.

The new control fixture added in the same round-2 edit — `"...and a directory holding exactly its
own assets is clean"` (`year_sets-check.py:174-179`) — **cannot reach this mode**: it writes no
dotfile and no sidecar, so the fixture and the defect are structurally disjoint. That is the
"fixture that cannot reach the failure mode" mechanism arriving with the fix, as usual.

Fix shape: filter `on_disk` by the same predicate the sync uses (`name.startswith(".")`,
`name.endswith((".json", ".aux.xml"))`), and say in the message that those are excluded rather
than leaving the next reader to rediscover it. Adding the two cases to the fixture loop is what
makes the fix provable.

### 2. [fragile] `scripts/stage_years-check.R:153-156` — the pin's currency gate reads the artifact under test

```r
built <- file.path(sbx, "data", "raw", "ufra_ch_ff04", "meta.json")
stamp <- jsonlite::read_json(built)$produced_datetime
if (!identical(stamp, PIN_STAMP)) skip(DESC, "upstream re-ran ufra …")
```

`produced_datetime` is a **published field of the very file whose bytes the assertion pins**. Any
regression that moves or nulls it — a broken provenance read, a lost landcover section, a
`fp_prov_item` rename — makes `identical()` FALSE and the assertion **skips** instead of failing,
under a message that blames upstream. A guard failing toward skip, on the one arm that exists to
detect the code moving meta.json.

This is round-1 finding 2 one axis over: that fix added a second *gate*; both gates now read
values the build itself produced (the toolchain gate reads this machine, which is fine; the stamp
gate reads the artifact, which is not).

Fix: read the stamp from `$FLOODPLAINS_DATA/ufra/provenance.json` — the producer's own file, the
independent source the pin is actually gated on. `landcover.ch_ff04.run.datetime_utc` is the same
value (verified: `2026-09-03T07:16:49Z` reaches meta.json unchanged), and reading it there makes a
corrupted meta.json a FAIL rather than a SKIP.

### 3. [fragile] `scripts/stage_years-check.R:216` (and `:36-43`) — the comment justifying "no mtimes" is false, and the choice it defends leaves the one hole

> `# Size-and-path fingerprint rather than mtimes, which a read can move.`

A read moves **atime**, not mtime. Nothing in this script or in `01_stage.R` reads
`<REPO>/data` at all, so mtimes could not have been moved by a read here.

It matters because the rejected alternative is the one that closes the residual hole: paths +
sizes are identical across a **destroy-and-rebuild**. The control run stages the same `ufra`
target with the same inputs, so if it escaped its sandbox it would wipe `data/raw` + `data/stac`
and re-stage a tree with the same paths and (for a stable build) the same sizes — and the
assertion would pass. Arms (a)/(b)/(c) refuse and stage nothing, so an escape there *is* caught;
the guard is therefore sound in practice and its stated claim ("the repo's own data/ tree is
untouched by all four runs") is still wider than its predicate.

Everything else about the fix checks out: the fingerprint is captured at `:116`, before
`sandbox()` and before the first `run_in()`, and nothing above it touches `<REPO>/data`; the
`skip()` increments `SKIPPED` and prints on the summary line rather than being silently dropped;
the premise branches on the *before* value, so an escaped run that leaves `data/` absent still
fails.

### 4. [fragile] `NEWS.md:39-41` — the stated cause is wrong, though the conclusion holds

> "the two forward-only items (`mcgr_ch_ff04`, `pine_bt_ff04`, both published `deprecated: true`)
> **have no landcover section**, so it does not run for them."

Measured across `$FLOODPLAINS_DATA`: `mcgr` and `pine` have **no `provenance.json` at all** — not
a file with a missing landcover section. `fp_prov_span()` returns NULL for either state, so the
`change_interval` check is skipped either way and the bullet's conclusion is correct. But the
sentence is a claim about the producer's files, and it is not the one the files support. Same
class the fix commit corrected two bullets up: restated rather than re-derived.

(Also confirmed while checking: `logs` and `neexdzii` likewise have no landcover/no provenance,
and neither is rostered — `logs` appears in no `config/regions/*.yml`, `neexdzii` is deliberately
excluded by `skeena.yml`. So "exactly two" is right for the published set.)

### 5. [fragile] `scripts/item_create.py:8-9` (uncommitted) — the docstring attributes the year set to the wrong producer

> `assets = one classified_<yyyy> COG per year in the item's OWN span (#61, **read from the
> producer's record**)`

`item_create.py` reads `meta["years"]` (`:308`, `:491`, `:513`), which `01_stage.R:240-242`
derived from `list.files("^classified_[0-9]{4}\\.tif$")` — from **disk**. The record only checks
it, and that direction is the PR's central design decision ("never the reverse").

`CLAUDE.md:78` and `NEWS.md:21` open with the same phrasing but correct themselves within the same
paragraph ("The set that gets **published** is the one discovered on disk and the record is what
checks it, never the reverse"). This docstring stands alone and does not, so it is the one surface
where a reader is left with the inverted answer.

### 6. [fragile] `README.Rmd:133` / `README.md:41` / `index.html:12997-12998` — "the three dissolved epochs" survives in the table the branch rewrote

The same table row the branch edited to remove "Ten assets each" and
"`classified_2017` `classified_2020` `classified_2023`" still reads:

> `transition_vector` | the transition patches alone — the change layer without **the three
> dissolved epochs** that carry most of the bytes

A seven-year item has seven, and four rostered groups (`bulk`, `kotl`, `lnth`, `necr`) are already
annual upstream. Same sentence in `item_create.py:370` (a comment, so harmless, but it is the
fourth copy).

Two lines below it the branch added the paragraph that explicitly tells the reader not to assume a
count — so the page now contradicts itself within one screen.

### 7. [fragile] `CLAUDE.md` — round 1's reachability finding was fixed on one of two surfaces

Round-1 finding 3 was "neither new check script was reachable from anything", fixed by a new
`scripts/README.md` section. `CLAUDE.md` names six check scripts by filename
(`catalogue_release-check.sh`, `style_drift-check.py`, `style_determinism-check.py`,
`gpkg_determinism-check.R`, `attribution_drift-check.py`, `fp_provenance-check.R`) and does not
name `stage_years-check.R` or `year_sets-check.py`.

The argument fix 6 used for itself applies here verbatim: CLAUDE.md is "the document the next
session reads first". This is "a fix that reaches one enforcement surface reads as complete on all
of them" (`code-check.md`, ngr#7/#36).

### 8. [fragile] PR #62 body — "95 assertions across three check scripts" is not derivable

At the fix commit `a0b6573` the three scripts print **96** (72 + 14 + 10). On the current working
tree they print **100** (72 + 14 + 14, the stray-file loop being three executions of one call
site). 95 is reachable only if `fp_provenance-check.R`'s `neexdzii` pin was skipping at the moment
of writing.

Immaterial on its own; listed because it is exactly the class the fix commit corrected in NEWS.md
("grew 25 cases" → 23), left standing in the PR body one document over. The same sentence's
"each arm greping its own message" is also slightly wide: the `expect_clean` controls assert an
empty problem list, not a message.

---

## The mechanism

Round 1's seven findings are **one shape in two materials**:

> **A statement's scope is set by what it *reads*, and it drifts as soon as the statement is
> written from something other than the thing it describes.**

- In **code**, the statement is an assertion description and the reading is its predicate. Every
  round-1 code finding is a predicate narrower than the sentence above it: `dir.exists(sandbox/…)`
  under "the repo's tree was not written"; one gate under "byte-identical"; a `YEARS` double under
  a comment about what `01_stage.R` passes.
- In **prose**, the statement is a released claim and the reading is which document it came from.
  Every round-1 doc finding is a figure or sentence copied from a sibling document rather than
  re-derived: "25 cases" from a draft, `change_interval` from the absolutes list, "3 classified-year
  COGs" from a CLAUDE.md nobody re-read against the branch.

The two are the same failure because in both cases **the source of the claim is not the subject of
the claim**, and nothing in the artifact can contradict it. That is why the count matters more than
the instance: this is round 3, five of the eight findings above are still this shape, and two of
them are *inside* round-1 or round-2 fixes (findings 2 and 1).

The terminating move is not another sampling pass. It is the enumeration below: for every
assertion and every factual sentence this branch adds, name what it reads and whether that sits
**above** its source of truth (independent — can contradict) or **below** it (derived — cannot).

---

## Enumeration A — every assertion in the new code, claim vs predicate

### `scripts/stage_years-check.R` (14 executed + 2 `stopifnot` premises)

| # | description | reads | above/below | verdict |
|---|---|---|---|---|
| 1 | the unmutated tree stages the item | `grepl("STAGED ufra_ch_ff04")` | above | exact |
| 2 | …and trips none of the year-set arms | regex over 3 of `fp_years_reconcile`'s 5 messages | above | **claim wider**: `two staged rasters claim the same…` and `found N classified raster(s)` are not in the regex. Backstopped by #1 (any arm aborts the stage), so not a finding |
| 3 | meta.json byte-identical to the pre-change build | `digest(file)` vs `PIN_META_SHA256` | above | exact — **but its gate is below** (finding 2). Also: the pin was committed in `b9f6830`, *after* the code change in `9901cc2`, and the tree records no capture procedure, so a future reader cannot tell a pre-change witness from a post-change self-comparison. The live-API comparison in `findings.md` is the independent evidence; the pin's own description leans on something the repo does not carry |
| 4 | the sandbox holds the build | `dir.exists(sbx/data/stac/…)` | above | exact |
| 5,6 | premises for arm (a) | `file.exists` before/after | above | exact — mutation-took proof present |
| 7,8 | arm (a) refuses / nothing staged | exact message + `!STAGED` | above | exact |
| 9-11 | arm (b) premise + refusal | as above | above | exact |
| 12-14 | arm (c) premise + refusal | reads the record back after rewriting | above | exact — and correctly mutates the *record* copy, not the disk copy (#26's mirror) |
| 15 | the repo's own data/ tree is untouched by all four runs | path+size digest of `<REPO>/data` | above | **claim marginally wider** (finding 3): identical across a destroy-and-rebuild |

### `scripts/item_validate.py` — new/changed `problems.append`

| arm | claim | reads | verdict |
|---|---|---|---|
| fixed-key cross-item | "differs from the other items" | `max(fixed_keys, key=len)` | below the items, and **documented as such**, paired with the `EXPECTED_STYLE_ASSETS` absolute |
| classified vs literal | "are not any sanctioned year set" | `ALLOWED_YEAR_SETS` | above — a human literal, correct shape per #23 |
| unused sanctioned set | "an entry … that no item in this build uses" | `used` accumulator | above; the round-2 rewrite naming both remedy directions is a genuine improvement and is pinned as *rendered text*, which is the right assertion shape |
| **stray files (round 2)** | "these would reach the public bucket" | `item_dir.iterdir()` | **claim wider than the sync** — finding 1 |
| `--partial` partition | which arms drop | `partial` flag | above; matches the table in the PR body and the block comment at `:678-687` |

### `scripts/year_sets-check.py`

All 12 call sites grep their own needle; the two `expect_clean` controls are the exception and
correctly so. The only gap is the **control fixture's reach** (finding 1): it blesses a directory
containing exactly its assets and nothing else, which is the one shape that cannot expose the
excludes problem.

### `scripts/fp_provenance.R` new stops

`fp_prov_span`'s three-state discipline and `fp_years_reconcile`'s five arms each carry their own
message, and `fp_provenance-check.R` fires all of them plus both controls (72/0/0). The ordered
dispatch is pinned with an input that trips two arms (`:309-310`), which is the right guard for
the "ordered dispatch makes severity ordering load-bearing" class. No claim/predicate gap found.

---

## Enumeration B — every factual claim in the docs, vs the artifact

Measured, not reasoned. `✓` = re-derived from the artifact during this review.

| document | claim | verdict |
|---|---|---|
| NEWS "grew 23 assertions, to 72" | 49 → 72 `expect_*` call sites (`+3` definitions each side = the commit message's 52 → 75); script prints **72** | ✓ |
| NEWS "three absolutes … hold for every item, record or no record" | `fp_provenance.R:411-427`, all three precede `if (is.null(span_rec)) return(FALSE)` at `:428` | ✓ |
| NEWS "a fourth check … record-dependent" | correct | ✓ |
| NEWS "…the two forward-only items have no landcover section" | they have **no provenance.json** | ✗ finding 4 |
| NEWS "five [arms] at the validator" | stale-literal, `--partial` drop, arm (a), stray-file, fixed-key = 5 | ✓ |
| NEWS "since #26 landed the smoke test has been unable to validate any watershed group at all" | consistent with `check_deprecated`'s absent-ids arm and `EXPECTED_DEPRECATED` naming two; not re-run here | plausible, unverified |
| CLAUDE.md "the set that gets published is the one discovered on disk and the record is what checks it, never the reverse" | `01_stage.R:240-242` discovers; `:234` reads the record; `:248` reconciles; `meta$years` = the disk set | ✓ |
| CLAUDE.md "`ALLOWED_YEAR_SETS` in `item_validate.py`" | `item_validate.py:669` | ✓ |
| CLAUDE.md "Most items carry 2017/2020/2023" | 19 of 23 rostered items three-year, 4 annual | ✓ |
| CLAUDE.md "one COG per classified year + a transition COG, plus three GeoPackages" | matches `data/stac/ufra_ch_ff04/` (10 files, 10 assets) | ✓ |
| CLAUDE.md script inventory | omits both new check scripts | ✗ finding 7 |
| scripts/README "neither runs from `run_pipeline.sh`" | the branch's only `run_pipeline.sh` change is the `ALLOW_DRIFT_SKEW` warning | ✓ |
| scripts/README "It skips out loud with no upstream tree" | `stage_years-check.R:56-60` | ✓ |
| scripts/README "two pinned witnesses, each gated" | `PIN_STAMP` + `PIN_TOOLCHAIN` | ✓ (gate quality: finding 2) |
| README "Seven assets each, plus one per classified year" | 4 data + 3 styles = 7 fixed | ✓ |
| README "the three dissolved epochs" | contradicts the paragraph two lines below it | ✗ finding 6 |
| PR "installed drift is 0.13.0 against a recorded 0.8.0 on 18 of 22 sections" | measured: 22 landcover sections, **18 at 0.8.0, 4 at 0.13.0**; installed 0.13.0 | ✓ exact |
| PR "item_validate.py:141-155 is `EXPECTED_CITATION`" | the constant spans `:135`ff | ✓ |
| PR "all 23 rostered targets: 21 match, 2 forward-only" | 21 rostered landcover sections, every one `change_interval=[2017,2023]`, digest keys == `years`, and disk `classified_*.tif` counts equal the recorded span (7/7/7/7 for bulk·kotl·lnth·necr, 3 elsewhere) | ✓ — **no rostered target is made unstageable by this change** |
| PR "95 assertions across three check scripts" | 96 at `a0b6573`, 100 now | ✗ finding 8 |
| PR live-item comparison (10 assets, 0 fields moved) | needs network | not re-checked |
| PR "lnth carries an extra `patch_watercourse_…` table registered `data_type='attributes'`" | not re-checked | — |

---

## Fix-by-fix verdict

| round-1 fix | verdict |
|---|---|
| 1 `repo_data_fingerprint()` | works, fires, captured at the right point, skip is counted and printed. Two residuals: false comment about mtimes, and blindness to an identical rebuild (finding 3) |
| 2 `PIN_TOOLCHAIN` | `sfv[["PROJ"]]` is the right key — sf reports **both** `proj.4` (legacy) and `PROJ`, measured `GEOS 3.13.0, GDAL 3.8.5, PROJ 9.5.1`, matching the pin. A lost name errors loudly rather than pinning silently; a gained name is inert. The two skip messages are distinguishable. `jsonlite`/R number formatting is not covered, but `digits = 10` at `01_stage.R:442` bounds that exposure, and `drift` genuinely is **not** an input to meta.json (it writes `classes.json` only; `drift_version` in meta comes from the record). The real defect is the *other* gate — finding 2 |
| 3 scripts/README section | accurate; incomplete across surfaces (finding 7) |
| 4 "23 assertions, to 72" | ✓ derivable and printed |
| 5 `change_interval` paragraph | conclusion right, stated cause wrong (finding 4) |
| 6 CLAUDE.md | new paragraph is true against `01_stage.R`; no other year literal in CLAUDE.md is now false. `NEWS.md:193` ("Seven assets per item: classified_2017/_2020/_2023") is a historical release entry and correct as history |
| 7 `c(2017L, 2020L, 2023L)` | safe at all three uses — `sprintf("classified_%d.tif", YEARS)`, `fp_fold_year_digests` (via `as.character`), `real_item()`'s fallback. Script runs 72/0/0 |

---

## Note on tree state

`scripts/item_validate.py`, `scripts/item_create.py` and `scripts/year_sets-check.py` were
modified in the working tree **during** this review (round-2 fixes landing from a parallel
session). Findings 1 and 5 are against that uncommitted state; everything else is against
`a0b6573`. Nothing was edited by this review.
