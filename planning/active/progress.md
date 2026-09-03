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
