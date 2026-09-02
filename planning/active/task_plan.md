# Task: Embed class labels in the published COGs, and declare them in STAC (#34 + #35)

Published rasters carry class codes with nothing that says what they mean. The classified
COGs are Byte with a 256-entry colour table and no labels; the transition COG is int32
encoded `from x 1000 + to` with no colour table at all, and ~91% of its valid cells are
no-change. The mapping already exists upstream in `drift::dft_class_table("io-lulc")` and
is dropped on republish.

## Phase 1: Ferry the class table from drift

- [ ] `01_stage.R` writes `data/raw/classes.json` from `drift::dft_class_table("io-lulc")`
- [ ] Absolute floor: non-empty, expected code set, `#RRGGBB` colours — a short table is a
      uniform defect no cross-item check can see
- [ ] Record `drift` version; reconcile against `meta$drift_version` (warn on null, stop on differ)
- [ ] Fix the adjacent unchecked `file.copy()` on the rasters (gpkg copies are already guarded)

## Phase 2: Author the RAT beside the staged rasters

- [ ] `02_raster_tag.py` writes `data/raw/<item>/<raster>.tif.aux.xml` via ElementTree
- [ ] `xml_declaration=False` — GDAL silently ignores a PAM sidecar carrying one
- [ ] Written UNCONDITIONALLY, before the tag skip-check, so a skipped raster still gets a RAT
- [ ] Classified: 9 base classes. Transition: 81 from->to combos, changed = destination
      colour, no-change = one muted grey
- [ ] GDAL usage flags MinMax/Name/Red/Green/Blue/Alpha — QGIS resolves a RAT by usage

## Phase 3: Replace terra with a CreateCopy COG writer

- [ ] `03_cog.R` -> `03_cog.py` using `rasterio.shutil.copy(driver="COG")`
- [ ] Preserve per-file failure counting + non-zero exit; add the missing zero-input floor
- [ ] Explicit `OVERVIEW_RESAMPLING=NEAREST`; create the destination dir
- [ ] Update `run_pipeline.sh`, `test_pipeline.R`, and the `.tif.aux.json` rationale comments

## Phase 4: Declare classification:classes in the STAC items

- [ ] Extension v2.0.0 URL in `stac_extensions`; classes on every raster asset
- [ ] Slugged `name` (no spaces, no `/`), readable form in `title`, `color_hint` without `#`
- [ ] Assert slug injectivity — `uniqueItems` cannot catch a collision when `value` differs
- [ ] Built from `classes.json`, so RAT and STAC cannot disagree by construction

## Phase 5: Guard it so a label cannot vanish silently

- [ ] `check_cog_rat()` — RAT present in TIFF tag 42112 (embedded, not a sidecar) AND
      `ds.files == [local]`; parser refuses what it cannot parse rather than reporting absent
- [ ] Absolute expected row counts per asset kind — the schema validates an item with ZERO
      classes, so pystac cannot catch a uniform loss
- [ ] Every code present in the transition raster has a RAT row (catches an upstream scheme change)
- [ ] Overview values are a subset of base values (catches a resampling fallback)
- [ ] Independent oracle in `test_pipeline.R`: decoded labels vs `transition_vector.gpkg`
- [ ] Zero-comparison branch on every new loop; differences computed before gating

## Validation

- [ ] `WSG=bulk Rscript scripts/test_pipeline.R` green
- [ ] Labels reachable under titiler's own GDAL config (`EMPTY_DIR` + `.tif`-only)
- [ ] No COG regression: block size, overviews, IFD offset, all tags
- [ ] Each new guard seen to FAIL against a restored defect
- [ ] `/code-check` clean on each commit
- [ ] `/planning-archive` on completion
