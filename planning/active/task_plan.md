# Task: Ship the class palette with the GeoPackages: embedded layer_styles + published .qml, generated from classes.json (#46)

## Context

The published rasters are self-describing since #34/#35 — they carry a GDAL raster
attribute table, so QGIS opens them already coloured and labelled. The vectors are not.
`floodplain_landcover.gpkg` layers carry `class_name`, the transition layers carry
`from_class` / `to_class` / `transition`, and every consumer either re-derives the palette
from a COG or invents one.

That drift is not hypothetical. The hand-exported reference style supplied 2026-09-03
carries QGIS auto-ramp colours, not drift's: Trees to Water renders green, Trees to Crops
magenta, Trees to Rangeland blue. The correct io-lulc palette has those as blue, orange and
pale khaki. So the vector and raster views of the same ground already disagree.

Outcome: the three GeoPackages open in QGIS already styled, matching the RAT exactly,
with the styles also published as STAC assets for anyone merging items or styling by hand.
Everything derives from the one `data/raw/classes.json` that already feeds the RAT and
`classification:classes`, so the three surfaces cannot disagree.

**This lands as merged code with no release.** #26 rebuilds every asset days later, and a
release cut here would publish a complete public catalogue of geometry already known to be
over-mapped. One tagged release at the end of #26 carries #46, #47 and the rebuild.

## Decisions folded in

- **Gain stays switched off by default.** The style emits all 72 ordered pairs; the 8
  `Trees -> *` loss categories ship on and everything else, including the 8
  `<other> -> Trees` gain categories, ships off. #46 step 1 currently says the default
  should *draw* gain. The user's reaction to the built style was that gain being present
  but off is the wanted behaviour, so the issue text gets corrected rather than the code.
- **All vector symbols at 50% opacity.** These read over a basemap.
- **Raster opacity is out of scope** — that is #48. The COGs already self-style from their
  RAT, and an opacity-only raster QML silently wipes the palette to zero classes.
- **Styles are committed, not generated at build time**, so a human reviews what ships. A
  drift check regenerates and byte-compares, so `styles/` cannot go stale against
  `classes.json`.

## Phase 1: Lock the styles as reviewed artifacts

- [x] Rename `styles/transition_trees.qml` to `styles/transition.qml` — the file holds all
      72 categories, so the name should describe the layer, not the default view. Keeps the
      year-free naming rule that lets a `path|layername=` style survive a change of span.
- [x] Settle names: files `floodplain.qml`, `classified.qml`, `transition.qml`; asset keys
      `style_floodplain`, `style_classified`, `style_transition`. #46 currently proposes
      `landcover_class.qml`; align the issue to whichever wins.
- [x] Finalise `scripts/style_qml-write.py` (already drafted, generates all three from
      `classes.json`) and commit `styles/*.qml`.
- [x] `scripts/style_drift-check.R` (or `.py`): regenerate to a temp dir and byte-compare
      against `styles/`. Fails when `classes.json` has moved and `styles/` has not. Modelled
      on `gpkg_determinism-check.R`, which is the repo's existing standalone-check shape.
- [x] Document the generator and the check in `scripts/README.md`, which mentions neither today.

## Phase 2: Embed into the GeoPackages

- [ ] New `scripts/04_gpkg_style.py`. **Python stdlib `sqlite3` only** — the repo has no
      DBI, no RSQLite, no geopandas and no fiona, and all vector I/O goes through `sf`.
      A `layer_styles` row is a plain INSERT, so this needs no new dependency in either
      language. Schema confirmed against a QGIS-written file: `id`, `f_table_catalog`,
      `f_table_schema`, `f_table_name`, `f_geometry_column`, `styleName`, `styleQML`,
      `styleSLD`, `useAsDefault`, `description`, `owner`, `ui`, `update_time`.
- [ ] Per item directory, for each of the three GeoPackages: enumerate feature layers from
      `gpkg_contents` where `data_type = 'features'`, map each layer name to a style by
      prefix (`classified_*`, `transition*`, `<sp>_ff0N`), and insert one row with
      `useAsDefault = 1`.
- [ ] **`f_table_schema` must be `''`, never NULL.** Measured on this repo's own data:
      the empty string auto-styles (73 categories, 8 on), NULL falls back to single-symbol
      and logs nothing. This is rfp#17 reproduced here.
- [ ] **Pin both timestamps to `GPKG_EPOCH` (`2000-01-01T00:00:00.000Z`, `scripts/fp_gpkg.R`).**
      Measured: QGIS's writer does not go through OGR, so `OGR_CURRENT_DATE` misses it and
      two live wall-clock stamps land — `layer_styles.update_time` and the
      `gpkg_contents.last_change` row for the styles table. Either one churns
      `transition_vector.gpkg`'s published `file:checksum` on every rebuild.
- [ ] Leave `styleSLD` NULL. QGIS reads `styleQML`; the SLD QGIS writes alongside is 31% of
      the added bytes and nothing here consumes it.
- [ ] Insert in a fixed layer order so repeat builds are byte-identical.
- [ ] Wire into `scripts/run_pipeline.sh` and `scripts/test_pipeline.R` between step 03 and
      `item_create.py`. It must precede `item_create.py`, which is where `file:checksum` is
      computed.

## Phase 3: Repair what embedding breaks

- [ ] **`sf::st_layers()` lists `layer_styles` as a layer.** Measured on a styled copy: both
      `ogrinfo` and `sf` report it. `test_pipeline.R`'s attribute loop iterates
      `sf::st_layers(gpkg)$name` and asserts every layer carries a `wsg` column, so
      embedding makes that loop fail on a correct file. Restrict the loop to feature layers.
- [ ] Extend `scripts/gpkg_determinism-check.R`, which today covers only the
      `transition_vector.gpkg` extraction, to cover a styled file — otherwise the pin added
      in Phase 2 has no test.
- [ ] Grep for any other layer enumeration that would now see `layer_styles`.

## Phase 4: Publish the styles as STAC assets

- [ ] Copy the three `.qml` into each item directory during staging or step 04. Per-item
      copies rather than one shared object at the bucket root, because
      `item_validate.py`'s `check_checksums` asserts `href_parts[-2] == item_id`. Cost is
      about 160 KB per item.
- [ ] `scripts/item_create.py`: three new assets alongside the existing hardcoded blocks,
      each with `file_meta()` for `file:checksum` / `file:size`, media type
      `application/xml`, `roles: ["style"]`. Also update the two enumerated filename lists
      used by the preflight (around lines 361 and 382).
- [ ] `.qml` needs no sync change — verified that `catalogue_release.sh`'s excludes are
      `.*`, `*/.*`, `*.json`, `*.aux.xml`, so a `.qml` in an item directory uploads.
- [ ] `test_pipeline.R`: the hardcoded `length(item_assets) != 7L` becomes 10.

## Phase 5: Validate, and prove the guards fire

- [ ] `scripts/item_validate.py`: assert every GeoPackage carries a `layer_styles` row for
      every feature layer, that `f_table_schema` is `''` on all of them, and that the
      embedded QML's category values equal `classification:classes` on the same item. Follow
      the file's existing convention of absolute literals (`EXPECTED_RAT_ROWS`) rather than
      expectations derived from the artifact.
- [ ] **Restore each defect and watch the check go red**, per the repo's convention:
      set `f_table_schema` to NULL and confirm refusal; drop a row and confirm refusal;
      edit `classes.json` and confirm the drift check fails.
- [ ] Confirm the cross-item asset-key equality check in `check_checksums` still passes with
      three keys added uniformly.

## Verification

End to end on one real group, which is the repo's own smoke path:

```bash
WSG=kotl Rscript scripts/test_pipeline.R
Rscript scripts/gpkg_determinism-check.R
Rscript scripts/style_drift-check.R
```

Then the check that matters, against the real consumer rather than our own writer — open a
staged GeoPackage in QGIS with no style loaded by hand and read back the renderer it
chooses. The PyQGIS probe used during planning is the pattern: it reported
`QgsCategorizedSymbolRenderer`, 73 categories, 8 on, symbol opacity 0.5, and zero data
values unmatched. A style that loads is not the same as a style that auto-applies, so the
assertion must be on a layer opened plain, not on one handed a `.qml`.

Finally confirm `run_pipeline.sh` is still green end to end and that nothing publishes:
this issue closes with merged code and no tag.

## Files

- New: `scripts/04_gpkg_style.py`, `scripts/style_drift-check.R`, `styles/*.qml`
- Modified: `scripts/style_qml-write.py`, `scripts/item_create.py`,
  `scripts/item_validate.py`, `scripts/test_pipeline.R`,
  `scripts/gpkg_determinism-check.R`, `scripts/run_pipeline.sh`, `scripts/README.md`
- Reused, not duplicated: `GPKG_EPOCH` from `scripts/fp_gpkg.R`, `file_meta()` and
  `_load_classes()` from `scripts/item_create.py`


## Validation

- [ ] `WSG=kotl Rscript scripts/test_pipeline.R` green
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
- [ ] Closes as merged code — NO release, no tag (the release rides #26)
