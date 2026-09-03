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
