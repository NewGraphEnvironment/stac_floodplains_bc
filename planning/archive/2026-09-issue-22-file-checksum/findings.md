# Findings — Publish `file:checksum` + `file:size` on assets (#22)

## Spec (verified against the extension README + installed pystac)

- Schema URI: `https://stac-extensions.github.io/file/v2.1.0/schema.json`
- `file:*` fields live in the **asset dict**, never in item `properties`
- `file:size` is bytes, integer
- `file:checksum` is a **multihash, hex-encoded lowercase**: `1220` + sha256 hex
  (`0x12` = sha2-256, `0x20` = 32 bytes). Confirmed against the spec's own SHA1 worked example.
- `pystac-ext-file 2.1.0` is already installed — no new dependency. `hashlib` + a 4-char prefix is
  all that is needed.

## Two traps the schema will not catch

- `^[a-f0-9]+$` means a **bare sha256 with no `1220` prefix validates fine**. The single likeliest
  implementation error is invisible to validation.
- **Uppercase hex fails** validation. `hexdigest()` is already lowercase; never `.upper()`.

## pystac API does not fit this construction order

`FileExtension.ext(asset, add_if_missing=True)` raises:

    STACError: Attempted to use add_if_missing=True for a <class 'pystac.asset.Asset'> with no owner

`05_stac_register.py` builds all six assets *before* the Item exists, so the idiomatic recipe would
crash. Use `extra_fields=` on the constructor and append the URI to `stac_extensions` — which also
matches how `proj:*` is already done in this file. Verified: serializes correctly, `validate()` passes.

## Pipeline facts

- 6 assets/item x 20 items = **120 files, 673 MB**. 80 `.tif` (77 MiB) + 40 `.gpkg` (564 MiB).
  Largest single file 75.4 MiB. sha256 over all of it: **2.4 s** warm.
- Mutation order `02` (write COG) -> `03` (in-place `r+` tag) -> `05` (build JSON), confirmed by
  mtimes. Hashing at `05` is safe **only** because of this; any later in-place step breaks it.
- gpkgs reach `data/stac/` by `file.copy()` (`01_stage.R:147-151`) — no GDAL rewrite in this repo.
- Local asset path is derivable inside `build_item` as `wsg_dir / Path(href).name`.
- `05` already has a preflight loop validating every `flood_factor` before the first write — the
  right place for hashing, so a failure cannot leave a mixture of fresh and stale JSON.

## Upstream state (the safety-critical finding)

`$FLOODPLAINS_DATA` is **mid-remodel**. Byte-comparing upstream `floodplain_landcover.gpkg` against
the staged copies:

| area | state |
|---|---|
| morr, bulk, kisp, necr, pars | **DIFFERS** — remodelled on flooded 0.5.0 |
| ufra, will, bowr (+ others) | same as staged — still pre-0.5.0 |

So `run_pipeline.sh` today would publish a **mixed-vintage catalogue**, and since no item carries a
`flooded` version (#17 is blocked on floodplains#33), nothing would distinguish them. This plan
rebuilds JSON only.

The staged tree itself is intact and byte-identical to S3 — it is the tree that produced the live
catalogue, which is what makes the JSON-only path safe.

## Issue graph

- **floodplains#45** CLOSED — pinned `OGR_CURRENT_DATE` via `fp_gpkg_pin_date()`; unblocks the gpkg
  half. Bound: full rebuild into an absent file is byte-identical, rewriting one layer into an
  existing gpkg is not (3 SQLite header bytes).
- **#23** blocked by this; carries the `OGR_CURRENT_DATE`-in-`scripts/` precondition because it makes
  this repo write a gpkg for the first time.
- **floodplains#46** (per-feature hashes) explicitly not a blocker.
- **#26** is the over-mapping defect this sequencing exists to precede. Not fixed here.
