# Progress — Publish the transition layer as its own asset (#23)

## Session 2026-09-01

- Plan-mode exploration with two parallel Explore agents (staging + extraction mechanics and the
  upstream pin; downstream 6-asset assumptions).
- **Caught a silent-failure trap before any code**: the proposed filename's stem is exactly the
  existing transition COG's asset key, so keying by stem would have deleted the raster from every
  item with nothing able to detect it.
- User chose year-free naming with forward-looking reasoning — QGIS symbology binds to
  `path|layername=`, so the abstraction had to reach the layer name inside the file, not just the
  asset key.
- Approved: `transition_vector` key + file, layer `transition`, and a determinism check with a cold
  path.
- Created branch `23-publish-transition-layer-as-own-asset` off main.
- Next: Phase 0 — measure whether the pin actually makes a 1-layer extract byte-reproducible.
