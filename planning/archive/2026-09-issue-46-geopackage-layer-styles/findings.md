# Findings — Ship the class palette with the GeoPackages: embedded layer_styles + published .qml, generated from classes.json (#46)

## Issue context

## What changes if we do it

The three GeoPackages open in QGIS already styled — the same class colours and names the COGs carry in their RAT — with no `.qml` to hunt for, and a `.qml` asset published beside them for anyone who merges items or styles by hand.

## What happens if we never do

The rasters are self-describing (#34/#35: RAT + `classification:classes`) and the vectors are not: `floodplain_landcover.gpkg` layers carry `class_name`, the transition layers carry `from_class` / `to_class` / `transition`, and every consumer re-derives the palette from the COG or invents one. Colours drift between the raster and vector views of the same ground.

**That drift is not hypothetical — it is what the reference export does.** See "Measured 2026-09-03" below.

## Shape

Everything derives from the one `data/raw/classes.json` that already feeds the RAT and `classification:classes` (drift's `dft_class_table("io-lulc")`), so the three surfaces cannot disagree.

1. **Generate two QML renderers per item at staging**, from `classes.json`:
   - `classified_*` layers: categorized on `class_name`, colour per class, label = class name.
   - `transition*` layers, **two styles**. The default is tree-focused: `Trees -> <other>` (the gross-loss patches) and `<other> -> Trees` (gain) drawn, everything else receded — it is the map of the figures we publish (`gross_loss_ha` / `gross_gain_ha` / `net_ha`). The second is the full palette: categorized on `transition`, destination-coloured (the same choice as the transition COG); label = `transition` string.
2. **Embed them in each GeoPackage's `layer_styles` table** as the default style, so QGIS applies them on load. Layer names carry `<sp>_ff0N` / years, so the rows are written per item. **Both traps below are now measured in this repo's own data rather than inherited from rfp#17 — see "Measured".** `f_table_schema` must be `''`, not NULL; and **two** timestamps churn, not one.
4. **Publish the `.qml` files as STAC assets** (`roles: ["style"]`) on every item, for merged multi-item GeoPackages and for consumers that disable default styles. Names year-free (`landcover_class.qml`, `transition.qml`) for the same reason `transition_vector.gpkg` is: a `path|layername=` style survives a change of span.
5. `item_validate.py`: assert every GeoPackage carries a `layer_styles` row per layer and that the QML's categories equal `classification:classes` on the same item — the absolute check that keeps the vector palette tied to the raster one.

3. **`floodplain.gpkg`** (bt_ff02 / bt_ff04 / bt_ff06) has no class attribute, so one single-symbol fill serves all three layers: ColorBrewer Paired blue `#1f78b4`, no outline, matching the hand-tuned reference (airvine, 2026-09-03).

**All vector symbols ship at 50% opacity.** These layers are read over a basemap, and shipping it beats every consumer reaching for the slider. Raster opacity is a different problem and is now **#48** — the COGs already self-style from their RAT, and an opacity-only raster QML silently wipes that palette.

## Measured 2026-09-03

All figures from `data/stac/kotl_bt_ff04` and QGIS 4.2.1 via PyQGIS, opening layers with no style loaded by hand.

**The reference export's colours are QGIS auto-ramp, not drift's palette.** Every fill in the hand-exported tree-focused QML carries an `hsv:` spelling, which is what QGIS writes when colours come from a ramp rather than being set. Trees -> Water renders green, Trees -> Crops magenta, Trees -> Rangeland blue; io-lulc has those classes as blue, orange and pale khaki. This is the colour drift in "What happens if we never do", already present in the artifact we were about to treat as a starting point. It confirms the existing instruction to derive from `classes.json` and supplies the reason.

**The vector carries no no-change diagonal.** `SELECT COUNT(*) FROM transition WHERE from_class = to_class` is 0 — the producer already excludes it. So the "hold the diagonal to the RAT's grey" clause applies to the transition **raster** only, and the full-palette vector style is 9x8 = **72** categories, not 81. Dropped from step 1 above.

**Embedding works, and the NULL trap is real here.** Same file, same style, one column different:

| `f_table_schema` | renderer on plain open | auto-styled |
|---|---|---|
| `''` | `QgsCategorizedSymbolRenderer`, 73 categories, 8 on | yes |
| `NULL` | `QgsSingleSymbolRenderer` | no |

The NULL case logs nothing. It is the rfp#17 failure exactly, now reproduced on this repo's data.

**Two churn vectors, not one.** `OGR_CURRENT_DATE` pins the `transition` row in `gpkg_contents` to `2000-01-01T00:00:00.000Z`, but QGIS's style writer does not go through OGR, so it lands two live wall-clock stamps:

| where | value written |
|---|---|
| `layer_styles.update_time` | `2026-09-03T20:48:05.000Z` |
| `gpkg_contents.last_change` for the `layer_styles` row | `2026-09-03T20:48:05.789Z` |

Either one churns `transition_vector.gpkg`'s published `file:checksum` on every rebuild. Step 2 previously named only the first. Pin both, and extend `gpkg_determinism-check.R` to the styled files.

**Size cost**, `transition_vector.gpkg`: 3,878,912 -> 4,091,904 bytes, +208 KB or +5.5%. QGIS writes an SLD (64,277 chars) alongside the QML (145,752 chars) in the same row; the SLD is free interop for anything that reads SLD but is 31% of the added bytes if we would rather not carry it.

**Legibility decision still open.** Colouring by destination class is what the transition COG does, so it keeps the raster and vector views in agreement. But it renders the headline category nearly invisible on a light basemap:

| destination | ha (kotl, from Trees) | share of tree loss | contrast vs white |
|---|---|---|---|
| Rangeland | 387.7 | 62% | 1.32 |
| Built Area | 165.6 | 27% | 5.73 |
| Water | 54.9 | 9% | 3.01 |
| Snow/Ice | 0.2 | <1% | 1.31 |

Agreement with the raster and legibility of the largest number are in direct conflict here. Pick one deliberately rather than by default.

## Verification

Open a downloaded `floodplain_landcover.gpkg` and `transition_vector.gpkg` in a fresh QGIS profile: layers load styled without touching the style panel, and the legend names and colours match the COG's RAT for the same item. Then the same on a merged two-item GeoPackage using the published `.qml`.

Assert the NULL case as well as the `''` case — a guard that only ever sees a correct row cannot show the failure it exists to catch.

## Status

Raised 2026-09-03 after the first look at the v1.0.0 layers in QGIS. Deferred until after the remodel release (#26).

**The generator does not depend on #26.** Styles derive from `classes.json`, not from item data, so they can be built and reviewed now; only the embedding's output is thrown away by a rebuild, and that output is regenerated by the same staging step. A first pass exists locally: `scripts/style_qml-write.py` generating `styles/floodplain.qml`, `styles/classified.qml` and `styles/transition_trees.qml`.

Verified 2026-09-03 by loading each onto its real layer in QGIS 4.2.1 and reading back the resulting renderer:

| style | layer | renderer | symbols | on | symbol opacity | data values unmatched |
|---|---|---|---|---|---|---|
| floodplain.qml | `bt_ff04` | single symbol | 1 | — | 0.5 | — |
| classified.qml | `classified_bt_ff04_2023` | categorized | 9 | 9 | 0.5 | 0 of 8 |
| transition_trees.qml | `transition` | categorized | 73 | 8 | 0.5 | 0 of 47 |

**Gain is already covered.** An earlier revision of this body said the first pass was loss-only. That was wrong: the style emits all 72 ordered pairs, so the 8 `<other> -> Trees` gain categories are present and switched off, exactly like the other 56. Step 1's tree-focused default needs them *drawn* rather than merely present, which is a one-line change to which categories ship with `render="true"`.




## Measured during planning, 2026-09-03

All figures from `data/stac/kotl_bt_ff04` and QGIS 4.2.1 via PyQGIS.

### The reference export's colours are QGIS auto-ramp, not drift's

Every fill in the hand-exported tree-focused QML carries an `hsv:` spelling, which is what
QGIS writes when colours come from a ramp. Trees to Water renders green, Trees to Crops
magenta, Trees to Rangeland blue; io-lulc has those as blue, orange and pale khaki. drift's
palette is `drift/inst/lulc_classes/io_lulc_v02.csv`, identical to this repo's `classes.json`.

### The vector carries no no-change diagonal

`SELECT COUNT(*) FROM transition WHERE from_class = to_class` is 0. The full-palette vector
style is 9x8 = 72 categories, not 81. The diagonal exists in the transition *raster* only.

### Embedding works; the NULL trap is real here

Same file, same style, one column different:

| `f_table_schema` | renderer on plain open | auto-styled |
|---|---|---|
| `''` | `QgsCategorizedSymbolRenderer`, 73 categories, 8 on | yes |
| `NULL` | `QgsSingleSymbolRenderer` | no |

The NULL case logs nothing. rfp#17 reproduced on this repo's data.

### Two churn vectors, not one

`OGR_CURRENT_DATE` pins the `transition` row in `gpkg_contents` to `2000-01-01T00:00:00.000Z`,
but QGIS's style writer does not go through OGR, so it lands two live wall-clock stamps:

| where | value written |
|---|---|
| `layer_styles.update_time` | `2026-09-03T20:48:05.000Z` |
| `gpkg_contents.last_change` for the `layer_styles` row | `2026-09-03T20:48:05.789Z` |

Size cost on `transition_vector.gpkg`: 3,878,912 -> 4,091,904 bytes, +208 KB, +5.5%.
QGIS writes an SLD (64,277 chars) beside the QML (145,752 chars); we omit the SLD.

### `layer_styles` is visible to OGR and sf as a layer

Both `ogrinfo` and `sf::st_layers()` list it (`2: layer_styles (None)`). `test_pipeline.R`'s
attribute loop iterates `sf::st_layers(gpkg)$name` and demands a `wsg` column from every
layer, so embedding makes that loop fail on a correct file. Phase 3 repairs it.

### Verification of the three drafted styles

Loaded onto their real layers in QGIS 4.2.1, renderer read back:

| style | layer | renderer | symbols | on | opacity | unmatched |
|---|---|---|---|---|---|---|
| floodplain.qml | `bt_ff04` | single symbol | 1 | — | 0.5 | — |
| classified.qml | `classified_bt_ff04_2023` | categorized | 9 | 9 | 0.5 | 0 of 8 |
| transition.qml | `transition` | categorized | 73 | 8 | 0.5 | 0 of 47 |

8 `<other> -> Trees` gain categories present and switched off.

### Legibility conflict, still open as a design call

Destination colouring agrees with the transition raster but hides the largest number:

| destination | ha (kotl, from Trees) | share of tree loss | contrast vs white |
|---|---|---|---|
| Rangeland | 387.7 | 62% | 1.32 |
| Built Area | 165.6 | 27% | 5.73 |
| Water | 54.9 | 9% | 3.01 |
| Snow/Ice | 0.2 | <1% | 1.31 |

### Repo facts that shape the implementation

- No DBI, RSQLite, geopandas or fiona anywhere; all vector I/O goes through `sf`. Python
  stdlib `sqlite3` is the zero-dependency route for writing `layer_styles`.
- `catalogue_release.sh` excludes only `.*`, `*/.*`, `*.json`, `*.aux.xml`, so a `.qml` in
  an item directory syncs to S3 with no change.
- `item_create.py` asset blocks are hand-written per asset, plus two enumerated filename
  lists in the preflight (around lines 361 and 382).
- `item_validate.py`'s `check_checksums` asserts `href_parts[-2] == item_id`, which forces
  per-item `.qml` copies rather than one shared object at the bucket root.
- `test_pipeline.R` hardcodes `length(item_assets) != 7L`.
- `GPKG_EPOCH <- "2000-01-01T00:00:00.000Z"` in `scripts/fp_gpkg.R` is the pin to reuse.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| An opacity-only raster QML reports ok and wipes the palette to 0 classes | Out of scope here; raised as #48 |
| `layerOpacity` silently ignored on a raster layer | Raster opacity lives on `<rasterrenderer>`; #48 |
| `gh issue edit` ran after a failed patch, rewriting the body unchanged | Chain the patch and the edit with `&&` |
