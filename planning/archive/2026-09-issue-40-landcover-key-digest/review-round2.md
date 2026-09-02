# Review round 2 — #40 (branch 40-nge-landcover-key-publishes-item-hash-th)

Scope: committed diff main..HEAD over scripts/ + CLAUDE.md, plus the uncommitted working-tree
diff (scripts/, NEWS.md, README.md), read against the full working-tree files. Probes ran in a
scratch copy of scripts/ under the scratchpad; nothing in the working tree was touched and no
stage/test_pipeline run was made. Real producer files were read read-only.

## Findings

- **[fragile]** `scripts/fp_provenance.R:333-335` (called from `scripts/01_stage.R:217`) —
  `fp_prov_rasters_current` compares filesystem mtimes, which are a property of the *copy*, not
  the data. A source tree moved without mtime preservation (`rsync` without `-a`/`-t`,
  `aws s3 sync`/`cp`, `scp -r` without `-p`) rewrites every mtime in transfer order, and
  `provenance.json` sorts before `rasters/`, so every landcover-bearing area on that machine
  stops the whole stage (no per-area tryCatch) with a message asserting "a landcover step is in
  flight or crashed" — a confident wrong diagnosis. Fails toward abort, so it cannot publish a
  wrong fingerprint, but it is a false refusal that will send someone to re-run upstream.
  Measured on today's real files it passes: bulk rasters 2026-09-01 01:06 vs provenance.json
  2026-09-02 12:54 (landcover empty, so no check anyway); neexdzii rasters 12:48:34-38 vs
  provenance.json 12:48:49. Upstream ordering confirmed (03_lulc_classify.R:123 writes,
  :128 digests, :410 records last) so a native tree cannot false-fire. Cheapest fix is the
  message naming the copied-tree possibility; the S4 digest recompute supersedes the guard.

## Verified clean (in answer to the "worth probing" list)

- mtime guard directions: all rasters missing -> pass (01 stops on the missing raster
  itself); raster mtime == record -> pass; record deleted between read and check -> stops
  naming `NA, NA, NA` (unreachable: nothing in 01_stage.R writes into `src_wsg` between
  `fp_prov_read` at :202 and the copies at :232-256; the only write is transition_vector.gpkg
  into `dst_stac`). Guard sits before any copy, so its window is valid.
- `area` vs directory: upstream `run_area.R:49-50` sets `cfg$area <- area` and
  `dir_out <- data/<area>`, `run_region.R:148` passes `tolower(wsg)`, so `area` always equals
  the directory basename for every rostered group (all 19 roster dirs exist; bulk file says
  area "bulk"). `%||%` chain: area JSON null -> falls to wsg (OK); area absent -> wsg
  (stops correctly on mismatch); area `""` -> check skipped; both null -> skipped. Probed.
- Fold: doubles vs integers and unsorted `years` fold identically; a fold returning a list or a
  length-2 vector is stopped by the scalar guard (restored in the scratch copy, both cases
  refused). `landcover` as `[]` or `{}` both select NULL -> nulls, no check.
- Two-sided `prov_keys` check: item_create.py adds `nge:` only at :312 from PROV_FIELDS, so
  `grep("^nge:")` on the built item is exactly the twelve; empty set fails loud. Six field-list
  copies agree (01_stage, fp_provenance map stopifnot, 02_raster_tag, item_create,
  item_validate set-equality, test_pipeline).
- `## Unreleased`: `catalogue_release.sh:233-243` refuses it at the top by design (full release
  only; `--only` skips the gate at :197-203). No other consumer in this repo. Note, pre-existing
  and not introduced here: soul's `gh-pr-merge` treats a repo as versioned when NEWS.md exists
  even without DESCRIPTION (`[ ! -f DESCRIPTION ] && [ ! -f NEWS.md ]`), and step 7 then greps
  DESCRIPTION — that has been true since v1.0.0's NEWS.md landed and is unchanged by this diff.
- `Rscript scripts/fp_provenance-check.R` not re-run (author reports 45/0); check script read in
  full: `read_doc(area=)`, the mtime fixture, the JSON-null year case and the empty-years case
  all exercise the code paths they name.
