## Outcome

`nge:landcover_key` now publishes a fingerprint of the landcover produced — the producer's
per-year content digests (`classified_content_sha256`, floodplains#64) folded to one `sha256:`
value over `<year>=<digest>` lines, years ascending, newline-joined — and the old value, a hash
over resolved STAC item ids that an in-place upstream re-derivation cannot move, ships under its
own name as the twelfth property `nge:landcover_item_hash`. Planning found the reader pinned
`schema_version` 1 while upstream had moved to 2 the same day, which would have refused the next
rebuild at BULK; the pin was bumped and `fp_provenance-check.R` became the reader's first offline
proof (synthetic v2 document mutated per guard, plus the producer's own bulk and neexdzii files).
The rasters-vs-record guard went through three review rounds before its reference was right: a
file's mtime is a property of the copy and of the last writer, where the invariant is a property
of the record's content, so the landcover section's own run stamp is what is compared. Nothing was
released; the 20 live items still serve all-null provenance until #26's rebuild.

## Measurement

Reader check: 24 → 38 → 45 → 49 assertions across the four commits, 0 failed, 0 skipped on this
machine (both producer files read). neexdzii's fold pinned at `sha256:27a0c5b6…fb89b04` and
reproduced independently in Python from the producer's file (twice: by the author and by the
round-3 reviewer). Restore-the-bug: pin at 1 aborts the run; rule change reddens two cases; nine
further restored defects each reached their guard (round 1); file-mtime reference restored
reddens the crash row and the masking row. Two bulk smoke tests passed (~3 min each): the first
real provenance ever staged here — `link_run_uid`, `link_config_sha256`, `link_sha`,
`link_version` 0.50.0, `flooded_version` 0.5.0 non-null; seven landcover fields null because
bulk's step 3 had not been re-run at provenance.json mtime 19:54:44Z.

## Evidence

`review-round1.md` … `review-round3.md` and the plan review's disposition table in
`findings.md`, in this directory. Smoke logs were session scratch, summarised in `progress.md`.

Closed by: PR for #40 (branch `40-nge-landcover-key-publishes-item-hash-th`).
