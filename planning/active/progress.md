# Progress — README rebuild from README.Rmd (#53)

## Session 2026-09-04

- Plan-mode exploration: read the current `README.md` (307 lines), `scripts/readme_coverage-table.py`,
  `scripts/README.md`, and the sibling `stac_dem_bc/README.Rmd` in full.
- Measured the live API and the item geometries before designing — the 45 MB / 11 MB-simplified
  result is what settles the interactive map's content (findings.md).
- Phases approved by user; three design questions answered (figure content, interactive site,
  cache shape).
- Created branch `53-readme-rebuild-from-readme-rmd-into-a-la` off main.
- Scaffolded PWF baseline from issue #53 with approved phases.
- Next: Phase 1 — render harness.

## Session 2026-09-04 (continued)

- **Phase 1–2** — `scripts/readme_functions.R`: one guarded `rstac` call, every guard from
  `readme_coverage-table.py` ported by behaviour. Five restore-the-bug proofs, each matched on
  its own refusal message. The R table reproduces the retired Python generator's output row for
  row against the live API (7,273 / 17,008 / 13,775 / -3,233).
- **Phase 3** — `fig/coverage.png` (tmap v4: `bcmaps::bc_bound()`, watershed groups filled by
  region, floodplain ribbons stroked over them, 22 labels) and the `mapgl` map for the site.
  Two visual iterations: Skeena's blue collided with the floodplain ink, and `opt_tm_text(halo=)`
  drew each label five times as offset copies rather than blurring it.
- **Phase 4–5** — `README.Rmd` as the single source; `ATTRIBUTION.md` takes the licence
  reasoning off the landing page; `scripts/README.md` gains Prerequisites and a rewritten
  release step 6; `readme_coverage-table.py` removed.
- QGIS screenshots copied from `stac_dem_bc` at the user's request, showing the endpoint
  connection and the extent filter. The second visibly shows a sister collection, so its prose
  says so rather than implying it is this one.
- Plan review returned mid-implementation; every finding checked rather than accepted. Two
  blockers were real and are fixed — see `review-53.md`. Two more proof arms added for them.
- README.md: **307 lines / 2,592 words → 136 / 1,593**, with three figures it did not have.
- Next: `/code-check` rounds, commit, PR. Pages enablement is post-merge (`source.branch=main`).
