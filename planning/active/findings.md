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
