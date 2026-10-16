# Progress — QGIS cannot find the embedded styles in floodplain_landcover.gpkg (#95)

## Session 2026-10-16

- Plan-mode exploration: read `04_gpkg_style.py`, `style_determinism-check.py`,
  `item_validate.py::check_layer_styles`, `test_pipeline.R`'s layer arms, `fp_gpkg.R`,
  `run_pipeline.sh`, the style sections of `scripts/README.md`; probed the staged v2.0.0
  tree read-only for the `gpkg_contents` / `gpkg_spatial_ref_sys` shape; searched the
  sibling packages for the same writer and found rfp's.
- Phases approved by user, with three scope decisions: ship the QGIS reachability check
  in this PR; file a soul issue and correct `code-check-spatial.md`; land code + a
  `v2.0.1` NEWS entry here and leave the rebuild, tag and release to the operator.
- Created branch `95-qgis-cannot-find-the-embedded-styles-in` off main (at `4db1fa8`).
- Scaffolded PWF baseline from issue #95 with the approved phases.
- Plan review (Plan agent, unnamed) landed 20 findings; three blockers and the mechanism
  correction verified here before acting:
  - **GDAL, not QGIS.** Reproduced the `LIST_ALL_TABLES=AUTO` heuristic on GDAL 3.8.5
    (`sf`), 3.12.4 (QGIS 4.2.1's own `ogrinfo`) and 3.13.0 (homebrew), and the
    registration fixing it on a copy. Issue body needs correcting.
  - `gpkg_determinism-check.R:121` takes its layer set from the **staged** file and copies
    from the **producer's** — a live break the first inventory missed. Confirmed by reading.
  - A bare registration INSERT raises on the regenerated-style path; the write must be
    conditional.
  - `01_stage.R:85-86` wipes `data/stac` unconditionally — witness captured first.
  Not taken: the review's suggestion to drop the committed QGIS check in favour of the
  GDAL-level arm alone. Both ship: GDAL listing the table is necessary but not sufficient
  for QGIS to apply the style (rfp#17 is the proof).
- Revised task_plan.md and findings.md pre-baseline, which is where that is free.
- Next: Phase 1.
