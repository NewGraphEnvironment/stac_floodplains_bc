# Task: Publish `file:checksum` + `file:size` on assets (file extension) (#22)

Published items carry no content hashes. A consumer who downloads an asset cannot verify they got
the bytes we published, and cannot tell *which version* of a regenerated asset a report cited.
Current `stac_extensions` is `projection` only.

This stopped being hypothetical. `flooded` 0.5.0 fixed a bankfull units defect, so **every published
floodplain is over-mapped** — a `ff04` item is really ~14.37x bankfull depth, not 4 (#26). Those
items are live and public now. Landing checksums **before** the #26 rebuild gives the current
vintage an identity, so the rebuild visibly changes the checksum; landing it after means checksums
and corrected geometry appear together and cannot be told apart.

## Approved decisions

| Decision | Choice |
|---|---|
| Scope | **Both `.tif` and `.gpkg`** — all 120 asset files |
| Publish | **Yes**, from the existing staged tree. **No re-stage.** |
| Guard | **Re-hash and compare against disk**, plus structural checks |

## Findings that shape the work

- **Do NOT run `run_pipeline.sh`.** Upstream is **mid-remodel** — MORR/BULK/KISP/NECR/PARS corrected,
  UFRA/WILL/BOWR and the rest not (verified by byte-comparing upstream gpkgs to staged copies).
  Re-staging would publish a **mixed-vintage catalogue** with nothing to distinguish the two.
- **The staged tree is the one that produced production** (all 20 JSONs byte-identical to S3). That
  is what makes a JSON-only rebuild safe; Phase 0 re-proves it.
- **Assets are byte-final at `05`**: `02` writes COGs -> `03` mutates in place -> `05` builds JSON.
  Hashing in `05` is correct *because of that ordering* — worth a comment.
- **gpkgs are `file.copy()`, never rewritten here**, so the checksum describes exactly the published
  bytes regardless of upstream `OGR_CURRENT_DATE` (which matters for #23, not this).
- **pystac's idiomatic recipe raises here**: `FileExtension.ext(asset, add_if_missing=True)` throws
  `STACError` on an unowned asset, and all six assets are built before the Item. Use `extra_fields`
  + explicit schema URI, matching the existing `proj:*` style. Verified to serialize and validate.
- **Validation cannot catch the likeliest bug**: schema is `^[a-f0-9]+$`, so a bare sha256 with no
  `1220` prefix passes. Uppercase fails. The generator must assert this itself.
- Cost measured: sha256 over all 120 files (673 MB) = **2.4 s**.

## Phase 0: Baseline

- [ ] Snapshot live collection + 20 live item JSONs to scratch (versioning Suspended)
- [ ] Re-prove fast path: all 20 local `data/stac/*.json` byte-identical to S3; 20 `meta.json`
- [ ] `md5` every asset file, so Phase 4 can prove no asset changed

## Phase 1: Emit the fields

- [ ] `05_stac_register.py` — `FILE_EXT` constant + `file_meta(path)` helper; assert prefix/length
- [ ] `extra_fields=file_meta(...)` on all six `pystac.Asset(...)` constructors
- [ ] Add `FILE_EXT` to the item's `stac_extensions`
- [ ] Hash in the existing preflight loop so an unreadable asset fails before the first write
- [ ] Comment recording the `02 -> 03 -> 05` ordering that makes hashing correct

## Phase 2: Guard

- [ ] `item_validate.py` — assert `file:size` and `file:checksum` match the bytes on disk, plus
      structural checks; report every mismatch then exit 1
- [ ] `test_pipeline.R` — assert both fields on all six assets against `file.size()`
- [ ] Negatives: corrupt a byte -> fails; strip the `1220` prefix -> fails (what the schema cannot)

## Phase 3: Docs

- [ ] `README.md` — the two fields, multihash form, how a consumer verifies a download
- [ ] `scripts/README.md` — the ordering constraint that keeps checksums valid

## Phase 4: Publish

- [ ] Run `05` **only** — never `run_pipeline.sh`
- [ ] Structural diff vs live: only `file:*` on assets + the added `stac_extensions` entry
- [ ] Assert no asset file changed (md5 vs Phase 0)
- [ ] `item_validate.py`, then `catalogue_release.sh`
- [ ] Verify live, and **download an asset from S3 and confirm its sha256 matches the published
      multihash** — end-to-end proof a consumer can actually verify

## Validation

- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
