# Task: Publish the transition layer as its own asset (#23)

Each item ships six assets. `floodplain_landcover.gpkg` bundles the transition layer with three
dissolved `classified_*` epochs, and the epochs carry nearly all the geometry — for BULK, the three
epochs are 8-9 features each but ~23 MB of vertices against ~4 MB for the transition layer. A
consumer wanting the change layer must download the whole bundle; for a Mergin project near a
~550 MB finalize ceiling that is the difference between usable and not.

Additive: the bundle is unchanged, so every existing asset's checksum stays stable.

## Approved decisions

| Decision | Choice |
|---|---|
| Asset key **and** filename | **`transition_vector`** / `transition_vector.gpkg` — year-free |
| Layer name inside | **`transition`** — what QGIS symbology binds to |
| Determinism guard | **Check with a cold path** that must fail when the pin is disabled |

### Why year-free, all the way down to the layer

The span is `2017_2023` today, could be `2017_2025`, could be `2010_2025` on satellite data. QGIS
styles and `.qlr` files bind to `path|layername=`, so a name carrying the span breaks every
downstream style the moment the model is re-run. Asset key, filename and **layer name** all stay
abstract.

Safe here even though upstream keeps producer-keyed layer names: upstream needs them because two
species share one file; this file is per-item and single-layer, and identity is carried by the item
id plus the layer's own `wsg`/`species`/`scenario` columns. This is the "flattening to generic
layers happens downstream at merge time" the `floodplains` README anticipates.

## Findings

- **A collision that would have shipped silently.** The COG asset key is `transition_2017_2023` —
  exactly the stem of the filename the issue proposed. Keying the gpkg by its stem would have
  **overwritten the COG in the assets dict**: still 6 assets, raster gone, and `item_validate.py`
  passes because every item lost the same key uniformly.
- The layer to extract is already computed at `01_stage.R:190-193`; resolves correctly for MORR's
  two items from one shared source file. Present in all 20 items.
- **Base layer only** — MORR/BULK also carry `_fire` and `_disturbance` variants. Uniformity is what
  `item_validate.py` enforces; #6 owns disturbance.
- Use `sf::st_layers()$name`, never an `ogrinfo` regex — `-so` appends the geometry type to most
  names but *not* MORR's `transition_co_ff04_2017_2023` (declared `Unknown (any)`).
- **The pin's guarantee is bounded to a fresh file**, so the extraction must `unlink()` first.
- The issue's "38.1 MB vs 5.8 MB" is a stale single-item figure from `floodplains`. Real staged
  sizes: BULK 41.7 MB, MORR 79 MB, SLOC 6.3 MB. Phase 0 measures the real extracted size.
- `item_validate.py` needs **no change** — it derives the expected key set, so a 7th asset on all
  items passes. A partial rebuild fails, which is correct.

## Phase 0: Baseline + measure the load-bearing premise

- [ ] Snapshot live collection + 20 item JSONs from **S3** (not the API — it injects links)
- [ ] Assert local `data/stac/*.json` byte-identical to S3; md5 all 120 assets
- [ ] **Determinism probe on real data** (`sloc_bt_ff04`): extract twice without the pin → must
      DIFFER; twice with it → must be IDENTICAL. `Sys.unsetenv()` for the cold path, 1.2 s sleep
      between writes (unpinned stamp has 1 ms resolution → same-instant write is a false pass).
      Record the real extracted size.

## Phase 1: The pin and its guard

- [ ] `01_stage.R` — `Sys.setenv(OGR_CURRENT_DATE = "2000-01-01T00:00:00.000Z")`, commented with
      floodplains#45, why process-wide, and the absent-file bound
- [ ] **New** `scripts/gpkg_determinism-check.R` with a `NO_PIN=1` cold path that must fail

## Phase 2: Extract during staging

- [ ] `01_stage.R` — write `transition_vector.gpkg` (layer `transition`) into `data/stac/<item_id>/`,
      `unlink()`-ing first
- [ ] Correct the now-false "Both are copied whole" comment at `:145-147`

## Phase 3: Publish it as an asset

- [ ] `05_stac_register.py` — asset keyed `transition_vector`, with `extra_fields=file_meta(...)`
- [ ] Both preflight lists (`:220-224`, `:241-246`)
- [ ] Module docstring + **collection description** (ships to live `collection.json`)
- [ ] `test_pipeline.R` — gpkg count `2L → 3L`, membership assert, asset count `6L → 7L`, add to the
      `wsg`-column contract loop

## Phase 4: Docs

- [ ] `README.md` — Stage row, Vector assets list, "both" → all three
- [ ] `scripts/README.md` — Stage row, smoke-test prose, and the `:34-35` claim that GeoPackages are
      "never rewritten here", which this change makes **false** and which is load-bearing for the
      checksum reasoning

## Phase 5: Publish + verify

- [ ] **Open sequencing question, deferred to here with evidence in hand**: this needs a re-stage
      (unlike #22), but upstream is mid-remodel (#26), so a full re-stage publishes a mixed-vintage
      catalogue. Decide then whether to stage now or wait for #26.
- [ ] Structural diff vs live: only the added asset + its `file:*`
- [ ] `item_validate.py` (key sets uniform across all 20), then `catalogue_release.sh`
- [ ] Verify live; download `transition_vector.gpkg` from S3, confirm checksum and that the layer
      inside is named `transition`

## Validation

- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
