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
- Phase 3 smoke: `WSG=bulk Rscript scripts/test_pipeline.R` 20:07:27Z → PASS in ~3 min. The first
  real provenance this repo has ever staged: `1 of 1 staged item(s) carry run provenance`;
  validator `provenance: 12 nge: properties on every item, COG tags agree`. Field by field on
  `bulk_co_ff04`: `link_run_uid` 20260901_234743-6628379d, `link_config_sha256` sha256:19e3a056…,
  `link_sha` 689146867a5f…, `link_version` 0.50.0, `flooded_version` 0.5.0 (the #26 fix); the
  seven landcover fields null (`drift_version`, `produced_datetime`, `landcover_source`,
  `_collection`, `_stac_url`, `_key`, `_item_hash`) because bulk's step 3 has not been re-run, and
  `NGE_PROVENANCE_NULL` on the COG names exactly those seven. The v1.0.0 live item still serves
  all-null; nothing here is released.
- Snapshot the smoke read (review O2): `bulk/provenance.json` mtime 2026-09-02T19:54:44Z, sections
  network `co3`, floodplain `co_ff02`+`co_ff04`, landcover `[]` — so "landcover fields null" is
  the correct reading at that mtime, and flips to non-null once upstream's step 3 lands.
- Plan review + `/code-check` round 1 (Clean, nine restored defects each reaching its guard):
  the plan review's gaps applied — check script now 45 assertions, 0 failed, 0 skipped; harness
  ALL PASS. Smoke re-run after the staging guard was added.
- Second smoke (after the staging guard): PASS, same values. `/code-check` round 2: one fragility —
  the mtime guard's message claimed "a step in flight" where a source tree copied without
  preserved mtimes would trip it too (false refusal, never a wrong publish); the message now
  names both causes. Everything else on its probe list verified clean, including `area` equals
  the directory for all 19 rostered groups upstream (`run_region.R` passes `tolower(wsg)`).
- `/code-check` round 3: one bug in the rasters-vs-record guard — its reference was the file's
  mtime, which every upstream step rewrites, so a crashed step 3 followed by a step-1 re-run
  would have passed and published a fingerprint of bytes the item does not ship. Reference is
  now the landcover section's own `run$datetime_utc` (floored to the second on both sides).
  Check script 49 assertions; with the file-mtime reference restored, 2 FAIL — the crash row
  and the masking row. Rounds 2 and 3 were one mechanism (a property of the file object
  standing in for a property of the record's content); the reader, fold and field-list
  plumbing were judged converged, with the neexdzii pin reproduced by the reviewer in Python.
  Follow-up named in the PR: recompute the digest on the staged copies (S4), which retires the
  class.
