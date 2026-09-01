# Progress — Publish `file:checksum` + `file:size` on assets (#22)

## Session 2026-09-01

- Plan-mode exploration with three parallel Explore agents (asset construction + hashing surface,
  STAC file-extension spec, issue graph + upstream data state).
- Three decisions approved: hash both `.tif` and `.gpkg`, publish from the existing staged tree
  without re-staging, and make the guard re-hash against disk rather than only check structure.
- Safety-critical finding, verified independently: upstream is **mid-remodel**, so `run_pipeline.sh`
  would publish a mixed-vintage catalogue. This work rebuilds JSON only.
- Two probes settled implementation before any code: pystac's `add_if_missing` raises on unowned
  assets (so `extra_fields` it is), and the schema cannot catch a missing `1220` prefix.
- Created branch `22-publish-file-checksum-file-size-on-asset` off main.
- Next: Phase 0 baseline.
