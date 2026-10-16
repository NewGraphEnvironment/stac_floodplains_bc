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
| soul `conventions/code-check-spatial.md` | "Neither is needed — QGIS auto-styles without them … writing *less* than QGIS does removes a churn vector" — loaded by **every** repo |

## rfp carries the same shape

Not a feature request — a plausible live defect:

- `rfp/R/rfp_styles_apply.R::.rfp_layer_styles_ddl()` writes `layer_styles` with no
  `gpkg_contents` row (DDL copied from QGIS's own writer, minus the registration).
- `rfp/R/rfp_source_bcdata_pass.R::.tracking_append()` registers `rfp_tracking` with
  `data_type = 'attributes'` in a project GeoPackage.
- Under the single multi-layer project layout those land in **one** file beside styled
  feature layers — exactly the shape measured here. Under the split layout (#89) tracking
  owns its own file and the question does not arise.
- `.rfp_styles_gpkg_tables()` reads `gpkg_contents` unfiltered and excludes
  `layer_styles` only in its no-`gpkg_contents` fallback branch, so a registration there
  would also need that filter — the same break as `test_pipeline.R`'s.
- rfp already owns the QGIS oracle (`tests/testthat/helper-qgis.R`, a pinned
  `qgis/qgis` image with a version constant), which is why a reusable reachability verb
  belongs there rather than here.

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
