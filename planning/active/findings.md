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

Not pasted into any literal: DUNC cannot publish until floodplains#133, so a release cut from
this tree fails one step earlier and these numbers would encode a broken record as the
expectation (#75, CLAUDE.md).

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
