# Progress — Ship the class palette with the GeoPackages: embedded layer_styles + published .qml, generated from classes.json (#46)

## Session 2026-09-03

- Plan-mode exploration across staging, item build/validate and the release path — phases approved by user
- Created branch `46-ship-the-class-palette-with-the-geopacka` off main
- Scaffolded PWF baseline from issue #46 with approved phases
- Carried in from the pre-branch session: `scripts/style_qml-write.py` and three generated
  styles in `styles/`, all three verified loading in QGIS 4.2.1
- Decisions locked: gain categories ship present-but-off; 50% symbol opacity; styles
  committed and drift-checked rather than generated at build time; closes with NO release
- Next: Phase 1 — rename `transition_trees.qml`, settle asset names, add the drift check

### Phase 1 — done

- `transition_trees.qml` renamed to `transition.qml`; names settled as `floodplain.qml` /
  `classified.qml` / `transition.qml`, asset keys `style_floodplain` / `style_classified` /
  `style_transition` (applied in Phase 4)
- `scripts/style_qml-write.py` gained `build_all()` as its single entry point
- `scripts/style_drift-check.py` added, two-sided on the file set and the bytes, and refusing
  when it compared nothing
- **The drift check found a real defect on its first run.** The generator used `uuid4()` for
  symbol-layer and category ids, so every run emitted different bytes at identical length —
  the committed styles could never have been byte-compared, and the embedded copy would have
  churned `transition_vector.gpkg`'s published `file:checksum` on every rebuild. Replaced with
  `uuid5` over a fixed namespace and stable keys. Two independent runs now produce identical
  sha256 for all three files.
- Both drift arms proven to fire: a perturbed committed style exits 1, an uncommitted
  generator output exits 1
- Re-verified in QGIS 4.2.1 after the UUID change — all three still load, opacity 0.5,
  0 data values unmatched, 8 gain categories present and off
- Documented in `scripts/README.md`

### Phase 2 — done

- `scripts/04_gpkg_style.py` added, stdlib `sqlite3` only, wired into `run_pipeline.sh`
  and `test_pipeline.R` between step 03 and `item_create.py`
- **Two design improvements over what QGIS's own writer produces**, both measured:
  - No `gpkg_contents` row and no triggers. QGIS auto-styles perfectly without them, and
    registering the table would add a second wall-clock stamp (`gpkg_contents.last_change`)
    on top of `layer_styles.update_time`. GDAL lists `layer_styles` as a layer either way,
    so the registration bought nothing and cost a churn vector. One vector remains, pinned.
  - `update_time` read from `fp_gpkg.R`'s `GPKG_EPOCH` rather than restated, so the pin has
    one source.
- **Determinism took two attempts.** One pass over a virgin file is byte-reproducible, but a
  second pass was not: SQLite bumps its header change counter on any write transaction and a
  DELETE leaves freelist pages, so rewriting identical rows still moved the bytes. Now the
  rows are compared first and the write skipped when they match. Three consecutive passes
  give one digest on all three files.
- An unmapped layer raises rather than being skipped — a new or renamed upstream layer must
  not ship unstyled while its neighbours look correct.
- Verified in QGIS 4.2.1: all 8 layers across the 3 GeoPackages auto-style on a plain open
  with no `.qml` loaded — 3 single-symbol, 3 categorized at 9 classes, 2 categorized at 73,
  every symbol at opacity 0.5.
