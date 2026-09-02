# Progress — nge:landcover_key publishes item_hash, the one landcover field that cannot detect an upstream reprocess (#40)

## Session 2026-09-02

- Plan-mode exploration — phases approved by user; scope grew by the schema-2 pin bump
- Created branch `40-nge-landcover-key-publishes-item-hash-th` off main
- Scaffolded PWF baseline from issue #40 with approved phases
- Next: start Phase 1
- Phase 1: `scripts/fp_provenance-check.R` (offline reader proof: synthetic schema-2 document +
  eleven mutations, plus the real bulk and neexdzii files) — 24 assertions, 0 failed, 0 skipped.
  Pin bumped to 2; with it at 1 the synthetic v2 base is refused (rc 1, "declares schema_version 2
  but this reader implements 1"). One fixture lesson kept as an assertion: `x$link_log <- NULL`
  removes the key in R, and the reader correctly refused that as a schema break — the modelled
  null needs `x["link_log"] <- list(NULL)`.
- Phase 2: `landcover_key` → fold of `classified_content_sha256` (`fp_fold_year_digests`: years
  asserted against the item's YEARS, every value `sha256:<64 hex>`, `<year>=<digest>` lines joined
  by newline, sha256 of that); `landcover_item_hash` (twelfth field) → `item_hash`. All six copies
  of the field list updated; the `fold` hook is the one route a non-scalar leaf reaches the item.
  Check script: 38 assertions, 0 failed, 0 skipped. neexdzii's fold pinned at
  `sha256:27a0c5b6…fb89b04`, and recomputed independently in Python from the producer's file
  (hashlib over the same payload): identical. Harness ALL PASS; py_compile + R parse clean.
