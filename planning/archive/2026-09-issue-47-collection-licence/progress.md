# Progress — Collection publishes license: proprietary (#47)

## Session 2026-09-03

- Plan-mode exploration: read the live API, the two source collections, the scientific
  extension schema, stac-fastapi-pgstac's link filter, and both sibling repos' licensing
- Concurrent Plan-agent review of the design; 8 findings, verified then folded in
- Three decisions taken with the user: MIT code / CC BY data; `New Graph Environment Ltd.`;
  this PR cuts a release (which also publishes #26)
- Created branch `47-collection-publishes-license-proprietary` off main
- Scaffolded PWF baseline with approved phases
- Phase 1: collection metadata in `scripts/item_create.py` — licence, six providers,
  `rel: license` + `rel: derived_from` links, scientific extension + `sci:citation`,
  and the CC BY §3(a)(1)(B) modification statement in the description. Rebuilt: 23
  items, collection validates against core + scientific v1.0.0
- Phase 2: `check_collection_metadata` (licence, 6 providers whole-record, both links,
  citation verbatim, extension biconditional, derivation statement) + 
  `check_citation_premise` tying the literals to every item's `nge:landcover_collection`.
  Positive control: validator green in 2m45s, and the independently-typed second copy
  of the citation matched the build's byte for byte
- Phase 4: step 5 of `catalogue_release.sh` reads `license`, the `rel: license` link and
  `sci:citation` back from the API AND the bucket. `licence_of()` proved offline against
  all four inputs (good / no licence / no citation / no link) plus an empty body, which
  must raise rather than read as a clean pass. `catalogue_release-check.sh` gains cases
  9c-9f: **90 assertions, 0 FAIL**, and each new case asserted its own message
- Phase 5: MIT `LICENSE` byte-identical to both siblings, README `## Attribution`,
  `pyproject.toml` license, `CLAUDE.md`, `NEWS.md` under Unreleased, `PROVENANCE_FLOOR=21`
- Phase 3: **8 of 8 guards proved** by mutating the source, rebuilding, and grepping for
  each guard's own message. One came back `*** WRONG GUARD` and was the most valuable
  result of the day: it disproved a premise I had written into three files (that the
  scientific extension validates with zero `sci:` fields — it does not; I had read a
  schema dump truncated mid-word). Comments corrected in `item_create.py`,
  `item_validate.py`, `CLAUDE.md`, `NEWS.md` and the PR body; the proof retargeted to
  the direction pystac genuinely cannot see
- `/code-check`: 3 rounds, 14 findings, all fixed. Round 1 caught the step-5 guard checking
  link PRESENCE not value — the one thing pgstac does to a link it keeps is rewrite the
  href, so the guard was blind to its own purpose. Round 2 found a defect inside that fix.
  Round 3 corrected round 2's explanation of it and found the harness had no fixture for
  the built side at all. Harness 90 -> 100 assertions; case 9j proved to discriminate (the
  pre-fix form reports RELEASE COMPLETE while publishing no attribution at all)
- Next: commit, PR
