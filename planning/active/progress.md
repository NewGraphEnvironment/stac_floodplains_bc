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
