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
- Phase 3 smokes (21:19:49Z, ~6 min for both): **bulk** → PASS on the producer-file-present
  branch with **12 of 12** `nge:` values non-null — upstream's landcover step 3 for bulk landed
  between #40's smoke and this one, so `landcover_key` is now a real fold published from the
  producer's file; validator line `1 of 1 carry values; floor 0`. **kotl** → PASS on the
  no-producer-file branch, all 12 null, `0 of 1 carry values; floor 0`. Both branches of the
  two-sided assertion exercised on real areas.
- Plan review + `/code-check` round 1 folded in (see findings.md): the floor is now exact, `--only`
  gains a live-vs-build provenance guard (case 15), test_pipeline.R compares three scalars per
  target against the producer's raw JSON, the validator prints per-section counts. Harness ALL
  PASS; guard disabled → case 15 red (2 FAILED, and the run syncs before failing); reader check 49
  assertions with bulk's landcover section now present. `--expect-provenance 1` on the all-null
  kotl tree → FAILED "0 of 1"; `0` passes with `network 0, floodplain 0, landcover 0`.
- Smokes rerun on the per-target compare: **bulk** PASS — `link_version 0.50.0`, `flooded_version
  0.5.0`, `produced_datetime 2026-09-02T20:46:08Z` each identical to the producer's raw JSON;
  validator `1 of 1 carry values — network 1, floodplain 1, landcover 1; floor none`. **kotl**
  PASS — all three expectations null and the item null; `0 of 1 … network 0, floodplain 0,
  landcover 0`.
- `/code-check` round 2: the `--only` guard refused only a TOTAL loss; a reader that kept the
  network section and lost landcover (live 12, build 4) passed it and the read-back would have
  accepted the nulls. Now per key: any live `nge:` value the build publishes as null refuses,
  naming the keys. Fixture gains `nge:kept` (a value on both sides) so partial loss is
  representable; case 15 is now that shape (live 2, build 1 → refused, 0 aws calls). With the
  total-count guard restored: 2 FAILED and the run syncs before the read-back fails.
- `/code-check` round 3: converged on the `--only` path (the class across the rounds: a guard
  written at a coarser granularity than its property — file, then item, now key, and there is no
  level below key). Two wording fixes: CLAUDE.md and scripts/README.md still described the
  total-loss predicate; a live key absent from the build (a contract rename) was diagnosed as a
  reader loss — now refused with its own message. Residual, stated: the full-release floor is
  item-level by design; per-section counts are printed, not gated.
