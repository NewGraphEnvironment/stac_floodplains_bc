# Findings — QGIS cannot find the embedded styles in floodplain_landcover.gpkg (#95)

## Measured here before any edit (2026-10-16, staged v2.0.0 tree)

Read-only over `data/stac/bowr_all_ff04/*.gpkg`:

| fact | value |
|---|---|
| `layer_styles` present | all three bundles |
| `layer_styles` registered in `gpkg_contents` | **none** of the three |
| `gpkg_contents.last_change` on every existing row | `2000-01-01T00:00:00.000Z` (= `GPKG_EPOCH`) |
| `gpkg_spatial_ref_sys.srs_id` | `floodplain.gpkg` [-1, 0, 3005, 4326]; other two [-1, 0, 4326, 32610] |
| `PRAGMA foreign_keys` | 0 |
| `gpkg_contents` columns of note | `identifier TEXT UNIQUE`, `description TEXT DEFAULT ''`, `last_change ... DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))` |
| `floodplain_landcover.gpkg` aspatial rows | `composition_all_ff04_2017_2023`, `patch_watercourse_all_ff04_2017_2023`, both `attributes`, `srs_id` 0 |

So `srs_id = 0` already exists in all three files and the pin is already the value every
other `gpkg_contents` row carries — the registration adds no new srs row and no second
timestamp vocabulary.

## The mechanism is GDAL's, not QGIS's (measured 2026-10-16, corrects the issue body)

The discriminator is the GPKG driver's `LIST_ALL_TABLES=AUTO` default: GDAL surfaces a
table `gpkg_contents` does not register **only** while the file declares no aspatial
content. QGIS's style lookup goes through GDAL's layer list, so the style is unreachable
in precisely the bundle where GDAL refuses to list the table.

Measured on the `sloc_all_ff04` witness copies, three GDALs:

| reader | `floodplain.gpkg` | `transition_vector.gpkg` | `floodplain_landcover.gpkg` |
|---|---|---|---|
| `sf::st_layers()`, GDAL 3.8.5 | lists `layer_styles` | lists it | **does not list it** |
| QGIS 4.2.1's own `ogrinfo`, GDAL 3.12.4 | lists it | lists it | **does not list it** |
| homebrew `ogrinfo`, GDAL 3.13.0 | lists it | lists it | **does not list it** |
| QGIS `ogrinfo -oo LIST_ALL_TABLES=YES` | — | — | **lists it (7th)** |
| homebrew `ogrinfo -oo LIST_ALL_TABLES=NO` | **hides it** | — | — |

So: a decade-old heuristic, not a 4.2.1 regression — waiting it out is not an option, and
the fix is robust whichever way the heuristic moves. `LIST_ALL_TABLES` is a consumer-side
open option, unreachable from the published bytes, and a `gpkg_extensions` row would make
things worse (the heuristic's other input is the legacy `gdal_aspatial` extension). So
**registering is the only in-file fix**.

Registering the row on a copy, then re-asking the same GDAL:

```
$Q/ogrinfo -q <copy>/floodplain_landcover.gpkg   # before: 6 layers, no layer_styles
#   INSERT INTO gpkg_contents (...) VALUES ('layer_styles','attributes',...)
$Q/ogrinfo -q <copy>/floodplain_landcover.gpkg   # after: 7 layers, layer_styles listed
$Q/ogrinfo -so <copy>/... layer_styles           # Feature Count: 4, FID Column = id,
                                                 # every column typed, NO warning
```

That last line is the measurement that justifies writing **less** than GDAL does: the
registered table reads cleanly with no `gpkg_ogr_contents` row and no feature-count
triggers.

`data_type` must be `attributes`. `features` needs a `gpkg_geometry_columns` row and
breaks the layer; `aspatial` is the retired GDAL extension and needs a `gpkg_extensions`
row; `attributes` is GPKG 1.2 core and is what GDAL itself wrote for `composition_*` and
`patch_watercourse_*` in these same files.

Side effect, in the direction we want: once `layer_styles` is registered it is itself an
`attributes` row, so each such file switches into the "AUTO hides unregistered tables"
mode. Nothing is affected today, and it makes reachability a property of the file.

## Readers of `gpkg_contents` in this repo, and whether the new row changes their answer

| reader | selects | affected |
|---|---|---|
| `04_gpkg_style.py::feature_layers()` | `data_type = 'features'` | no |
| `item_validate.py::check_layer_styles` (`layers`) | `data_type = 'features'` | no |
| `test_pipeline.R::keyed_layers()` | `data_type IN ('features','attributes')` | **YES** — three arms |
| `gpkg_determinism-check.R` (~121) | `data_type IN ('features','attributes')` on the STAGED file | **YES** — both multi-layer arms |
| `fp_gpkg.R::gpkg_layer_keys()` | `gpkg_contents` unfiltered, producer files only | no; its comments are now false |
| `01_stage.R` | producer files + freshly staged copies, before the style step | no |
| `item_create.py` | never opens a GeoPackage (hashes bytes) | no |
| `only_preflight.py`, `prov_*`, `year_sets-check.py`, `stage_years-check.R`, `attribution_drift-check.py`, `style_drift-check.py`, `collection_version.py`, `catalogue_release*.sh` | no GeoPackage access | no |
| `readme_functions.R`, `README.Rmd` | `file:size` from the LIVE catalogue via rstac | after the republish, not from the code change |

`gpkg_determinism-check.R` is the sharper break of the two, and the first inventory missed
it: the layer set comes from the **staged** file and is handed to `gpkg_copy_layers()`
against the **producer's** file, which has no `layer_styles`, so the copier stops with
`Couldn't fetch requested layer` — and the message blames the copier. `$FLOODPLAINS_DATA`
is present on this machine, so both multi-layer arms run and the failure is live.

`test_pipeline.R` is the other break: `keyed_layers()` feeds the per-layer key arm (~390),
the source-set equality arm (~477, whose `expect` comes from the producer's file, which
has no `layer_styles`) and the absolute-floor arm. Its comment block at 369–381 states
the structural-exclusion rationale this fix falsifies.

## The retired claim, and where it is still live

| file | form |
|---|---|
| `scripts/04_gpkg_style.py` | docstring bullet: "registering the table adds a second wall-clock timestamp … the registration buys nothing" |
| `scripts/README.md` | step-04 row: "measured to auto-style fine without them" |
| `scripts/test_pipeline.R` | comment: "deliberately writes `layer_styles` with NO `gpkg_contents` row" |
| the shared spatial code-check convention | "Neither is needed — QGIS auto-styles without them … writing *less* than QGIS does removes a churn vector" — loaded by **every** repo |

## A sibling package carries the same shape

Not a feature request — a plausible live defect, filed there with the detail. The shape, in
terms this repo can state without naming another repo's internals: a package that writes
`layer_styles` with no `gpkg_contents` row, and separately registers a provenance-tracking
table as `data_type = 'attributes'`, puts both in **one** file under its single multi-layer
project layout — exactly the shape measured here. Under its per-layer layout the tracking
table owns its own file and the question does not arise. One of its own readers scans
`gpkg_contents` unfiltered and excludes `layer_styles` only in a fallback branch, so a
registration there needs the same by-name exclusion `test_pipeline.R` just grew.

It is also where a reusable reachability verb belongs, because it already owns a QGIS oracle
— a pinned container with a version constant — which this repo does not and should not grow
for one hand-run check.

## Why the guard that would have caught it needs QGIS's own python

`osgeo`/PyQGIS is not available under `uv` (CLAUDE.md records `uv pip install gdal` as
having no usable wheels), so a reachability check cannot run from `run_pipeline.sh`. It
joins `fp_provenance-check.R`, `stage_years-check.R`, `year_sets-check.py` and
`prov_fields-check.py` — the checks a normal build never runs.

## Three things the first design got wrong

1. **A bare `INSERT` raises on a real path.** `gpkg_contents.table_name` is the PRIMARY KEY
   and `identifier` is UNIQUE. Once the tree carries the row, any run where the style rows
   differ but the registration is already correct — a regenerated `styles/*.qml`, a new
   class table — falls past the skip-if-current check and executes the INSERT into an
   already-registered table. The write must be conditional, and `UPDATE` rather than
   `REPLACE`, which reassigns the rowid.
2. **Publishing from a repaired tree would publish checksums no rebuild reproduces.**
   Running the fixed writer over the existing v2.0.0 tree repairs it, but that file went
   through more write transactions than a fresh build's, so its SQLite header change
   counter and freelist state — and its sha256 — differ. v2.0.1 must be cut from a full
   `run_pipeline.sh`, which is the less tempting of the two paths.
3. **A per-bundle cold arm in the QGIS check would report two false failures.**
   De-registering `floodplain.gpkg` or `transition_vector.gpkg` returns them to a state
   where AUTO still lists the table and QGIS still finds the style. The cold arm is
   landcover-only, or it injects an `attributes` row first.

Insert order into `gpkg_contents` is **not** a determinism hazard: it is a rowid table
whose PRIMARY KEY and UNIQUE constraints are value-keyed `sqlite_autoindex` b-trees, and
in a fresh build the sequence is fixed — `01_stage.R` writes the features through one
sorted `vectortranslate` call, then step 04 appends one row at `max(rowid)+1`.

## Register all three bundles, not the landcover one alone

Measured off the 23 item documents: landcover alone is 777.7 MB re-uploaded and 23 moved
checksums; all three is 1,179.2 MB and 69. `aws s3 sync` passes neither `--size-only` nor
`--delete`, so mtime forces the re-upload either way. All three, because
`01_stage.R` explicitly anticipates an aspatial family appearing in `floodplain.gpkg` and
would stage it — and on that day that bundle's styles die exactly as the landcover
bundle's did, silently.

## Where the regression guard belongs

Three layers, none of them redundant:

| layer | asks | runs |
|---|---|---|
| `item_validate.py`, stdlib sqlite3 | is the row there, `attributes`, pinned | every build; the release gate |
| `test_pipeline.R`, `sf::st_layers()` | does GDAL **list** the table | the smoke test — sf's GDAL 3.8.5 reproduces the heuristic exactly |
| `style_reach-check.py`, PyQGIS | what does QGIS actually **draw** | by hand |

GDAL listing the table is necessary but **not sufficient** for QGIS to apply the style —
the NULL `f_table_schema` trap is the standing proof that a listed, well-formed row can
still open unstyled. And the release gate stays at the SQL level: `osgeo` is unavailable
under `uv`, and shelling out to `ogrinfo` would put an undeclared CLI dependency in the
one script `catalogue_release.sh` gates on.

## Ordering hazard

`01_stage.R` unlinks `data/raw` and `data/stac` unconditionally, **before** any `WSG_ONLY`
filtering, and `data/stac` is gitignored. So any run of `test_pipeline.R` or
`run_pipeline.sh` destroys the only local copy of the broken v2.0.0 state — which is the
before-arm of every measurement here. Captured first (Phase 0).

## Errors Encountered

| Error | Resolution |
|-------|------------|

## Issue context

## Problem

Every published `floodplain_landcover.gpkg` carries a correct `layer_styles` row per
feature layer, and **QGIS does not find any of them**. The layer opens with a random
single symbol instead of the 10-class `classified` or 91-category `transition` style.

Measured 2026-10-15 on QGIS 4.2.1 (macOS), against the **v2.0.0 build** — the bytes
that were published:

| bundle | styled layers | QGIS finds the style |
|---|---|---|
| `floodplain.gpkg` | 4 per item | yes |
| `transition_vector.gpkg` | 1 per item | yes |
| `floodplain_landcover.gpkg` | 4 per item (8 on the four annual-span items) | **no** |

**All 23 items**, one bundle each, 108 styled layers in total (19 x 4 + 4 x 8). The COGs
are unaffected — they self-style from their RAT, and `QgsPalettedRasterRenderer` reports
10 classes on every classified COG and 100 on every transition COG. So the raster surface
is fine and the vector surface is not.

## Cause

`04_gpkg_style.py` deliberately writes **no `gpkg_contents` row** for `layer_styles`
(see `scripts/README.md`: "measured to auto-style fine without them"). That measurement
holds — but only for a GeoPackage with **no aspatial tables**.

The discriminator is an `attributes` table registered in `gpkg_contents`. Once one is
present, QGIS stops finding an *unregistered* `layer_styles`. Verified in both directions
on copies, same QGIS session:

| file | change | style found |
|---|---|---|
| `floodplain_landcover.gpkg` | as published | **no** |
| `floodplain_landcover.gpkg` | the two `attributes` tables dropped | yes |
| `floodplain.gpkg` | as published | yes |
| `floodplain.gpkg` | a dummy `attributes` table registered | **no** |
| `floodplain.gpkg` | a dummy table created but **not** registered | yes |
| `floodplain_landcover.gpkg` | `layer_styles` registered in `gpkg_contents` | **yes** |

So it is registration in `gpkg_contents`, not the table's existence, that flips it.

`floodplain.gpkg` and `transition_vector.gpkg` carry no aspatial tables, which is exactly
why they escaped — and why the original measurement was right about the file it was taken
on and wrong about this one.

## Scope in time

This is not new at v2.0.0, but v2.0.0 made it universal: the whole-network runs write both
a `patch_watercourse` and a `composition` table for **every** group, where it was 18 / 5 on
2026-10-14. Before that, the groups with no aspatial table styled correctly.

## Fix

Register `layer_styles` in `gpkg_contents` from `04_gpkg_style.py`, with `last_change`
pinned to `GPKG_EPOCH` rather than SQLite's `strftime(...,'now')` default:

```sql
INSERT INTO gpkg_contents (table_name, data_type, identifier, description, last_change, srs_id)
VALUES ('layer_styles', 'attributes', 'layer_styles', '', <GPKG_EPOCH>, 0);
```

The pin is what answers the original objection — the reason the row was left out was that
registering "adds a second wall-clock stamp that would churn `file:checksum`". Pinned, it
does not churn between rebuilds; `style_determinism-check.py` should gain an arm over it.

## Consequence

The fix changes the bytes of all 23 `floodplain_landcover.gpkg`, so every one of their
`file:checksum` values moves and the items need republishing — a patch release, not an
in-place asset swap.

## Guard

Nothing here asks QGIS whether a style is *reachable*; `style_drift-check.py` compares the
committed QML against `classes.json`, and `04_gpkg_style.py` confirms its own INSERT. Both
pass on these files. A check that opens each staged layer through QGIS and asserts the
renderer is the expected type is the one that would have caught it — the "verification that
reads its own output" shape.

`scripts/README.md` already names this exact question under "Verifying a style against QGIS
itself": *what QGIS does with a layer opened plain, with no `.qml` handed to it — which is
how a style that loads cleanly and renders nothing gets caught.* The recipe was there; it had
not been run over `floodplain_landcover.gpkg`.


## This repo is public, so the cross-repo pointers cannot be written down

`.claude/visibility` is `public`, and `feature-workflow.md` forbids naming a private sibling
repo in tracked text — "not even as provenance", because the link 404s for everyone outside the
organisation and names internal work while doing it. The two issues this work filed live in
private repos, and so does the one that recorded the NULL `f_table_schema` trap, so all of them
are described in words here instead. `planning/` is committed, so the rule reaches it too.

The repo already carries pre-existing citations of that kind in `04_gpkg_style.py` and
`item_validate.py`; #86 is open for exactly that and is where they get removed. This branch
adds none — verified with
`git diff origin/main -- . | grep -E '^\+.*(private-repo-name)#[0-9]+'`.

## Errors Encountered (2)

| Error | Resolution |
|-------|------------|
| The conventions repo was checked out on **another task's in-flight feature branch**, not main, and `git checkout -b` inherited it — so the PR opened with 10 foreign commits and 20 files, reading MERGEABLE/CLEAN the whole time | Rebuilt the branch in a throwaway `git worktree` off `origin/main`, cherry-picked the one commit, `--force-with-lease`, and restored the original checkout to the branch and dirty file it was found on. **Check `git branch --show-current` before `git checkout -b` in a repo this session did not start in** — `git log -1` alone does not tell you which branch you are on, and a clean mergeable PR is no evidence of a clean range |

## Code-check round 1 — six findings, all real, two of them in the fix itself

Full report in `review-round1.md` (scrubbed of private-repo identifiers, which was its own
first finding). Verified here before acting, and one turned out worse than reported:

| finding | verdict |
|---|---|
| the planning files still name the private siblings' internals, after a commit saying the citations were "described rather than linked" — the links went, the **names** did not | real; scrubbed, including the reviewer's own file |
| a bare `#89` meaning the sibling's issue resolves to **this** repo's #89 (the v2.0.0 cutover) | real; the number is gone, since a private repo cannot be qualified either |
| **4 of the 9 warm assertions in `style_reach-check.py` cannot fail** — `singleSymbol` is also what QGIS builds for a layer with no style | real, and the sharpest finding here; see below |
| `feature_layers(dereg)[0]` IndexErrors past `main()`, discarding every finding above it | real; guarded and named |
| a registration arriving with `data_type='features'` never reaches the repair branch | real, and **worse** than reported; see below |
| the positive arm's comment claims a scope it does not have | real; it discriminates on one bundle of three |

### The probe whose whole job is to reach the failure mode could not reach it

`EXPECT_RENDERER["floodplain"]` is `singleSymbol`, and `singleSymbol` is QGIS's default for a
layer with **no style at all**. Measured on `all_ff04`: styled gives `#1f78b4` at opacity 0.5;
the same file with `layer_styles` dropped and de-registered gives a random colour at opacity
1.0. So four of nine assertions passed identically whether that bundle's style was reachable,
unreachable or absent — on the bundle the "register all three" argument is pre-emptive for, so
nothing else covered it either.

Fixed by asserting every symbol's opacity against the committed QMLs, which carry
`alpha="0.5"` on all 102 symbols — read, not restated, and refusing on more than one distinct
value. Uniform across all three styles, so one assertion covers all nine layers. Restored the
bug: stripping `floodplain.gpkg`'s style now gives 4 named failures where it gave a green run.

The recipe this script replaced already knew: `scripts/README.md`'s #46 paragraph says
"renderer and symbol **opacity** read back from QGIS".

### `data_type='features'` on the registration, measured in both bundles

`feature_layers()` selects on `data_type='features'`, so a registration arriving with that
value puts the style table into the writer's own input, ahead of the repair branch that would
have fixed it. The reviewer measured `floodplain_landcover.gpkg` raising "layer 'layer_styles'
matches no style rule" — naming the wrong problem. Measured here, `floodplain.gpkg` is worse:
its style rule is a catch-all, so it **silently writes a style row for the style table**, and
the run reports success. Fixed by excluding the table by name in `feature_layers()` as well as
by `data_type`; both bundles now repair the row and style exactly their real layers.

## Code-check round 2 — five findings, and the mechanism named

Its mechanism statement is better than mine. Mine was "an assertion whose expected value is
also the value the failure mode produces", which covers round 1's sharpest finding and nothing
else. Round 2's:

> **#95 converted a fact that was *structural* into a value this repo's own writer now
> writes, and at the same time introduced the repo's first guards whose subject is
> *reachability* rather than *presence*.**

The single absence of a `gpkg_contents` row was doing three jobs silently: it excluded the
style table from every `data_type` filter for free, with no name anywhere; it made "the style
is there" and "the style is reachable" indistinguishable, so every presence assertion read as
a reachability one; and it kept the published prose true by accident. Registering the row
retires all three accidents at once, so the branch owes three sweeps — explicit exclusions,
a discriminator on every reachability assertion, and a re-check of every quantified claim on
every surface. Round 1 found one instance of each of the first two and the start of the third.
**Round 2's whole residue was the third: the claim sweep had run over *links* and over three
of five surfaces.**

| finding | verdict |
|---|---|
| `progress.md:9` still names a private sibling by **name** — the earlier sweep scoped itself to the `<repo>#<N>` *link* form | real; scrubbed |
| a **commit subject** names both private siblings with issue numbers, in a public repo | real; the branch was unpushed, so rewritten rather than left in published history |
| `item_create.py`'s **published** `floodplain` asset description tells the consumer to "read the layer list", which is now five entries whose fifth has no `scenario` column — the identical claim was corrected in the sibling asset ten lines above | real; this is the copy that *instructs* the enumeration |
| `scripts/README.md:272` overstates the very guard this branch changed | real |
| `style_reach-check.py` has its **own** `feature_layers()` with no name exclusion — round 1 finding 2's shape, in a second copy, raising from inside the warm loop | real; fixing one copy and not the other is how the first instance got here |

### A measurement that came out of fixing the last one

With the registration's `data_type` set to `features` in all three bundles, QGIS loses the
style in **all three** — every styled layer back to `singleSymbol` at opacity 1.0, including
the two bundles with no aspatial table that #95 never affected. So `data_type='attributes'` is
now justified by measurement rather than by citing the GeoPackage spec, and the strengthened
script reports nine named failures there where it used to raise on the first bundle.

### And one the enumeration found rather than a reviewer

`expected_opacity()`'s discriminating power is a property of the **value** 0.5, not of the
comparison: 1.0 is what QGIS gives an unstyled layer, so a style shipped at full opacity would
silently return the four `singleSymbol` assertions to the no-op they were before #95, with the
renderer-type arm already unable to tell and nothing saying so. It now refuses on 1.0, the same
shape as its refusal on more than one distinct value.
