# Progress — Add an operator-set provenance floor so a reader that finds nothing fails the release (#32)

## Session 2026-09-02

- Plan-mode exploration — phases approved by user
- Created branch `32-add-an-operator-set-provenance-floor-so-` off main
- Scaffolded PWF baseline from issue #32 with approved phases
- Next: start Phase 1
- Phase 1: `item_validate.py --expect-provenance N` (default 0; negative refused);
  `check_provenance()` returns (problems, traced, seen) with `traced` = items carrying any
  non-null `nge:` value, the same predicate as `has_prov` / `_no_prov`. On the real bulk smoke
  tree (1 item, 5 non-null values): floor 0 → pass, 1 → pass, 2 → FAILED "1 of 1 item(s) carry a
  non-null nge: value but the release floor is 2 …". Summary line now reads
  `provenance: 12 nge: properties on every item (1 of 1 carry values; floor 0), COG tags agree`.
- Phase 2: `PROVENANCE_FLOOR=0` literal in `catalogue_release.sh` with the flip rule in its
  comment; step 1 passes it on a full release and says "provenance floor: skipped under --only"
  otherwise (the fourth skip). Harness reads the literal back with an anchored sed and asserts
  the uv shim's argv carries exactly it on a full release and nothing under --only; ALL PASS.
  Restore-the-bug: with the argument removed from step 1, 2 FAILED. Docs: scripts/README.md
  step 1, CLAUDE.md paragraph, NEWS Unreleased bullet.
