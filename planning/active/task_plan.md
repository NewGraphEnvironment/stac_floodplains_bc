# Task: QGIS cannot find the embedded styles in floodplain_landcover.gpkg on all 23 published items (#95)

Every published `floodplain_landcover.gpkg` carries a correct `layer_styles` row per
feature layer, and **QGIS does not find any of them**. The layer opens with a random
single symbol instead of the 10-class `classified` or 91-category `transition` style.

**The mechanism is GDAL's, not QGIS's** — measured here 2026-10-16 and a correction to the
issue body. The GPKG driver's `LIST_ALL_TABLES=AUTO` default surfaces a table that
`gpkg_contents` does not register **only** while the file declares no aspatial content.
Once a `data_type='attributes'` row is present, GDAL stops *listing* the unregistered
`layer_styles`, and QGIS's style lookup goes through GDAL's layer list. Reproduced on
GDAL 3.8.5 (`sf`), 3.12.4 (QGIS 4.2.1's own) and 3.13.0 (homebrew): the table is hidden in
`floodplain_landcover.gpkg` and listed in the other two bundles, and
`-oo LIST_ALL_TABLES=YES` brings it back. So this is a decade-old heuristic rather than a
4.2.1 regression, `LIST_ALL_TABLES` is consumer-side and unreachable from the published
bytes, and **registering the table is the only in-file fix**.

`floodplain_landcover.gpkg` carries `patch_watercourse_*` and `composition_*`; the other
two bundles carry none, which is exactly why they escaped. v2.0.0 made it universal — the
whole-network runs write both aspatial tables for every group, where it was 18 / 5 on
2026-10-14.

Consequence: the fix moves the bytes of every bundle it registers, so their
`file:checksum` values move and the items need republishing — `v2.0.1`, cut from a **full
`run_pipeline.sh` rebuild** and never from an in-place repair of the existing tree, whose
extra write transactions give different bytes for identical content.

## Phase 0: Capture the broken witness before anything wipes it

`01_stage.R` unlinks `data/raw` and `data/stac` unconditionally, before any `WSG_ONLY`
filtering, and `data/stac` is gitignored — so the first smoke test destroys the only local
copy of the published v2.0.0 state.

- [x] Copy `sloc_all_ff04`'s three bundles and the 246 staged asset digests to the
      scratchpad as the before-arm witness.

## Phase 1: Register `layer_styles`, pinned (`scripts/04_gpkg_style.py`)

Register in **all three** bundles, not just the landcover one: `01_stage.R` already
anticipates an aspatial family appearing in `floodplain.gpkg` and would stage it, and on
that day that bundle's styles would die exactly as the landcover bundle's did. Uniform
registration makes reachability a property of the file instead of of a GDAL heuristic.

- [x] Add the `gpkg_contents` registration to `style_gpkg()`, matching what GDAL itself
      wrote for the sibling `attributes` rows in these same files: `identifier` =
      `table_name`, `description` `''`, bbox columns NULL, `srs_id` 0, `last_change` =
      the `epoch` argument `style_gpkg()` already receives (not a second read of
      `gpkg_epoch()`, so the determinism check's cold path drives it through one source).
- [x] `data_type` must be `attributes`: `features` needs a `gpkg_geometry_columns` row and
      breaks the layer, `aspatial` is the retired GDAL extension and needs a
      `gpkg_extensions` row, and `attributes` is GPKG 1.2 core and what GDAL wrote for
      `composition_*` here. Record that `ogrinfo -so` reads the registered table cleanly
      with **no** `gpkg_ogr_contents` row and no feature-count triggers — measured, not
      assumed, so the writer's refusal to write GDAL's extra bookkeeping is justified.
- [x] Fold the registration into the skip-if-current comparison, which today reads only
      the `layer_styles` rows. A re-run over a correct file must stay a byte no-op, and a
      file whose style rows match but whose registration is missing must **not** be
      skipped.
- [x] The write must be conditional, not a bare INSERT. `gpkg_contents.table_name` is the
      PRIMARY KEY and `identifier` is UNIQUE, so any run where the style rows differ while
      the registration is already correct — a regenerated `styles/*.qml`, a new class
      table — would raise `IntegrityError`. `UPDATE`-or-`INSERT`, never `REPLACE`, which
      reassigns the rowid.
- [x] Rewrite the two docstring claims this falsifies: "registering the table adds a
      second wall-clock timestamp … the registration buys nothing", and "GDAL lists
      `layer_styles` as a layer either way" — the exact premise that shipped #95.
- [x] Confirm `feature_layers()` is unaffected (`data_type = 'features'`), so the new row
      cannot feed back into the writer's own input.

## Phase 2: The two guards that must fail when the registration is absent

- [x] `scripts/item_validate.py` — new arm in `check_layer_styles()`, per styled
      GeoPackage: exactly one `gpkg_contents` row for `layer_styles`, `data_type`
      `attributes`, `last_change` = `GPKG_EPOCH`. Read the pin from `scripts/fp_gpkg.R`
      with the idiom `sync_excludes()` uses for `catalogue_release.sh`. Stays at the SQL
      level — this is the one script `catalogue_release.sh` gates on, `osgeo` is
      unavailable under `uv`, and shelling out to `ogrinfo` would add an undeclared CLI
      dependency to the release path. Extend the summary line so an operator reads the
      claim that the table is registered.
- [x] `scripts/style_determinism-check.py` — strip the registration row as well as
      `DROP TABLE layer_styles` in setup, so both arms start from the virgin shape and the
      registration write is exercised; add a warm-path arm asserting the written row
      carries the pin.
- [x] A second warm-only arm for the conflict path, which no existing arm can reach: drop
      `layer_styles` while **keeping** its `gpkg_contents` row, call `style_gpkg()`, and
      assert it does not raise and leaves exactly one registration row.
- [x] Prove both new guards fail on purpose: `item_validate.py` over a copied tree with
      the registration rows deleted must report one problem per item naming the
      consequence; the determinism arm must go red against a wall-clock `last_change`.

## Phase 3: The three R readers of `gpkg_contents` that break

All three break the moment a tree is built with the new writer, so they land in the same
commit as Phase 1.

- [x] `scripts/gpkg_determinism-check.R` (~line 121) takes its layer set from the
      **staged** file with `data_type IN ('features','attributes')` and hands it to
      `gpkg_copy_layers()` against the **producer's** file, which has no `layer_styles` —
      so `gpkg_copy_layers()` stops with `Couldn't fetch requested layer`. Hits both
      multi-layer arms. Exclude `layer_styles` in that query and say in the comment why a
      staged-side list now needs filtering.
- [x] `scripts/test_pipeline.R::keyed_layers()` feeds the per-layer key arm, the
      source-set equality arm (whose `expect` comes from the producer's file) and the
      absolute floor. Exclude `layer_styles` by name.
- [x] Pair the name-based exclusion with a **positive** arm —
      `"layer_styles" %in% sf::st_layers(gpkg)$name` for each bundle. This is the
      GDAL-level predicate itself (sf's GDAL 3.8.5 reproduces the heuristic exactly,
      measured), it needs no new dependency, and it is what stops a name-based exclusion
      hiding a disappearance. It also answers soul's "filter on the property, never on the
      name" rule, which the exclusion alone would contradict.
- [x] Rewrite the comment block at `test_pipeline.R` 369–381, whose structural-exclusion
      rationale this fix falsifies, keeping the "a filter that removed everything" guard.

## Phase 4: `scripts/style_reach-check.py` — ask QGIS what it actually draws

Not redundant with Phase 3: GDAL listing the table is **necessary but not sufficient** for
QGIS to apply the style — rfp#17's NULL `f_table_schema` is the standing proof that a
listed, well-formed row can still open unstyled. This is the end-consumer witness, and the
question #95 proves was never asked of this bundle. Runs under the QGIS bundle's own
python, so — like `fp_provenance-check.R`, `stage_years-check.R`, `year_sets-check.py` and
`prov_fields-check.py` — it is **not** in `run_pipeline.sh`.

- [ ] Warm arm: for one staged item (`ITEM=` overridable), open every styled layer of all
      three bundles plain through `QgsVectorLayer` — no `.qml` handed to it — and assert
      `isValid()`, the expected renderer type, and the category count for the two
      categorized styles.
- [ ] Cold arm, **landcover only**. De-registering `floodplain.gpkg` or
      `transition_vector.gpkg` returns them to a state where AUTO still lists the table and
      QGIS still finds the style, so a per-bundle cold arm would report two false failures.
      The arm either names the landcover bundle or injects an `attributes` row first.
- [ ] Runner: the recipe in `scripts/README.md` under "Verifying a style against QGIS
      itself" — `PROJ_DATA`/`PROJ_LIB`/`GDAL_DATA`, the bundle's `python3.12` on
      `PYTHONPATH`, `QT_QPA_PLATFORM=offscreen`, PyQt6 enum access. Prefix from
      `QGIS_PREFIX` with the installed path as default, refusing by name when absent
      rather than half-running.
- [ ] Expected-renderer map: one literal here, **statically** compared against
      `item_validate.py`'s `EXPECT_RENDERER` (it cannot be imported — `item_validate.py`
      pulls pystac, which QGIS's python does not have), the shape `prov_fields-check.py`
      uses over the four publish-side copies.
- [ ] Writes only to a temp directory; never touches `data/`.

## Phase 5: Prose and NEWS — the stale claim is in seven tracked places

- [ ] `scripts/04_gpkg_style.py` — the two docstring claims (Phase 1).
- [ ] `scripts/fp_gpkg.R` (~117–119 and ~125–130) — "GDAL lists tables `gpkg_contents`
      does not register (`layer_styles` is one, verified on a styled file)". True on two
      bundles, false on the third: the measurement was taken on the wrong file.
- [ ] `scripts/test_pipeline.R` 369–371 — "`st_layers()` returns it alongside the real
      ones" (Phase 3).
- [ ] `scripts/README.md` — the step-04 row in the rebuild table; the "Verifying a style
      against QGIS itself" section gains the new script, the GDAL mechanism and the
      `ogrinfo` two-command proof; a `style_reach-check.py` entry beside the other
      hand-run checks.
- [ ] `CLAUDE.md` — the `styles/` paragraph; and the "two tables this repo does not
      describe" paragraph, which calls those tables "inert there" when they are the thing
      that flipped the behaviour.
- [ ] The "every layer carries wsg/species/scenario" claim, which GDAL already falsifies
      on two bundles today and on all three after the fix: `scripts/item_create.py`
      (**published** in every item document), `CLAUDE.md`, `README.Rmd` and the generated
      `README.md`. Qualify to data layers. A full re-render is release step 6 and reads the
      live API, so the one sentence is corrected in both files identically instead.
- [ ] `NEWS.md` — `## v2.0.1` entry: the GDAL mechanism, what republishes, and the count.
- [ ] Correct the issue body: it attributes the behaviour to QGIS, and the discriminator is
      GDAL's `LIST_ALL_TABLES=AUTO`.

## Phase 6: Cross-repo — the same claim lives outside this repo

- [ ] **soul**: `conventions/code-check-spatial.md` needs **both** adjacent paragraphs
      rewritten, not one. "Neither is needed — QGIS auto-styles without them … writing
      *less* than QGIS does removes a churn vector" is false; and the bullet above it says
      "GDAL lists non-spatial tables as layers … with or without a `gpkg_contents` row",
      which is the premise that shipped this bug. Its "filter on the property, never on the
      name" advice stays right and now needs the positive-arm companion. Correcting a soul
      convention needs an issue first (the blast-radius rule): file it with the
      three-GDAL measurement, then correct both paragraphs in a separate soul commit.
- [ ] **rfp**: file a defect issue, not a feature request. `.rfp_layer_styles_ddl()` writes
      `layer_styles` with no `gpkg_contents` row and `.tracking_append()` registers
      `rfp_tracking` as `data_type='attributes'`; under the single multi-layer project
      layout those land in one file beside styled feature layers — the shape measured here.
      `.rfp_styles_gpkg_tables()` would also need the same exclusion. rfp is the right
      long-term home for a reusable reachability verb: it already owns the QGIS oracle
      (`tests/testthat/helper-qgis.R`, a pinned `qgis/qgis` image) and the style-writing
      exports. This repo does not depend on rfp and should not grow one for a hand-run
      check, so Phase 4's script stays local; the issue carries the recipe.

## Validation

- [ ] `uv run python scripts/style_determinism-check.py` and `NO_PIN=1 …`
- [ ] `Rscript scripts/gpkg_determinism-check.R` and `NO_PIN=1 …` — all three arms
- [ ] `WSG=sloc Rscript scripts/test_pipeline.R`, twice, with
      `shasum -a 256 data/stac/sloc_all_ff04/*.gpkg` diffed between runs: cross-build byte
      equality, which no existing check covers end to end (the determinism check compares
      two copies that each went through the same setup).
- [ ] `bash scripts/catalogue_release-check.sh`
- [ ] `/code-check branch` before the PR, three-round floor
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion

**Not in this work** (operator, after merge): the full `run_pipeline.sh` rebuild, re-taking
`PROVENANCE_FLOOR` and `PROV_CENSUS` from that build, the `v2.0.1` tag,
`catalogue_release.sh`, and the README re-render that follows a republish.
