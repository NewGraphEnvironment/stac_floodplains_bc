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
- Next: Phase 3 — restore each bug and prove the guard fires
