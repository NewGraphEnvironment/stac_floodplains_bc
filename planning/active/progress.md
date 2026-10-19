# Progress — Publish v2.1.0 (#98)

## Session 2026-10-19

- Plan-mode exploration; phases approved. No feature branch: the tag must sit on a clean
  main commit whose `NEWS.md` top entry names the version.
- Measured the pre-flight state (findings.md) and established why the box was still open —
  `data/stac` predates `d77fd36`'s publish-side prose edits.
- 08:37–08:52 PDT (15 min): `bash scripts/run_pipeline.sh`, exit 0. 108 staged rasters
  converted, 0 failed; 223 style rows over 23 items, `layer_styles` registered and pinned in
  69 of 69 GeoPackages; 23 items + collection written; the run's own validate green.
- Phase 2 guards, all exit 0: `claim_drift-check.py` (156 arms over 9 files, 0 problems),
  `attribution_drift-check.py`, `prov_census-measure.R`.
- **No literal moved.** The build prints floor 23/23, census `link_run_uid` 18 with the other
  eleven at 23, straddle 23 of 23 on all five metrics — which is what `PROVENANCE_FLOOR`,
  `PROV_CENSUS` and `METRIC_SCOPE_CENSUS` already hold. `prov_census-measure.R`'s pre-flight
  agrees with the build's own line.
- Skipped `test_pipeline.R` deliberately: it restages into the real `data/` and leaves
  `PARTIAL_STAGE`, so it would destroy the build the release is cut from. The full rebuild
  exercised the same chain over all 23 groups through the same gate.
- Next: date NEWS, commit, tag, release.
