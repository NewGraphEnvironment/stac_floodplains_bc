# Progress — Embed class labels in the published COGs (#34 + #35)

## Session 2026-09-01

- Measured the storage question end to end: category names vs RAT, terra vs rasterio vs
  system GDAL, sidecar reachability over HTTP under titiler's own GDAL config
- Established that `rasterio.shutil.copy(driver="COG")` embeds a hand-written PAM RAT with
  no new dependency — this is what makes both issues deliverable
- Plan reviewed by a Plan subagent; findings folded into the phases (skip-branch ordering,
  slug injectivity, the schema hole, the gpkg oracle, absolute row-count floors)
- Created branch `34-35-embed-class-labels-rat-and-classification`
- Next: Phase 1
