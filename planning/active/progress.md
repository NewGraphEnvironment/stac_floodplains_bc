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

### Phase 3 — done

- Confirmed the break before fixing it: the unmodified `test_pipeline.R` loop errors with
  `layer 'layer_styles' ... has no wsg column` against a styled GeoPackage.
- Fixed by filtering to layers that HAVE a geometry, not by excluding the name
  `layer_styles` — a name test would pass the day a second non-spatial table appears. The
  filter refuses if it removed everything, so it cannot make the assertions vacuous.
- Audited the other two `st_layers()` callers: `fp_gpkg.R:65` and `01_stage.R:294` are a
  membership test and a `setdiff` against a needed set, both of which tolerate an extra
  layer. Neither needed changing.
- `scripts/style_determinism-check.py` added rather than extending the R check: the style
  pin is a different mechanism in a different language, and `OGR_CURRENT_DATE` cannot reach
  a row written through `sqlite3`. Warm, cold and re-run-is-a-no-op arms all pass.
- The check's first run failed usefully — the writer refused a temp file named
  `a_floodplain.gpkg` because it keys its style map on the basename. That is the production
  behaviour we want, so the check moved to subdirectories instead.

### Phase 4 — done

- `04_gpkg_style.py` now also copies the three `.qml` into each item directory, writing
  only when the bytes differ so an unchanged rerun does not move an mtime.
- `item_create.py` publishes them as `style_floodplain` / `style_classified` /
  `style_transition`, media type `application/xml`, `roles: ["style"]`, each with
  `file:checksum` and `file:size` from the existing `file_meta()`.
- Keys are prefixed rather than named for the file stem, deliberately: `floodplain` and
  `transition_vector` are already asset keys, so a stem-keyed style would replace a data
  asset and leave the asset count unchanged — the same trap the `transition_vector`
  comment in that file already describes.
- Both preflight filename lists extended from `STYLE_ASSETS`, so the list has one source.
- `test_pipeline.R`: asset count 7 -> 10, plus per-key presence and a `roles == ["style"]`
  assertion, since a count alone cannot tell a style from a replaced data asset.
- Built and validated: 10 assets on `kotl_bt_ff04`, `item_validate.py` green including its
  re-hash of every asset.

### Phase 5 — done

- `check_layer_styles()` added to `item_validate.py`: every feature layer carries a style
  row, `f_table_schema` is `''`, `useAsDefault` is 1, and — the arm that matters — the
  embedded QML's categories are compared against **this item's own**
  `classification:classes`, so a vector legend that disagrees with the raster of the same
  ground is refused. Absolute literals (`STYLED_GPKGS`, `EXPECTED_STYLE_CATEGORIES`),
  matching the file's existing convention, and it refuses if it opened nothing.
- The comparison has to translate: the producer writes the vector's `transition` column
  with an ASCII arrow and the RAT's titles with U+2192. Both deliberate, so the check
  converts rather than assuming they match.
- **The first restore-the-bug run was a false pass, and checking the message is what
  caught it.** All five mutations exited 1, but none printed a style message: mutating the
  GeoPackage changes its bytes, so `check_checksums` fired first and short-circuited. The
  proofs only mean anything with `item_create.py` re-run in between so the checksums match.
- Six arms, each fired for its own reason after that fix: NULL `f_table_schema`, a missing
  row, no table at all, `useAsDefault = 0`, a colour disagreeing with the raster, and a
  category the raster does not name.
- One of those six needed a second attempt too: ElementTree escapes the arrow as `-&gt;`
  in the raw file, so a plain string replace on `styleQML` matched nothing and the test
  silently mutated nothing. A test artifact, not a code defect — the validator parses the
  XML and sees the unescaped value.
- Full `WSG=kotl Rscript scripts/test_pipeline.R` green end to end, and all three
  standalone checks pass on both arms.

### Known limitation, stated rather than papered over

`check_checksums`'s cross-item asset-key equality check cannot discriminate on a
single-item tree: with one item, the largest observed key set IS that item's set. The
three style keys were verified present by the absolute count in `test_pipeline.R` (10) and
by per-key assertions, which is the pairing this repo already prescribes for that blind
spot (#23). A full `run_pipeline.sh` over all rostered groups is what exercises the
cross-item arm, and that happens in #26.
