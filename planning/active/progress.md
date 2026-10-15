# Progress — Complete the whole-network cutover in one release at v2.0.0 (#89)

## Session 2026-10-15

- Plan-mode exploration — phases approved by user; scope confirmed as "through RELEASE
  COMPLETE, the S3 retract handed over"
- Created branch `89-complete-the-whole-network-cutover-in-one` off main
- Scaffolded PWF baseline from issue #89 with approved phases
- Next: Phase 1

- Phase 1 done (af679c9): deprecation literals emptied, published collection description and
  the two determinism-check ITEM defaults moved with the cutover
- Phase 5 docs done (afd85bf): NEWS promoted to v2.0.0 naming all 23 retired ids, CLAUDE.md,
  README.Rmd
- Phase 2 build: staged 23/23, no skips, floor 23, census matches the pre-flight exactly.
  VALIDATE refused on a real defect — class 0 dropped from the class table (findings.md).
  Fixed, styles regenerated, rebuilding from step 02.
- Next: Phase 3 PROV_CENSUS, Phase 4 checks, then RETIRED_ITEMS last
