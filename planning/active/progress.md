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
- Phase 2 rebuild (2nd pass, from step 02 after the class-0 fix): VALIDATE clean with
  `--expect-provenance 23`; floor 23 and the per-field census both asserted; RAT 10/100;
  "every pixel value described"
- Phase 3 literals set: PROVENANCE_FLOOR 23, PROV_CENSUS (link_run_uid 18, other eleven 23),
  prov_fields-check.py fixture 18/5/2 with floor 23 and the 12 numbers that move with it
- Phase 4 checks, all run with RETIRED_ITEMS still empty (a non-empty literal collapses
  catalogue_release-check.sh, which runs the real script against a 2-item fixture):
  prov_fields 49/0, attribution_drift, style_drift (3 byte-identical, 10 classes),
  year_sets 16/0, style_determinism PASS, fp_provenance 87/0, gpkg_determinism PASS
- Payload: data/stac 1.6G over 23 items + collection.json

- Phase 4 code-check: FIVE rounds (branch mode). R1 4 findings, R2 5, R3 10, R4 6, R5 1 —
  rounds 2, 3 and 4 each found a defect INSIDE the previous round's fix, all one mechanism:
  a measured quantity in prose, re-measured at the wrong scope or in the wrong units.
  Terminated by enumeration (3 axes: 21 semantic literal groups, 56 quantity claims, 37 ids)
  plus independent re-derivation of every corrected number through different tooling.
  No behavioural defect after round 1. Durable gap filed as #93.
- Phase 5 docs complete. Phase 6 next: PR, merge, tag v2.0.0, release.
