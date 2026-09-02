# Progress — Embed class labels in the published COGs (#34 + #35)

## Session 2026-09-01

- Measured the storage question end to end: category names vs RAT, terra vs rasterio vs
  system GDAL, sidecar reachability over HTTP under titiler's own GDAL config
- Established that `rasterio.shutil.copy(driver="COG")` embeds a hand-written PAM RAT with
  no new dependency — this is what makes both issues deliverable
- Plan reviewed by a Plan subagent; findings folded into the phases (skip-branch ordering,
  slug injectivity, the schema hole, the gpkg oracle, absolute row-count floors)
- Created branch `34-35-embed-class-labels-rat-and-classification`
- Phases 1-3 landed in 3aca094 (class table, RAT sidecar, terra -> CreateCopy)
- Phases 4-5: classification:classes on every raster asset; item_validate gains an
  embedded-RAT guard (parses TIFF tag 42112 directly, because asking GDAL cannot tell an
  embedded RAT from a sidecar one), a RAT-vs-item agreement guard, a pixel-value coverage
  guard, and an overview-interpolation guard
- test_pipeline.R gains the transition_vector.gpkg oracle: 53 upstream from->to pairs, all
  named by the published classes, from a producer that is not us
- Every guard exercised against a restored defect and seen to fail
- /code-check ran 3 rounds: 9 findings in rounds 1-2, 3 in round 3, all fixed and each
  verified against a restored defect
- Round 2's headline: two of round 1's three fixes carried a NEW defect of the same class
  they closed. Round 3 named the mechanism — every new premise was written as a literal
  reasoned from a producer's behaviour when the artifact answers it directly — and
  enumerated the closed candidate set, which had exactly one remaining hit
  (`COG_BLOCK_SIZE`, now read from `ds.block_shapes`)
- Next: archive PWF, open the PR
