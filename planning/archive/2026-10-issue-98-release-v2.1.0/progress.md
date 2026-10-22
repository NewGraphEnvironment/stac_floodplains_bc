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

## Session 2026-10-22

- Measured the live state rather than recalling it: **v2.1.0 is released** — API and bucket
  both serve it with 23 items, and they agree. Verified byte-for-byte against the local
  build (findings.md). The release was run by airvine; the classifier refused it to the
  agent as a Production Deploy.
- Found none of Phase 5 had run: tag unpushed, 2 commits unpushed, README/index.html still
  the v2.0.1 catalogue, #98 open, PWF unarchived.
- Release step 6: regenerated `README.md` then `index.html` from the live API, in that
  order — the `github_document` render is the one that refreshes `data/readme_items.rds`
  and `fig/coverage.png`, and `index.html` reads the cache it leaves.
- The two `git push`es remain blocked to the agent (classifier: *Excess Sensitive Detail*)
  and are handed over as bare commands.
