# Findings — nge:landcover_key publishes item_hash, the one landcover field that cannot detect an upstream reprocess (#40)

## Issue context

## Problem

`nge:landcover_key` is meant to be the field that fails when the upstream landcover moves. It
cannot, because it publishes the wrong hash.

`scripts/fp_provenance.R` maps it to `inputs$item_hash`:

```r
landcover_key = list(section = "landcover", path = c("inputs", "item_hash"))
```

`item_hash` is a hash over the **resolved STAC item ids**. That was a deliberate improvement over
drift's `stac_cache_key()` (which fingerprints the request and nothing about the response), and the
comment in that file says so. But it does not go far enough, and floodplains#33 measured why:

- io-lulc item ids are `<tile>-<year>` — a deterministic function of tile and year.
- The blob path is fixed.
- The items carry **no `created` and no `updated` property** (verified live).

So if Planetary Computer re-derives a year **in place**, every id and every href is unchanged and
`item_hash` is byte-identical. The ids are an **identity** — they name what was read — not a
**fingerprint**. floodplains' CLAUDE.md has said "`nge:landcover_key` should be the raster digest"
since #33; that sentence has never been true of what ships.

## What changed upstream

floodplains#64 (merged) replaced its container-level file hash with a real content digest:

- `inputs$classified_sha256` → **`inputs$classified_content_sha256`** (renamed, so old and new
  records are distinguishable rather than silently redefined).
- It digests **cell values plus geometry** (dim, extent, EPSG, res) in fixed 512-row blocks, so it
  is invariant to the writer's toolchain and still moves on a single changed cell.

That last property was the reason for the change. Measured across two machines running the
identical commit against the same database: 28,291,615 cells per year, **zero differing**, and
three different file digests — 10,028 bytes of TIFF tag 42112 that one terra writes and another
drops. The new digest agrees on all three years and still moves on one changed cell or one cell
becoming nodata.

Shape of the value, one entry per year:

```json
"classified_content_sha256": { "2017": "sha256:…", "2020": "sha256:…", "2023": "sha256:…" }
```

## What to do

- [ ] Point `landcover_key` at the raster digest rather than `item_hash`. Note it is a **map keyed
      by year**, not a scalar, so the mapping needs a decision: publish the map, or fold it to one
      value over the sorted years. Folding is probably right for a single STAC property — but say
      which, because a consumer cannot tell a fold from a single year's hash.
- [ ] Keep `item_hash` published under its own name if it is wanted. It is genuinely useful as *what
      was read*; it is only wrong as *what was produced*.
- [ ] Decide what happens to already-published items. floodplains' provenance is forward-only, so an
      area carries the new field only once re-run — items registered before then have neither the
      new key nor a correct old one.

## Ordering

Do not switch until the producing areas have been re-run under floodplains#64, or the field
resolves to null and the null publishes.

Filed from floodplains#63/#64. Measurement:
`floodplains/scripts/floodplain_lcc/logs/20260902_provenance_live-verify_neexdzii.md`.



## Exploration (2026-09-02, plan mode)


`nge:landcover_key` exists to move when the upstream landcover moves. It publishes
`inputs$item_hash`, a hash over resolved STAC item ids — an identity, not a fingerprint — so an
in-place re-derivation upstream leaves it unchanged. floodplains#64 (merged) added
`inputs$classified_content_sha256`, a per-year map of content digests over cell values plus
geometry, invariant to the writing toolchain. This repo has to point `landcover_key` at it.

**Exploration changed the scope in one way that cannot wait.** Upstream `provenance.json` now
declares `schema_version: 2` (floodplains#65 phase 1, 2026-09-02: sections gained `inputs_hash`,
`outputs`, `outputs_hash`; `sha_source` became a closed vocabulary; the landcover digest was
renamed). This repo's reader pins `FP_PROV_SCHEMA_VERSION <- 1L` and **stops** on any other
value. Upstream is being re-run right now under the new writer — `bulk/provenance.json` was
rewritten at 19:54Z today, after the v1.0.0 rebuild staged it at 18:01Z — so the next
`run_pipeline.sh` refuses at BULK before it reaches anything. The state today, all 11 nge:
properties null on every live item, is exactly what the schema pin is designed to make loud.

Measured on the two v2 files on disk (`bulk`: network `co3` + floodplain `co_ff02/co_ff04`, no
landcover yet; `neexdzii`: all three sections, landcover `co_ff04`): every `FP_PROV_MAP` path
still resolves. The map walks explicit paths, so the new sibling keys are inert; only the pin
and the landcover leaf change.


### Measured on disk

- `$FLOODPLAINS_DATA/bulk/provenance.json` (mtime 19:54:44Z, after the v1.0.0 rebuild staged bulk at
  18:01:50Z): `schema_version` 2, network `co3` (inputs, inputs_hash, link_log, link_log_note,
  outputs, outputs_hash, run), floodplain `co_ff02` + `co_ff04` (inputs.flooded.version 0.5.0 —
  the #26 fix), landcover empty. So bulk's next stage yields non-null link/flooded fields and null
  landcover fields.
- `$FLOODPLAINS_DATA/neexdzii/provenance.json` (19:48:49Z): schema 2, landcover `co_ff04` with
  `classified_content_sha256` = {2017, 2020, 2023} → `sha256:<64 hex>` each, `item_hash`
  `sha256:c653b16d…`, `item_ids_complete` true, `run.toolchain` present, `drift.version` 0.8.0.
  Not a rostered area; it is the only file with a landcover section, so the fold is proven
  against it offline.
- Every `FP_PROV_MAP` path resolves on both v2 files; only the pin blocks them.
- Upstream `item_hash` payload (floodplains `fp_prov_stac_items`): `"<year>=<ids,…>"` lines
  joined by `\n`, years sorted, `sha256:` + `digest::digest(payload, algo = "sha256",
  serialize = FALSE)`. The fold here uses the same construction over the year digests.
- R packages available here: digest, openssl, jsonlite.

## Errors Encountered

| Error | Resolution |
|-------|------------|
