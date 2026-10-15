# Code-check round 4 — narrow verification (#89)

Scope as briefed: re-measure, independently, every quantity `01650a6` changed; then check the
prose rewrites for broken meaning; then a short behavioural scan. Nothing was taken from the
commit, from `review-round3.md`, or from an earlier round's number.

**Measured 2026-10-15, after `01650a6`, working tree clean.** Every size below is derived from
`os.path.getsize()` on the files themselves, with MiB = `/1024**2` and MB = `/1e6` printed side
by side so no row can be read in the wrong unit. The roster is the 23 `data/stac/*_all_ff04`
directories; the upstream side is `../floodplains/data/<wsg>/` for those same 23 codes.

Two methodology notes, because both bit during this round:

* `ls --color` is aliased here and injects ANSI bytes into a captured directory listing. The
  first measurement script silently found zero files for all 23 groups and reported `0.0 MiB`
  for both sides — a clean-looking agreement with nothing behind it. Everything below is
  globbed from Python, not from `ls`.
* The upstream bundles have not been written since **2026-10-15T11:50Z** (newest mtime,
  `dunc/floodplain_landcover.gpkg`), and `01650a6` is 15:47 local. So this round measures the
  identical tree round 3 measured; any disagreement is a measurement error, not drift.

---

## Measurement table

Scope column states exactly what was summed.

| # | claim (site) | stated | measured | verdict | scope measured at |
|---|---|---|---|---|---|
| 1 | upstream two bundles (CLAUDE.md, scripts/README.md) | 1602.6 MiB | 1,680,412,672 B = **1602.6 MiB** = 1680.4 MB | agree | `../floodplains/data/<wsg>/{floodplain_landcover,floodplain}.gpkg`, 23 rostered wsg |
| 2 | staged two bundles | 1035.3 MiB | 1,085,607,936 B = **1035.3 MiB** = 1085.6 MB | agree | `data/stac/<wsg>_all_ff04/{floodplain_landcover,floodplain}.gpkg`, same 23 |
| 3 | delta | 567.2 MiB | 594,804,736 B = **567.2 MiB** = 594.8 MB | agree | row 1 − row 2 |
| 4 | `transition_vector.gpkg` further | 89.3 MiB | 93,618,176 B = **89.3 MiB** = 93.6 MB | agree | staged, 23 items |
| 5 | MORR 110.9 → 34.0 MiB, −69% | as stated | 116,326,400 → 35,655,680 B = **110.9 → 34.0 MiB**, **−69.4%** | agree | MORR two bundles, both sides |
| 6 | "both sides are the same two files" | — | yes: `floodplain_landcover.gpkg` + `floodplain.gpkg` on each side, no third file on either | agree | file-name check per group |
| 7 | units really are MiB | MiB | yes — the same bytes are 1680.4 / 1085.6 MB decimal, so the labels are correct for rows 1–5 | agree | — |
| 8 | **historical pair "827 → 643 MiB"** (CLAUDE.md:153) | MiB | its source records **MB**; in MiB it is **788.6 → 613.1** | **disagree** | see Finding 2 |
| 9 | **`attributes` layers, two bundles** (CLAUDE.md:173, 01_stage.R:528) | 68 of 68 | **66 of 66** | **disagree** | `gpkg_contents.data_type='attributes'`, two bundles, 23 rostered wsg |
| 10 | `aquatic_network.gpkg` holds N more | 23 | **23** (1 per group) | agree | same 23 wsg |
| 11 | item JSON minimum | 5.6 MB | 5,619,746 B = **5.6 MB** (`sloc_all_ff04.json`) | agree | `data/stac/*.json` less `collection.json` |
| 12 | item JSON maximum | 18.3 MB | 18,245,948 B = **18.2 MB** (`fran_all_ff04.json`) | **disagree** (0.05 MB, rounds down) | same |
| 13 | item JSON total | 252.6 MB | 252,620,392 B = **252.6 MB** = 240.9 MiB | agree | 23 item JSON, collection.json excluded |
| 14 | asset re-read ≈1.3 GB / 1338.3 MB | as stated | 1,338,267,559 B over **246** asset files = **1338.3 MB** = 1.34 GB = 1276.3 MiB = 1.25 GiB | agree | every `assets[*].href` of all 23 items, resolved to its staged file |
| 15 | NEWS.md whole file | 47,156 B | **47,156 B** | agree | `wc -c NEWS.md`, same as `git show HEAD:NEWS.md` |
| 16 | NEWS.md top section | 36,128 B | **36,129 B** | **disagree** (1 B) | the script's own slice: `news=$(cat NEWS.md); printf '%s\n' "$news" \| awk '/^## /{n++} n==1'` |
| 17 | margin 1.8x (and 1.39x whole file) | as stated | 65536/36129 = **1.814**; 65536/47156 = **1.390** | agree | 64 KiB = 65536 B |
| 18 | four COGs on 19 items, eight on four | as stated | `{4: 19, 8: 4}` | agree | `*.tif` per `data/stac/<item>/` |
| 19 | 10 assets on 19, 14 on four | as stated | `Counter({10: 19, 14: 4})`; the four 14s are bulk, kotl, lnth, necr (7-year) | agree | `len(assets)` per item JSON |
| 20 | 23 groups (readme_functions.R:330) | 23 | **23** published items, 23 distinct wsg | agree | build |
| 21 | 23 unmarked / "all 23 carry flooded 0.7.0" (item_validate.py:274) | 23 | **23** items, **0** `deprecated`, `flooded` = `0.7.0` on all 23 | agree | item properties |
| 22 | `summaries.flood_factor == [4]` | [4] | **[4]**; `scenario ["all_ff04"]`, `species ["all"]` | agree | `data/stac/collection.json` |

### Also re-measured (candidate set, not in the briefed list)

Each of these is a quantity or quantifier this branch wrote or changed; all agree.

| claim | measured |
|---|---|
| CLAUDE.md:145 "22 of the 23 groups" carry a layer naming no target, "only DUNC clean" | 22 dirty, **DUNC** the single clean group |
| CLAUDE.md "all 23 items carry both a `patch_watercourse` and a `composition`" | exactly 1 + 1 on all 23 staged landcover bundles |
| 01_stage.R:556 `_by_blue_line_key` "on all 23 groups" | 23 of 23 |
| 01_stage.R:556 `_by_gnis_name` "upstream on MORR's coho" | MORR only, `co_ff04_by_gnis_name` |
| style_qml-write.py "four per published item", "MORR's file has 13 layers" | staged `floodplain.gpkg` = 4 layers on all 23; MORR upstream = 13 |
| item_validate.py:1758 "`transition` 81 of 90 ship off" | 91 categories, 82 `render="false"`; the catch-all (`value="NULL"`) is one of them → **81 of 90** emitted |
| `EXPECTED_STYLE_CATEGORIES {classified 10, transition 91}` / `EXPECTED_RAT_ROWS {10, 100}` | 10 and 91 in the committed QML; validator confirms 10/100 |
| prov_fields-check.py "5 missing only link_run_uid (kotl, larl, sloc, dunc, mcgr)" | exactly those 5 lack `link:run_uid` |
| `PROV_CENSUS` 18 / 23×11, `PROVENANCE_FLOOR` 23 | validator printed `link_run_uid 18`, the other eleven `23`, `23 of 23 … floor 23` |
| `RETIRED_ITEMS` "23 ids over 22 groups" | 23 ids, 22 distinct wsg |
| NEWS.md "BULK … 659.99 km²" | `bulk_all_ff04.floodplain_ff04_km2 = 659.99` |
| README.Rmd "Seven assets each, plus one per classified year" | consistent with `n_expected <- 7L + length(years)` and with row 19 |

### Re-validation

| command | result |
|---|---|
| `uv run python scripts/item_validate.py --expect-provenance 23` | exit 0, 5m44s; census and floor as above |
| `scripts/prov_fields-check.py` | exit 0, 49 assertions, 0 failed |
| `scripts/style_drift-check.py` | exit 0, 3 styles byte-identical (10 classes) |
| `scripts/attribution_drift-check.py` | exit 0, citation 770 chars |

---

## Findings

### 1. [bug] CLAUDE.md:173-175 and scripts/01_stage.R:528-530 — "68 of 68" is 66 of 66; the extra two are a group the roster excludes

CLAUDE.md:

> Every `attributes` layer in the two bundles this repo stages from is in the landcover one
> (68 of 68, measured on the v2.0.0 tree; upstream's `aquatic_network.gpkg` holds 23 more that
> nothing here reads)

Measured over the 23 rostered groups, `gpkg_contents.data_type='attributes'`:

```
floodplain_landcover.gpkg : 66
floodplain.gpkg           :  0
aquatic_network.gpkg      : 23
```

So it is **66 of 66**, and the commit message's "68 of 91" is **66 of 89**. The definition is
not in question: `01_stage.R` and `test_pipeline.R` both key on `data_type`, there are zero
unregistered user tables in either bundle, and `ogrinfo` agrees table-for-table on a spot check
(`bulk`: 20 layers, 4 aspatial).

The two extra layers are `../floodplains/data/neexdzii/floodplain_landcover.gpkg`.
`floodplains/config/regions/skeena.yml` excludes that group by name —
`watershed_groups: [BULK, MORR, KISP]   # NEEXDZII (subset of BULK) intentionally excluded` —
so it is staged by nothing and is not one of "the two bundles this repo stages from". A glob of
`../floodplains/data/*/` yields 24 directories carrying the bundle, 66 + 2 = 68; `lit/` has none.

**This is the same defect round 3 was created to fix, inside round 3's own fix**: a measurement
taken at a scope the prose does not state, indistinguishable from a correct one. It is also
internally inconsistent in a single parenthesis — the 23 for `aquatic_network.gpkg` is right at
roster scope (NEEXDZII's copy holds none), so the sentence reports one number over 24 directories
and the next over 23.

Fix: 66 of 66 in both copies, and say the scope is the 23 rostered groups.

### 2. [bug] CLAUDE.md:153 — the historical pair was relabelled MB → MiB, and its source says MB

`01650a6` rewrote `the figures before it were 827 -> 643 MB` to `… 827 -> 643 MiB`. That pair was
not and cannot be re-measured — the species-roster bundles were overwritten by the whole-network
runs — so the relabel has no source. Its actual source does:

`planning/archive/2026-10-issue-80-item-scoped-geopackages/progress.md:108`

> `826.9 -> 642.9 MB`, 184 MB less to publish. MORR -70% (116.3 -> 35.4)

and that record is checkable today, because MORR's upstream bundles have **not** been rewritten
since 2026-10-14 06:52 — before #80's measurement. They are 116,326,400 B, i.e. **116.3 MB
decimal** and 110.9 MiB. #80 wrote 116.3. So #80 measured in decimal MB, and the historical pair
in MiB is **788.6 → 613.1**, not 827 → 643.

The consequence is in the sentence the relabel sits in: the reader now compares 643 "MiB" against
this build's 1035.3 MiB, an apples-to-apples claim that is off by ~5% because one side is really
MB. Fix: restore `MB` on the historical pair (with its own unit, as its source has it), or convert
it to 788.6 → 613.1 MiB.

### 3. [fragile] scripts/catalogue_release-check.sh:1064 — the third copy of the NEWS.md size, still 39,573 B

`01650a6` updated the NEWS.md byte count in the two sites inside `catalogue_release.sh`
(lines 687 and 728). A third copy, making the same argument about the same 64 KiB pipe buffer,
was not updated:

```
# the harness payloads are hundreds of bytes, and NEWS.md is 39,573 B against that 64 KiB.
```

It is 47,156 B. The conclusion still holds (47,156 < 65,536), so this is not a live defect — but
it is round 2's "the fix landed in one of two copies" recurring as one of **three**, and it is
the copy furthest from the number's source, so it will go stale first and silently.

### 4. [fragile] scripts/test_pipeline.R:323-326 — the rewritten comment contradicts the count check fifteen lines above it

```r
  # `transition_2017_2023` is the COG key and is also the stem of the gpkg's old proposed
  # filename, so keying the vector by its stem would silently replace the raster and still
  # leave the item's other assets (10 on a three-year item, 14 on an annual-span one).
  # Assert both survive.
```

10 and 14 are what `n_expected <- 7L + length(unlist(meta$years))` (line 305) requires on an
item **with no collision** — measured, `Counter({10: 19, 14: 4})`. A stem-key collision replaces
one asset with another, so the item would hold **9 or 13** and the count check on line 306 would
fire and name the shortfall. The comment therefore tells a future maintainer that the count guard
is blind to this case, which is the argument for keeping the explicit key assertion — and it is
not true.

The false mechanism is inherited (`still leave 7 assets` had the same shape against the then
`!= 7L` check), but round 3 re-measured the number and left the claim standing, which is exactly
the failure mode the round exists to catch: a quantity corrected inside a sentence that was wrong
for a different reason. Either drop the parenthetical, or state the real asymmetry — the count
check *does* catch a collision, and the explicit key assertion is what names *which* key was lost.

### 5. [fragile] scripts/item_validate.py:2072 — "reports 21 items as unmarked-and-not-rebuilt"

```python
    # absent — so without this first, a software map of the wrong TYPE reports 21 items as
    # unmarked-and-not-rebuilt instead of the one shape message that names the cause.
```

21 was the v1.1.0 build. On this build it is 23. Caught by an independent sweep for `\b2[12]\b`,
not by round 3's enumeration — so the enumeration that `de8e473` claims to have done over the
stale-quantity set did not cover this file's prose.

### 6. [fragile] scripts/README.md:61-67 — one paragraph, two units, and a figure from the wrong scope

```
Verifying re-reads every asset … The two GeoPackage bundles are the bulk of it:
1035.3 MiB across the 23 rostered groups … All staged assets together are 1338.3 MB, which is
what the re-read actually costs
```

Two problems in the same paragraph, both of the class the brief flags:

* **Mixed units across a comparison.** 1035.3 **MiB** and 1338.3 **MB** describe parts of one
  total. A reader divides and gets 77%; the true two-bundle share of the re-read is
  1085.6 / 1338.3 = **81%**.
* **Wrong scope for the sentence.** "The two GeoPackage bundles are the bulk of it" attributes
  the #80 *comparison* figure to the *re-read*, but the re-read covers all three bundles —
  1,179,225 kB = **1179.2 MB** (1124.6 MiB) — plus 154.6 MB of COGs and 4.5 MB of QML. The
  excluded 89.3 MiB is excluded from the #80 comparison only; it is fully inside the cost the
  paragraph is quantifying.

Fix: give the re-read's gpkg share in the same unit as the re-read total, and say plainly that
`transition_vector.gpkg` is excluded from the *saving* and included in the *cost*.

### 7. [fragile] two one-step rounding slips

* `scripts/item_register.sh:37`, `scripts/item_create.py:726`, `scripts/catalogue_release.sh:525`
  — "18.3 MB" is 18,245,948 B = **18.2 MB**. Three copies, all the same. The neighbouring
  `--max-time 60 … against an 18 MB body` is fine either way.
* `scripts/catalogue_release.sh:729` — "its top section 36,128 B" is **36,129 B** by the script's
  own `awk '/^## /{n++} n==1'` slice. The 1.8x margin is unaffected.

Neither changes a conclusion; both are listed because the brief asked for stated-vs-measured on
every row, and because a number that is "about right" is how the 1035.3/1124.6 slip survived two
rounds.

### Behavioural scan — no new defect

Round 3's verdict is **confirmed**. The code the branch changed behaves as written:

* The step-6 `item_unregister.sh` failure block: `|| { … exit 1; }` is correct under `set -e`;
  `post_ids=$(fetch_live_ids)` as an `if` condition is safe; both `comm` inputs are sorted
  (`fetch_live_ids` sorts in Python, `to_delete` descends from a `comm -12` of
  `LC_ALL=C sort -u` output); the missing `LC_ALL=C` on `comm` matches the pre-existing call it
  sits beside and cannot reorder this ASCII id set.
* `retired $(printf '%s\n' "$to_delete" | grep -c . || true) item(s)` avoids the `grep -c`
  exit-1 trap correctly — `|| true` inside the substitution, not `|| echo 0`, so no second line
  is appended, and an empty `$to_delete` yields `0`.
* `$to_delete` is in scope at the step-7 report: both blocks are gated on `[ "$n_retired" -gt 0 ]`
  and shell variables are global.
* `DEPRECATED_ITEMS: set[str] = set()` / `EXPECTED_DEPRECATED: set[str] = set()` are vacuous over
  exactly the two set-difference arms the comment names; the new `elif EXPECTED_DEPRECATED:` /
  `else:` split prints a true statement in both states, and the validator exercised the `else`
  branch cleanly.
* `classes <- classes[, c(...)]` with the widened `setequal(classes$code, c(0, 1, …, 11))` floor,
  `EXPECTED_RAT_ROWS {10, 100}` and `EXPECTED_STYLE_CATEGORIES {10, 91}` are mutually consistent
  with the committed QML and with the staged RATs — all four check scripts and the validator pass.

---

## Termination verdict

**Not met.**

Four of the quantities `01650a6` touched are wrong when measured independently, and two more
stale copies were found by a sweep the round did not run:

* **68 of 68 is 66 of 66** (Finding 1) — and it is wrong by the *same mechanism* round 3 was
  convened for: a count taken over 24 upstream directories and reported at a scope of 23. Round 3
  caught that mechanism in round 2's fix and then committed a fresh instance of it in the same
  commit.
* **827 → 643 MiB is 827 → 643 MB** (Finding 2) — a unit asserted on a measurement that was not,
  and cannot be, re-taken; its archived source and a still-unmodified file both say MB.
* `catalogue_release-check.sh`'s 39,573 B and `item_validate.py`'s "21 items" (Findings 3, 5) are
  copies the enumeration missed, which means the enumeration in `de8e473` was not complete over
  the files it claimed.
* `scripts/README.md`'s MiB/MB mix and wrong-scope attribution (Finding 6) is a third instance of
  the scope/unit class, in the paragraph round 3 rewrote to fix exactly that.
* Findings 4 and 7 are a false mechanism re-blessed by a correct re-measurement, and two
  rounding slips.

Nothing here blocks the *release mechanism* — the validator, the four check scripts, the floor,
the census, the retirement literal and the styles are all clean and independently confirmed. What
is not met is the termination test as stated: **not** every number in the candidate set is correct
when measured independently, and three of the six findings sit *inside the previous round's fix*,
which is the explicit signal to run another round rather than stop.

The round-5 instrument should not be another read. Two of these would have been caught by a single
script that walks the roster the way `01_stage.R` does and prints the dozen figures the prose
quotes — the `quantities-check` sibling the brief says is being filed. Until it exists, the
minimum for round 5 is: fix Findings 1–6, then re-derive each corrected number **from a different
expression than the one that produced it** (e.g. per-group sums reconciled against the total), and
state the scope inline in every sentence that carries a count.
