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

- [x] Snapshotted the live collection + 20 item JSONs from **S3** (not the API — the API injects
      self/root links, which produced a false gate failure on the first attempt).
- [x] GATE PASS: **21/21 byte-identical** to S3; 20 `meta.json`. The staged tree is the one that
      produced production.
- [x] md5 baseline of all **120** asset files.

## Phase 1: Emit the fields

- [x] `FILE_EXT` + `file_meta()` with the `1220`/68-char assertion (chunked read, 1 MB blocks).
- [x] `extra_fields=file_meta(...)` on all six asset constructors; `FILE_EXT` added to
      `stac_extensions`. Build takes **4.7 s** for 20 items including hashing 673 MB.
- [x] Preflight now **opens** every asset before the first write, so "unreadable" is true as well as
      "missing" — review caught that the original comment over-claimed.
- [x] Ordering comment recorded at the hash site.

## Phase 2: Guard

- [x] `item_validate.py` re-hashes every asset and compares; reports all problems then exits 1.
      Measured at **0.72 s** over the full tree.
- [x] `test_pipeline.R` asserts both fields on all six assets against `file.size()`.
- [x] Negatives pass: corrupt a byte -> caught; strip the `1220` prefix -> caught. **Proved the gap
      is real** — pystac `validate()` PASSES the prefix-less checksum, so the schema cannot see it.
- [x] **Review found four silent-success holes; all fixed and each proven:**
      1. An item that lost an asset iterated nothing and passed — "nothing checked" was
         indistinguishable from "all checked". Now compares asset key sets across items.
      2. All items losing all assets passed the same way. Now reported explicitly.
      3. The local path was derived from `item_id` + basename, **discarding the href's directory**,
         so a wrong published prefix verified against the correct local file and passed. Now
         resolved from the href itself and asserted to sit under the item id.
      4. `--skip-sync` could register a checksum for bytes not on S3, since "the href resolves" no
         longer implies "the bytes match". Verify now downloads the probe asset and compares its
         real checksum; the flag's contract is documented as narrower.

## Phase 3: Docs

- [x] `README.md` — the two fields, the multihash form, and copy-pasteable shell + R verification.
- [x] `scripts/README.md` — the `02 -> 03 -> 05` ordering constraint and why the schema is not a
      sufficient guard.

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
