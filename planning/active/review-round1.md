# Code-check round 1 — #80 branch diff (`git diff f8003ef...HEAD`)

Reviewer: code-review subagent, 2026-10-14. Scope: the 15 changed code/prose files; `planning/`
skimmed for claims that contradict the code. Every number in the prose was re-derived against
`../floodplains/data` rather than taken from the diff (results at the bottom).

## Findings

### 1. [bug] `scripts/fp_gpkg.R:225-237` — the warning guard discards the only message that names the failing layer, and its stated purpose is unreachable

The handler captures the GDAL warning and calls `invokeRestart("muffleWarning")`; the
`stop("gpkg_copy_layers: GDAL warned writing ...")` at `:234-237` is meant to re-surface it.
But `sf::gdal_utils()` **raises** on the same call, and the raise unwinds
`withCallingHandlers()` before line 234 is ever reached — so the captured message is thrown
away and the muffle suppresses the only place it would have been printed.

Reproduced (DUNC `floodplain_landcover.gpkg`, one real layer + `nope_missing`):

```
Error in sf::gdal_utils("vectortranslate", source = src, destination = dst,  :
  gdal_utils vectortranslate: an error occured
```

That is verbatim the message the comment at `:217-221` says the guard exists to avoid
("gdal_utils's own error says ... and names nothing, while the warning names the layer, which
is the one fact an operator needs"). Measured separately, the warning GDAL signals is
`GDAL Error 1: Couldn't fetch requested layer 'nope_missing'!`, and with no handler at all R
prints it beside the error. So the guard as written is strictly worse than its absence for
the one case it was written for, and the comment block justifying it is false.

Fix: catch the error as well and re-raise with the captured text, e.g.

```r
err <- NULL
withCallingHandlers(
  tryCatch(sf::gdal_utils(...), error = function(e) err <<- conditionMessage(e)),
  warning = function(w) { gdal_warning <<- conditionMessage(w); invokeRestart("muffleWarning") })
if (!is.null(err) || !is.null(gdal_warning)) stop("gpkg_copy_layers: ... ", err, " / ", gdal_warning)
```

(or simply stop muffling). The `setequal()` backstop at `:242-247` is unaffected but is also
unreachable for this case, since the raise comes first.

### 2. [fragile] `scripts/01_stage.R:242-284` — the group-level key read was hoisted above the per-target "no rasters" skip, with two consequences

Before #80 both bundles were only touched **inside** the target loop, after the
`SKIPPED <item> — no rasters` branch at `:325-329`. They are now read at group level, before it.

**(a) A documented skip became a hard stop.** `:244`
(`for (p in gpkg_src) if (!file.exists(p)) stop("Missing source GeoPackage: ", p)`) aborts the
entire stage for a rostered group with no upstream outputs. `:717-734` describes exactly that
state ("an upstream gap ... because `$FLOODPLAINS_DATA` is stale or mid-recompute") and
`ALLOW_SKIPPED` is called "the deliberate escape hatch for rostered groups that are not modelled
yet" — neither can be reached any more, because the stop is upstream of both. Latent today:
measured, all 23 rostered groups carry both files (the only two dirs under
`../floodplains/data` without them, `lit` and `logs`, are a PDF folder and a log folder, not
areas).

**(b) The #80 census reports a skipped target's layers as upstream's retired targets.** When a
target `next`s at `:329`, nothing is added to `claimed_fp`/`claimed_lc`, so the per-group census
at `:665-676` prints **every** layer of that group as

> `N layer(s) match no target of this group, not staged`

and the end-of-run line at `:700-704` labels them "upstream's retired targets, pruned by
floodplains#131". For a group whose only target was skipped both statements are false, and the
second actively invites deleting upstream data that belongs to a live target. It also makes the
count CLAUDE.md says should fall to zero after floodplains#131 non-zero for an unrelated reason.
Latent today (measured: every rostered group has `data/<wsg>/rasters/<primary_scenario>`), live
the first time a rostered group is un-modelled or mid-recompute — which is the case (a) above
also exists for.

Cheapest fix for (b): accumulate `claimed_*` from the target set rather than from what staged,
or suppress/annotate the census for a group that skipped a target.

### 3. [fragile] `scripts/test_pipeline.R:432-451` — the layer-set arm cannot see a selector that drops a whole layer family

`expect` comes from the same `gpkg_own_layers()` the stage selects with, and the per-layer arm at
`:382-418` is satisfied by any **subset**. The diff's comment (`:428-431`) argues the key arm is
the one doing the work; that holds for an *extra* layer and not for a *missing* one, which is the
direction this arm claims to cover.

Enumerating everything else that could notice a missing family:

| would catch | covers |
|---|---|
| `01_stage.R:527` `missing_layers` | only `scenario` + `<sp>_ff02/04/06` |
| `gpkg_extract_layer` (`:501`) | only `transition_<scen>_<span>` |
| `04_gpkg_style.py`, `item_validate.check_layer_styles` | derive their layer list from the file under test |

So losing **every** `classified_*` layer, the `<sp>_ff04_by_blue_line_key` layer (kept on 18 of
23 items, measured) or either aspatial table from a published bundle ships silently and green on
all five surfaces. One assertion taken from the source *without* the selector — a per-family
presence check, or a count of `classified_*` against `length(meta$years)` — closes it.

### 4. [fragile] `scripts/01_stage.R:437-438` and `:458` — an NA `data_type` becomes an NA index and inflates the vector the guard measures

`sel$keys$data_type` is `dt$data_type[match(layers, dt$table_name)]` (`fp_gpkg.R:124`), i.e. `NA`
for any layer `st_layers()` reports that `gpkg_contents` does not hold. In R,
`c("a","b")[c(TRUE, NA)]` is `c("a", NA)`, so such a layer makes `length(feat) >= 1` and the
"this item's layers are all aspatial" refusal at `:439-444` pass vacuously; the aspatial report at
`:459-463` would print `NA` as a table name. Latent — measured, `st_layers()` and `gpkg_contents`
return identical sets on the files checked — but `which()` or
`sel$keys$data_type %in% "features"` removes it for free.

### 5. [fragile] `scripts/fp_gpkg.R:122-125` — a layerless GeoPackage raises an error that names neither the file nor the condition

`data.frame(layer = character(0), wsg = NA_character_, ...)` cannot recycle a length-1 scalar
against a length-0 column. Reproduced:

```
Error in data.frame(layer = character(0), wsg = NA_character_, ... :
  arguments imply differing number of rows: 0, 1
```

It refuses rather than passing, so this is a diagnostics defect only — but `gpkg_layer_keys()` is
the first reader of these files, and a crashed producer run leaving a registered-but-layerless
GeoPackage is precisely the state it would meet.

## Minor notes (not findings)

- `scripts/item_create.py:427-431` — the published `floodplain.gpkg` description says "The
  ff02/ff04/ff06 delineations", but 18 of 23 items also ship `<sp>_ff04_by_blue_line_key`
  (measured). `item_validate.py:1499-1501`'s "three or four of them since #80" already
  acknowledges four.
- `scripts/gpkg_determinism-check.R:101-104` takes its layer set `ORDER BY table_name`, while the
  stage passes `st_layers()` order. Both orders are internally stable, so the determinism property
  still holds; the arm just proves it for a different ordering than the one published.
- `scripts/gpkg_determinism-check.R:35` guards only on the landcover bundle; a staged dir missing
  `floodplain.gpkg` reaches `:101` and fails with a raw GDAL open error instead of the friendly
  message.
- **Pre-existing, not this branch:** `scripts/01_stage.R:306-307` says "every area, including the
  four that carry no provenance.json at all (measured 2026-10-14: lit, logs, mcgr, pine)".
  `lit` and `logs` are not area dirs (literature PDFs and run logs); only `mcgr` and `pine` are.
  Introduced in a188ced (#75).

## Checked and correct

R semantics the prompt flagged, all verified by reading and where cheap by execution:

- `gpkg_own_layers()` leads with `ok`, so `FALSE & NA` is `FALSE` and no `NA` reaches
  `keys$layer[hit]`. The `off <- toupper(k$wsg) != toupper(wsg)` arm at `01_stage.R:275` can only
  be `NA` for a non-`ok` row, and the `bad` stop at `:269` fires first, so `if (any(off))` can
  never see `NA`.
- `union`/`setdiff`/`setequal` on `character(0)`; `%in%` with `NA` (FALSE); `paste0(..., collapse=)`
  guarded by `length()` at every call site; `stop(..., if (FALSE) ...)` drops the `NULL`.
- `gpkg_determinism-check.R:106-111` — the `local({ u <- up; l <- layers; ... })` capture is
  correct, and `results[[length(results) + 1L]] <<- ...` resolves `results` in the global frame.
- `$` is exact on every list/data.frame access added here (`sel$keys`, `r$size`, `meta$wsg_lower`,
  `dt$data_type`).
- SQL interpolation (`sprintf('... FROM "%s"', lyr)`) is double-quoted and the names come from the
  producer's `gpkg_contents`; same pattern already in `test_pipeline.R`.
- The `test_pipeline.R` filter change is a strengthening, not a weakening: the old geometry filter
  excluded the producer's `transition_*` layer (declared `Unknown (any)`, empty geomtype) as well
  as the two aspatial families, so `wsg` was never asserted on them.
- 04/validate `features`-only filters remain consistent with staging selecting the aspatial tables.
- No assertion anywhere reads asset `title`/`description`, so the two new descriptions are inert;
  the `--only` wholesale asset compare in `catalogue_release.sh:609-630` runs *after* registration.

## Measurements re-derived (independent of the diff)

Over all 26 dirs in `../floodplains/data`, via stdlib `sqlite3`, and via the branch's own helpers
in R:

| claim | source | verdict |
|---|---|---|
| 276 layers, 246 `features` + 30 `attributes` | `fp_gpkg.R:92-95` | ✓ exactly |
| all three key columns, exactly one distinct value, every layer | same | ✓ 0 exceptions |
| 24 area dirs with both bundles | `findings.md` | ✓ (26 dirs − `lit`, `logs`) |
| MORR fp 13→4, lc 22→6 | `progress.md` | ✓ |
| BULK 8→4 / 20→10, KISP 8→4 / 11→6 | implied by NEWS | ✓ |
| `_by_blue_line_key` on 18 of 23 groups | `scripts/README.md:295` | ✓ 18 |
| `patch_watercourse_*` 18 of 23, `composition_*` 5 | `CLAUDE.md` | ✓ 18 / 5 |
| `_patches` only on MORR's retired ch/co | `style_qml-write.py:28-30` | ✓ (6 layers, MORR only) |
| 826.9 → 642.9 MB over the 23 rostered groups | NEWS.md, CLAUDE.md, `scripts/README.md` | ✓ 826,941,440 → 642.9 MB |
| MORR 116.3 → 35.4 MB, −70% | NEWS.md | ✓ |
| floodplain-layer count per published item is 3 or 4 | `item_validate.py:1499` | ✓ |
| multi-layer `vectortranslate` byte-reproducible with the pin, `attributes` preserved | `fp_gpkg.R:31-38` | ✓ (DUNC, 6 layers, two builds 1.2 s apart, md5 identical) |
| every rostered item keeps ≥1 `classified_*` and exactly 1 `transition_*`; no layer fires `unfamiliar` | — | ✓ |
| 46 translations (23 groups × 2 files): no GDAL warning, no `setequal` failure | — | ✓ 0 / 0 |

So no prose number in the diff is wrong, and the selection rule produces the keep sets the diff
claims on every rostered group.
