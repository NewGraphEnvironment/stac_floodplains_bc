# Findings — Produce the provenance floor and census numbers (#82)

## Planning measurement, 2026-10-15

Taken with a throwaway probe in the session scratchpad, driving this repo's own reader over the
roster (the shape `scripts/prov_census-measure.R` ships). Producer tree `floodplains` at
`v0.1.13-3-g760b8d9-dirty`:

```
rostered groups: 23
targets walked: 23   carrying any: 20
  link_run_uid           18
  link_config_sha256     19
  link_sha               19
  link_version           20
  flooded_version        20
  drift_version          20
  produced_datetime      20
  landcover_source       20
  landcover_collection   20
  landcover_stac_url     20
  landcover_key          20
  landcover_item_hash    20
would-not-stage (3): kotl_all_ff04, larl_all_ff04, sloc_all_ff04   [no classified rasters]
```

Not pasted into any literal: DUNC could not publish while floodplains#133 held, so a release cut
from this tree would have failed one step earlier and these numbers would have encoded a broken
record as the expectation (#75, CLAUDE.md). **That cleared at 18:38Z the same day** — the series
and the correction are further down this file; the decision not to re-take the literals stands on
its own reason, which is that they are re-taken on the build a release is cut from.

## The skip-before-read order is the build's, and the issue's spec is not

The issue specs the walk as roster -> targets -> `fp_prov_item()`. Walked that way on today's
tree, **three targets raise rather than count**: `kotl`/`larl`/`sloc` declare
`primary_scenario: all_ff04` while their `provenance.json` holds only `bt_ff02/04/06`, so
`fp_prov_sections()` refuses with "the floodplain section has no 'all_ff04' key". Under the
issue's refusal rule that prints no census at all — on a tree where a build is perfectly happy.

`01_stage.R` does not reach the reader for those targets: the `no rasters at <dir>` skip
(`01_stage.R:375-379`) sits **above** the first `fp_prov_*` call (`:396`). So the measure script
applies the same order, and the refusal then covers only targets that would actually stage —
which is the direction that matters, since the number it prints becomes a release gate.

## What makes a build stage fewer items than the roster declares

Checked against `01_stage.R` so the script can say what it does not cover:

| 01_stage.R | measure script |
|---|---|
| no `config/<wsg>/area.yml` -> group skipped (`:207`) | mirrored |
| `floodplain.gpkg` or `floodplain_landcover.gpkg` absent -> group skipped (`:250`) | mirrored (existence only) |
| either bundle unreadable -> group skipped (`:266`) | **not** mirrored — needs a GDAL read of every layer |
| a layer with no usable key, or another group's -> **stop** (`:281-312`) | not mirrored; stops the build loudly |
| no `rasters/<scenario>/` -> target skipped (`:375`) | mirrored, plus "no classified raster in it" |
| `fp_years_reconcile()` mismatch -> **stop** (`:410`) | not mirrored; needs `TRANSITION_SPAN` too |
| `fp_prov_rasters_current()` mtime -> **stop** (`:422`) | mirrored — it is the mid-write state the issue's caveat names |
| `WSG_ONLY` -> one group | not applicable: no argument, the whole roster every time |

Every unmirrored row makes the build stage *fewer* items or stop outright, so the script's count
can only ever be at or above what such a build publishes — and both of those are loud.

## Phase 2 — the refusal, proven in a sandbox

No check script ships for it (#82 asks for a measurement, and a check for the measurement is not
what it asks for), so the arms were driven by hand and are reproducible from here. Sandbox shape
is `stage_years-check.R:159-190`'s, minus its cwd games — one group, a synthetic region yml, the
real `area.yml` and `provenance.json` copied, bundles and rasters symlinked (the mtime guard
follows a symlink to the producer's file, which is older than the record, so the control passes):

```bash
SBX=$(mktemp -d)/sbx
mkdir -p "$SBX/src/config/regions" "$SBX/src/config/bulk" "$SBX/src/data/bulk/rasters/all_ff04"
printf 'region: skeena\nwatershed_groups: [BULK]\n' > "$SBX/src/config/regions/test.yml"
cp ../floodplains/config/bulk/area.yml       "$SBX/src/config/bulk/area.yml"
cp ../floodplains/data/bulk/provenance.json  "$SBX/src/data/bulk/provenance.json"
for f in floodplain.gpkg floodplain_landcover.gpkg; do
  ln -s "$PWD/../floodplains/data/bulk/$f" "$SBX/src/data/bulk/$f"; done
for f in ../floodplains/data/bulk/rasters/all_ff04/*; do
  ln -s "$PWD/$f" "$SBX/src/data/bulk/rasters/all_ff04/$(basename "$f")"; done
FLOODPLAINS_DATA="$SBX/src/data" Rscript scripts/prov_census-measure.R
```

| arm | mutation | result |
|---|---|---|
| control | none | exit 0, census of 1 item, all twelve fields |
| unreadable record | `provenance.json` truncated to invalid JSON | exit 1, **no census**, names BULK and jsonlite's own lexical error |
| schema moved | `schema_version` -> 3 | exit 1, no census, "declares schema_version 3 but this reader implements 2" |
| mid-write | one `classified_*.tif` replaced by a file newer than the landcover run stamp | exit 1, no census, `fp_prov_rasters_current()`'s own message |
| forward-only control | `provenance.json` removed | **exit 0**, census prints, 1 item with none at all, floor 0 — the legitimate absence, not a failure |
| group skip | one bundle removed | group skipped by name, and then the zero-staged refusal below |
| no roster | `area.yml` removed | group reported as declaring no targets, then the same refusal |

Each refusal was told apart by its own message, never by the exit status: six arms share exit 1,
and only the message says which fired.

**A guard added here, not in the plan.** The group-skip and no-roster arms printed
`PROVENANCE_FLOOR=0` and exited 0 — a census of nothing, in the shape of an answer. 0 is the one
value every presence check in the publish path waves through, and it was true of v1.0.0, so it
cannot be told from a measurement that worked. Nothing staged is now its own refusal, naming the
resolved `$FLOODPLAINS_DATA`: the same stance `item_validate.py` takes on a wrong `--base` rather
than reporting `valid: 0` and exiting 0.

## Plan review (Plan agent, unnamed, returned 14 min after spawn)

Findings verified before acting, both directions. Three were load-bearing:

**1. The staged census and the published one differ by construction, in one place — and today's
tree cannot build.** `link_version` and `link_sha` publish as one `processing:software` entry, so
`prov_present()` (`item_validate.py:604-613`) reads both from that single value, and
`item_create.py:506-521` **raises** `SystemExit` on a half-present entry rather than writing
`+<sha>`. Verified against the record: `data/dunc/provenance.json` carries
`inputs.link.version: 0.50.0` with `link_log: null` (`link_log_note: "no log row for DUNC in
schema 'fresh'"`), so DUNC stages `link_version` with a value and `link_sha` null. DUNC stages —
config in `columbia.yml`, both bundles, seven classified rasters — so **`run_pipeline.sh` aborts
on `dunc_all_ff04`, whichever region a release is for**. #89's "DUNC is not a gate" is true of
the catalogue and false of the build; its body is corrected. The pairing is asserted in
`prov_fields-check.py`, where `PROV_SOFTWARE` lives, rather than copied into R.

**2. `!length(years)` was swallowing a build abort.** `01_stage.R:375` skips only when the
raster *directory* is absent. A directory holding none or one `classified_*.tif` reaches
`fp_years_reconcile()` at `:410`, which stops — and `01_stage.R` has no per-area `tryCatch`, so
the build stops. The draft treated that as a skip, which is the dangerous direction the script
exists to argue against: a census for a tree that cannot build. Split: `!dir.exists()` is the
skip, anything else goes to the reader arms. (Today both coincide — none of the three skipped
groups has an `all_ff04` raster directory at all.)

**3. `fp_prov_span()` was never called**, so six enumerable build-abort states were invisible and
the "year set taken from disk, unchecked" count was not produced. Now called in the build's own
order (`span -> years -> reconcile -> rasters_current -> item`), which also means the first
refusal an operator sees is the one the build would show them. `TRANSITION_SPAN` is parsed out of
`01_stage.R` by the same helper as `PROV_FIELDS`, never copied.

Also accepted: the paste block moved to column 0 (an indented `PROV_CENSUS = {` is an
`IndentationError` to `prov_fields-check.py`'s `literal()`, and the floor is grepped with an
anchored `^PROVENANCE_FLOOR=`); group-level skips and failures now name their target ids and
feed a per-item accounting identity asserted before any number prints; `WSG_ONLY` refuses
outright, since it would stage one group against a full-roster census; a region file with no
`region:` is a recorded failure, as it stops the build; `git rev-parse --short HEAD` beside
`describe`, which yields no sha when HEAD is on a tag; the `ALLOW_SKIPPED` banner no longer
over-promises (it waives the `PARTIAL_STAGE` marker and nothing else — not step 0's refusal of a
build missing a live item).

Declined, each named in the script: reading the GeoPackages' layer keys (needs `sf`/GDAL, the
dependency separating "runs where a build cannot" from "needs the build env" — 0.6 s for BULK's
two bundles, so it is affordable and still the wrong trade); comparing `drift_version` against
the installed `drift` (needs `drift`); deriving `prov_fields-check.py`'s fixture from
`PROV_CENSUS` (the user chose otherwise at the plan gate, and it would make that file's census
arm assert the literal against itself); per-group count accumulation (a failure discards the
census, so nothing leaks — the accounting identity covers the interim).

**One correction to the review, and one to this branch's own comment.** The review's "kotl has
`all_*` floodplain sections" and the earlier probe's "kotl's floodplain holds only `bt_*`" are
both right, 14 minutes apart: a `run_region.R columbia` run was in flight (`pgrep`: started
17:14:55Z, `run_area.R kotl 1,2,3`), and KOTL's record gained `network/all2` and
`floodplain/all_ff0*` between the two reads. The caveat the issue asked for is therefore not
hypothetical — it happened during the work. The script's header says so.

## The new arms fire (mutation table, 2026-10-15)

Run over a copy of `scripts/` so the working tree was never patched. Control: 49 assertions,
0 failed.

| mutation | arm that fired |
|---|---|
| `PROV_CENSUS["link_sha"] = 20` beside `link_version` 21 | "equal census counts" |
| `PROVENANCE_FLOOR=17` under a census of 21 | "bounds every per-field census count" |
| `PROV_FIELDS <- c(...)` appended to the measure script | "parses its literals out of 01_stage.R" |
| `prov_fields-check.py` dropped from the paste block | "...does not name [...]" |
| the raster-skip expression reworded in the measure script | "no longer share" |

## The refusal fires on the real tree, 20 minutes after the census did

Timeline, one command, same tree, no code change between the two:

| UTC | `Rscript scripts/prov_census-measure.R` |
|---|---|
| 17:37 | exit 0 — 23 rostered, 20 staged, floor 20; `kotl_all_ff04` skipped, no `rasters/all_ff04/` |
| 17:58 | **exit 1, no census** — `kotl_all_ff04`: "the landcover section has no 'all_ff04' key — it holds 'bt_ff04'" |

The `run_region.R columbia` run in flight wrote KOTL's seven `classified_*.tif` into
`rasters/all_ff04/` and has not yet stamped its landcover section (upstream writes rasters first,
stamps last — the invariant `fp_prov_rasters_current()` exists for). So the target stopped being
a skip and became a would-stage target whose record does not describe it, and a build of that
tree stops there too: `01_stage.R` calls `fp_prov_span()` with no per-area `tryCatch`.

That is the refusal doing exactly its job on producer bytes rather than in a sandbox, and it is
why the numbers above carry a timestamp. It also means the floor cannot be re-taken until the
Columbia run finishes — which is the state, not a defect.

## /code-check round 2, and the mechanism

Round 2 named the mechanism behind round 1's four findings, and it is the right one: **fidelity
to `01_stage.R` was established by enumerating the conditions the build applies and then
validating against the only producer tree that exists — a tree on which each arm's
distinguishing case is unreachable.** Every condition was individually right while its order,
its disposition and its subject went unexercised. `code-check.md`'s "a fixture that cannot reach
the failure mode", with the live tree as the fixture.

Its five findings, all reproduced before acting:

1. **[bug] The `_mirror` arm could not fire.** `area[["targets"]]` appears as a COMMENT in both
   files (`01_stage.R:222`, `prov_census-measure.R:200`) — comments whose whole purpose is to
   explain why `$` must not be used, so a regression would never delete them. Rewriting either
   file's code to `area$targets` left 49 assertions, 0 failed. This is round 1's finding 3 one
   axis over, in the sibling arm added by the same commit.
2. **[fragile] The paste-block strip was whole-line.** Deleting the `cat()` and adding a
   TRAILING `# for prov_fields-check.py` passed.
3. **[fragile] The hoist stopped one arm short.** `01_stage.R` skips a group whose bundle cannot
   be READ (`:265-275`), above the target loop, and this script does not open the bundles — so a
   target-level refusal can belong to a group the build would have skipped, and the banner
   asserted "a build of this tree stops on the first of them". Now "stops on the first of them
   or skips its group", with the consequence named in the header. Not fixed by sniffing the
   SQLite header, which would be a proxy for "GDAL can read it".
4. **[fragile] Two of 23 line citations were wrong** — `01_stage.R:338-356` for two assertions
   the first of which is at `:328`, and `fp_provenance.R:588` for a filter at `:589`.
5. **[fragile] `scripts/README.md`'s "three rostered targets ... today"** was undated, unlike the
   `CLAUDE.md` and `NEWS.md` copies, and already two.

### The fix for 1 and 2 recurred the mechanism once more

The first fix stripped whole-line comments for R and whole-line comments for shell. The shell
half was then defeated by the same trailing-comment shape the R half had just been fixed for:
`| python3 -c '...'  # was: | python3 scripts/only_preflight.py` passed the arm whose whole
subject is which of those two the release runs. So both sides now go through ONE helper,
`_code_only()`, quote-aware, with `word_start=True` for shell because `${tag#v}` appears seven
times in `catalogue_release.sh` and a naive cut would truncate real code. Unit-checked on eight
lines including both defeats and that expansion.

### Termination: the enumeration

The mechanism is "a token pinned by a text search that also appears in prose". Its candidate set
is every source-text read in `prov_fields-check.py`, which is eight, enumerated mechanically
(`grep -n "read_text()\|literal(\|_code_only(\|re.search"`), not recalled:

| arm | reads | cannot be satisfied by prose because |
|---|---|---|
| item_create.py publish map (x2) | `ast.literal_eval` of a module-level assign | AST — comments are not nodes |
| 02_raster_tag.py field list | same | same |
| only_preflight.py maps (x3) | `import` | runtime values, not text |
| the release runs the preflight module | shell text | `_code_only(word_start=True)` |
| PROVENANCE_FLOOR bounds the census | `^PROVENANCE_FLOOR=([0-9]+)$`, `re.M` | anchored: a `#` line cannot match |
| measure script parses its literals | R text | `_code_only` |
| measure script prints three destinations | R text | `_code_only` |
| the roster mirror (three expressions) | R text, both files | `_code_only` + the whole assignment, not the subscript |

Checked after: `grep -n "in _release\b\|in _measure\b"` returns nothing — no text-presence test
reads raw source any more. Six mutations fire, each on its own arm's message, control 0 failed:

| mutation | arm |
|---|---|
| `01_stage.R` code -> `area$targets` | mirror |
| measure script code -> `area$targets` | mirror |
| the anchored `classified_` pattern unanchored | mirror |
| `dir.exists(src_rasters)` removed | mirror |
| destination moved to a trailing comment | paste block |
| preflight inlined, module named only in a comment | the release runs it |

## /code-check round 3, and the third mechanism

Round 3 attacked both enumerations and neither broke. It confirmed the source-text set is
**exactly eight** (`prov_census-measure.R` reads source once, at `:94`, and only through an AST
walk), ran **14 mutations and all 14 fired**, and measured `_code_only()` over all three files it
is applied to: 0 over-strips, 0 surviving comments, the 26 surviving `#` all inside string
literals or shell parameter expansions. Its one structural limit — per-line quote reset, so a
multi-line string would mis-strip — it showed unreachable: no R line leaves a quote open, and
`catalogue_release.sh`'s 18 that do sit far from the only 400-char window a shell arm reads.

For the first mechanism it built a **38-row table from `01_stage.R` in file order**, cross-checked
by grep for every `stop(`/`stopifnot`/`SKIPPED`/`warning(`/`next` between `:130` and `:721` plus
every implicit raise from a called function, and `grep Sys.getenv` (exactly four env vars, no
fifth). Every row is mirrored, or declined with the decline named in the header, and **every
decline is in the direction where the build stages fewer items or stops outright** — which an
exact-in-both-directions literal makes loud. No miss. Both walks measured identical on the real
tree: same 23 groups, same order.

Its one finding is a **third mechanism**: an undated count about the moving upstream tree,
restated in several copies, where fixing one copy leaves the others. Round 2's finding (i) fixed
`scripts/README.md`; the script header kept the undated form, and it had already gone false.

### Enumeration for the third mechanism

Candidate set: every count or temporal claim about the upstream tree in this branch's added
prose, enumerated by grep over the diff rather than recalled —

```bash
git diff $(git merge-base origin/main HEAD)...HEAD -- scripts/ CLAUDE.md NEWS.md \
  | grep -E "^\+" | grep -inE "\btoday\b|\bthree\b|\btwo\b|\bnow\b|\bcurrent\b|kotl|larl|sloc|dunc|mcgr|pine"
```

68 hits, of which 58 are structural counts about the CODE (three literals, two of three, three
mirrored expressions) and are invariant. The ten that are claims about the tree:

| claim | verdict |
|---|---|
| script header, "three rostered targets are in exactly that state" | **stale** — dated, and the whole series given |
| script header, "DUNC is in exactly that state today" | **stale** — see below |
| script header, "every skip happens to be a target — which it is today" | de-tensed to the condition |
| script header, "the populations ... covers today" | de-tensed; it is about the fixture, not the tree |
| `prov_fields-check.py`, "DUNC is in exactly that state today" | **stale** — see below |
| `prov_fields-check.py`, "measured 2026-10-15 it is already empty" | dated already |
| `CLAUDE.md`, "the three Columbia groups still declaring all_ff04" | **stale** — dated, both ends |
| `CLAUDE.md`/`NEWS.md`, the 17:37Z census | dated already |
| `CLAUDE.md`, "a build of today's tree aborts" | **falsified during the review** — below |
| `NEWS.md`, "a build of that tree does not finish" | same |

## The tree moved five times, and falsified one of this branch's own claims

One command, one tree, five answers in 61 minutes while `run_region.R columbia` landed group by
group:

| UTC | result |
|---|---|
| 17:37 | floor 20, 20 staged, 3 skipped (`kotl`/`larl`/`sloc`) |
| 17:58 | **refusal**, no census — KOTL's rasters written, its landcover section not yet stamped |
| 18:16 | floor 21, 21 staged, 2 skipped |
| 18:33 | floor 22, 22 staged, 1 skipped |
| 18:38 | floor 23, 23 staged, none skipped; `link_run_uid` 18, the other eleven 23 |

The last one **falsified a claim this branch had written into four files and an issue body**:
that a build of the tree aborts because DUNC carries `link_version` without `link_sha`. Measured
18:38Z, `data/dunc/provenance.json`'s `network/all2` now carries a `link_log` with
`link_sha 8215d2d0…`, the pair is even at 23, and `item_create.py` no longer refuses it. The
finding was true when measured (17:37-18:16Z) and the guard it produced stays, because the state
recurs whenever upstream cannot resolve a sha — but every copy of the claim is corrected to say
when it held, and floodplains#133 carries the measurement as a comment (still open; closing it is
its owner's call). `link_log` carries no `run_uid` even now, which is the modelled
`kotl`/`larl`/`sloc` shape and is why `link_run_uid` stays at 18 — five items lack it
(`kotl`, `larl`, `sloc`, `dunc`, `mcgr`), which the script prints by name.

This is the rule about measurements carrying their timestamp, arriving as a correction to work in
flight rather than as a convention to cite.

## /code-check round 4: the third mechanism was not closed, and now is

Round 4 was scoped to the previous commit, because that commit rewrote load-bearing CLAIMS under
a tree that was still moving. Nine findings, **no bugs** — `prov_fields-check.py` stayed 49/0 and
the measure script exit 0 throughout, so no guard moved. It re-measured the tree itself
(18:42Z: unchanged at 23/23; the `peace` run had not moved it, all three Peace groups already
holding `rasters/all_ff04/`) and verified the corrected core true: the field sources, the
half-present raise, and that `run_pipeline.sh` calls `item_create.py` **once** under
`set -euo pipefail`, which is why one item's refusal aborts the whole build.

Its central point is that my enumeration of mechanism 3 was not one: it grepped **added** lines in
**three paths**, so it could not see pre-existing copies in the same files, branch-added copies
outside those paths, or the two artifacts `git diff` cannot reach at all — the PR draft and the
issue bodies. Four copies survived, three of them in the same `## Unreleased` section, so a reader
would have met 23/23-cleared, then "blocked by floodplains#133", then 17/20/20.

| finding | disposition |
|---|---|
| `README.md` "two of them an hour later" — the 11th instance, and false (2 held at +39 min, 0 at +61) | count removed; the script names them |
| "the state recurs whenever upstream cannot resolve a sha" — **falsified by 22 counterexamples** | corrected in 4 places: the condition is BOTH sources empty. Measured: all 23 `all*` sections carry `inputs$link$sha: null` and every one publishes, because the log row supplies it |
| "those four" items lack `run_uid` — it is **five** (`+mcgr`) | corrected here and in the floodplains#133 comment; the script had printed five by name two minutes earlier |
| "a build no longer aborts" is inferred, not measured | now "that arm no longer refuses", with the declined arms named |
| 4 uncorrected copies (`CLAUDE.md:238`, `NEWS.md:68`, `NEWS.md:199`, `task_plan.md`/`findings.md`) | each dated; the two `NEWS.md` ones point at the #82 entry |
| the PR draft still led with the falsified claim | rewritten before any push |
| #89 self-contradicting in three places + "seven classified rasters" (three are) | body corrected; its verified-state table kept as dated history with a pointer to the command |
| "three files and an issue body" — four files | corrected |
| "from 2026-10-14" names the first measurement, not the start (2026-10-12) | reworded to "when it was measured on" |

### Enumeration, done the way round 4 prescribed

No `^+` filter, no path list, over **every file the branch touches plus the PR draft and the
bodies of #82, #89 and #90**:

```bash
BASE=$(git merge-base origin/main HEAD)
FILES=$(git diff --name-only "$BASE"...HEAD | grep -v review-round)
gh issue view 89 --json body -q .body > /tmp/s89.md   # and 82, 90
grep -nEi 'DUNC cannot|cannot publish|is blocked|three (rostered|Columbia)|two of them|those four|state today|no longer aborts|13 of the 23' \
  $FILES /tmp/pr.md /tmp/s82.md /tmp/s89.md /tmp/s90.md
```

It found a **12th** instance the reviewer had not named either, and the most consequential of all:
`CLAUDE.md`'s own "Measured 2026-10-14, it cannot be cut yet: 13 of the 23 rostered groups declare
`all_ff04` and hold only their old species rasters" — the sentence a future agent would read to
decide whether the cutover release can happen, false as of 18:42Z. Re-measured in place.

**The structural fix, which is what closes it:** the moving numbers live in exactly two places —
the script, which prints them live, and this file, which is a dated record by construction. Every
other copy is count-free and points at the command. The final sweep returns only the two
quotations inside the table above.

## Errors Encountered

| Error | Resolution |
|-------|------------|

## Issue context

> **If we do it:** re-taking `PROVENANCE_FLOOR` and `PROV_CENSUS` before a release is one command,
> and the numbers come from the same reader the build uses.
> **If we never do:** every release re-derives them by hand or from a reviewer's measurement, and the
> literals go stale between releases with nothing to say so — which is where #75 found them.
> 
> ## Why
> 
> `PROVENANCE_FLOOR` (`catalogue_release.sh`) and `PROV_CENSUS` (`item_validate.py`) are exact
> literals a human sets, deliberately: an expectation derived from the data cannot be contradicted by
> it. But nothing in the repo *produces* the number a human is meant to set, so the only routes are
> reading `01_stage.R`'s printed count off a full build, or doing what #75 did — writing a throwaway
> script.
> 
> Measured 2026-10-14 during #75: the literals read `link_run_uid` 18 / `link_config_sha256` 21 /
> `link_sha` 21 while the roster measures **17 / 20 / 20**, the other nine 21, floor 21 still exact.
> The delta is entirely DUNC's null `link_log`. CLAUDE.md and NEWS.md now name that, and say the
> literals are re-taken on the build the next release is cut from — without saying how.
> 
> ## The script #75 used
> 
> Throwaway, and the only copy is in that session's scratchpad. It walks the roster the way
> `01_stage.R` does and drives this repo's own reader, so it needs no stage and makes no writes:
> 
> ```r
> exprs <- parse("scripts/01_stage.R")
> ip <- vapply(exprs, function(e) is.call(e) && identical(e[[1]], as.name("<-")) &&
>                identical(e[[2]], as.name("PROV_FIELDS")), logical(1))
> eval(exprs[[which(ip)]]); source("scripts/fp_provenance.R")
> # then: for each region roster -> each area.yml target -> fp_prov_item(), count non-NA per field
> ```
> 
> Output on the current tree:
> 
> ```
> items staged: 23  carrying any provenance: 21
>   link_run_uid           17
>   link_config_sha256     20
>   link_sha               20
>   link_version           21
>   ... the other eight    21
> ```
> 
> ## Decided (2026-10-15, airvine)
> 
> **It ships as a script** — not a line in the release recipe. The recipe already has six steps,
> and a one-liner that only works if you have memorised the field list is not an improvement;
> `prov_fields-check.py` also then has something to compare against.
> 
> **Name: `scripts/prov_census-measure.R`.** Deliberately *not* `-check`: every `*-check.{R,py}`
> here asserts an expectation, and this one **produces** one. `scripts/README.md` gets a row that
> says so in as many words, so nobody later reads a passing run as a gate.
> 
> ## Build notes
> 
> Worked out 2026-10-15 by reading the pieces; no code written yet.
> 
> ### Reuse, do not duplicate
> 
> - **`PROV_FIELDS`** is parsed out of `01_stage.R`, never copied. `fp_provenance-check.R:24-29`
>   is the pattern to follow exactly — `parse()` the file, find the one `PROV_FIELDS <- ...`
>   assignment, `eval()` that expression alone, and `stopifnot` there is exactly one. A fifth copy
>   of the field list is what #74 spent its review rounds avoiding.
> - **The roster walk** mirrors `01_stage.R`: `config/regions/*.yml` → `watershed_groups` →
>   `config/<wsg>/area.yml` → targets. Use `area[["targets"]]`, **never `area$targets`**: `$`
>   partial-matches, and an `area.yml` carrying `targets_retired:` returns the retired block, which
>   is how a census would count items nobody publishes (`01_stage.R:216-222` records the measured
>   case).
> - **`years`** is the one argument `fp_prov_item()` needs that is not in the record: it feeds the
>   `landcover_key` fold. Discover it the way `01_stage.R:402` does, from
>   `rasters/<scenario>/classified_<yyyy>.tif` with an **anchored** pattern — unanchored, the
>   `.tif.aux.xml` sidecar beside each raster matches and the year is counted twice.
> - **The reader** is `fp_prov_item(prov, species, scenario, where, years)`, driven per target. No
>   staging, no writes, no network.
> 
> ### It must refuse to print a short census
> 
> This is the design point that matters, because the output becomes a literal that **gates
> releases**: a count that is low for any reason other than the data is the dangerous direction —
> it would be pasted into `PROVENANCE_FLOOR` and then satisfied by a build that lost provenance.
> 
> `fp_prov_read()` already draws the line this needs (`fp_provenance.R:147-166`):
> 
> | upstream state | `fp_prov_read()` | the measurement should |
> |---|---|---|
> | no `provenance.json`, or empty | returns `NULL` | count the item as carrying none — this is the legitimate forward-only state |
> | unreadable JSON, or a `schema_version` the reader does not implement | **raises** | refuse to print any census |
> 
> So: wrap each group in `tryCatch`, so one group's refusal does not kill the walk, **record** the
> failure, and then print the per-group failures and **exit non-zero without a census** if any
> occurred. A `fp_prov_sections()` refusal (#75's "the item must find its key") is the same
> disposition.
> 
> ### It must say what it measured
> 
> The numbers get pasted into literals that outlive the run, so the output carries its own
> provenance: the UTC timestamp, `$FLOODPLAINS_DATA`, the producer's `git describe`/HEAD, and the
> count of rostered groups walked versus skipped. A census printed without them is a number with
> no date, which is the state #75 found the literals in.
> 
> **Caveat worth writing into the script's header:** run against a tree that is mid-write — an
> upstream `run_region.R` in flight, which was the case when this was specced — the numbers are of
> a half-finished roster. The timestamp and the producer HEAD are what make that visible rather
> than silent.
> 
> ### Output shape
> 
> Ready to paste into both literals, in the order `PROV_FIELDS` declares, plus the floor:
> 
> ```
> items on the roster: 23   carrying any provenance: 21      <- PROVENANCE_FLOOR
>   link_run_uid           17
>   link_config_sha256     20
>   ...
> ```
> 
> (Those figures are #75's, from 2026-10-14, and are stale by now — they are the shape, not the
> answer.)
> 
> ## Done when
> 
> - `scripts/prov_census-measure.R` exists, runs with no arguments, writes nothing, and needs no
>   database or network.
> - `scripts/README.md` carries a row naming it a **measurement, not a gate**.
> - It refuses, non-zero and out loud, rather than print a census over an incomplete read.
> - #89's release step 3 names it as where the numbers come from.
> - `prov_fields-check.py`'s hard-asserted counts and this script's output are reconciled once, so
>   the two cannot disagree silently.
> 
> Relates: #89 (the cutover, which re-takes these literals twice), #72 (how v1.2.0 gets cut), #75,
> NewGraphEnvironment/floodplains#133 (DUNC, which is why the numbers cannot be re-taken against a
> releasable build yet).
> 
