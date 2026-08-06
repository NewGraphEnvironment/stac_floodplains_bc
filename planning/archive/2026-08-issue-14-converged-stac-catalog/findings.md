# Findings — Adopt the converged stac-catalog system (#14)

## Issue context

Registration currently ends with `scp` + `ssh root@geopro` running rtj's
`stac_register-pypgstac.sh`. Issue #14 proposes adopting the stac_uav_bc system (#16, #18):
repo-owned registration, a validation gate, versioned releases, a retraction flow, and `noun_verb`
script naming (soul#62). Related: stac_dem_bc#27, floodplains#32.

## Reference implementation

`stac_uav_bc@origin/main` (local clone is 32 commits behind — read via `git show origin/main:<path>`):
`scripts/catalogue_release.sh`, `scripts/item_validate.py`, `scripts/item_create.py`,
`scripts/config/{item,collection}_register.sh`, `scripts/config/item_unregister.sh`.

Transport: compact item JSONs to NDJSON locally in **one** python process, pipe over ssh stdin into
`uv run pypgstac load items --method upsert` on the droplet. Credentials never leave the server
(`. /opt/geoserv/.env`). Deletion has no pypgstac verb, so `item_unregister.sh` goes through
`docker exec -i geoserv-db psql` calling `pgstac.delete_item()`.

## What must NOT be ported verbatim

1. **`--delete` on the S3 sync.** uav's `PROD` tree is durable; `data/stac` here is wiped by
   `01_stage.R:30-31` on every run and rebuilt by a stager that soft-skips missing WSGs
   (`:97-101`, `:119-123`) while still exiting 0. With versioning Suspended, `--delete` would
   silently and irrecoverably erase a published item's assets. uav's own retraction recipe uses an
   explicit `aws s3 rm`, not `--delete`.
2. **uav's verify.** It reads `.version` off the live collection and defaults `VERSION` from
   `git describe --tags`. This repo has **zero tags** and the collection carries no `version` field,
   so under `set -euo pipefail` it aborts — *after* syncing and registering. Item 3 is deferred, so
   verify asserts **set identity** instead.
3. **uav's un-fielded `POST /search`.** Measured here: **38 MB in 30 s**, parsed just to count
   features. `"fields":{"include":["id"]}` is mandatory.

## Silent-success traps (the CLAUDE.md class: exit 0 while nothing happened)

- `item_validate.py` has no lower bound — a wrong `--base` prints `valid: 0` and exits 0, so the
  gate opens on nothing. And `rglob("*.json")` over `data/stac` matches **86** files: 18 real plus
  **68 `.tif.aux.json`** terra sidecars, silently skipped by the `type != "Feature"` branch.
  Fix: depth-1 `glob()` + `--expect N` from the `data/raw/*/meta.json` count.
- A truncated ssh transfer of the ~94 MB NDJSON: remote `cat` sees EOF → exit 0; pypgstac loads
  valid-but-short NDJSON → exit 0; ssh → exit 0. Green output, missing items. rtj guards this with a
  count check (`stac_register-pypgstac.sh:93-96`); the port must too.

## Corrections to earlier assumptions

- **The 9 MB item corruption is already fixed** — rtj commit `5719f8c` added temp-file-per-job plus a
  count guard. It is history, not a live justification for anything.
- **`stac_airphoto_bc/scripts/run_pipeline.sh:32` is not a stale, divergent IP.** It is
  `root@146.190.12.8`, byte-identical to uav's, and `dig +short images.a11s.one` still returns it.
  The real argument for `geopro` is **transport**: the public IP is gated by the DO firewall's
  `ssh_allowed_ips` (`rtj/env/do/prod/geoserv/main.tf:51`), while the Tailscale node name works from
  anywhere on the tailnet and survives a droplet rebuild.
- **Root SSH is not blocked by the Tailscale ACL.** The `ssh` block restricting `tag:compute` to
  `autogroup:nonroot` (`rtj/docs/tailscale-acl.jsonc:69-74`) governs *Tailscale SSH* only; geopro
  runs plain OpenSSH (rtj manages its host key with `ssh-keyscan`) and `acls` has a `*:*` catch-all.

## Other verified facts

- **Register the collection before items** — pgstac items reference the collection row. uav does
  items-first and gets away with it only because its collection pre-exists.
- **Keep `--exclude '*.json'` on the asset sync.** uav's filters are only `--exclude "*/.*"` and
  `--exclude ".*"`; porting those would push the 68 sidecars, taking the bucket 120 → 188 objects.
- **rtj still lists this collection** (`stac_register-all.sh:32`) and reloads it *from S3*. So
  "sync JSON to S3 before registering" is load-bearing — it keeps bucket and API identical, making an
  rtj all-reload a no-op rather than a silent revert.
- **`PARTIAL_STAGE` must be re-guarded upstream of the sync.** All three of 05's interlocks
  (`:139-150`, `:160-162`, `:220-229`) currently sit *after* the 700 MB push.
- `geopro` → MagicDNS `100.111.226.127`, pings from this M1.
- Scale: 17 items, 68 COGs, `data/stac` 703 MB; item JSONs 3.0–9.1 MB each, **94 MB total**.
- Live bucket: 17 asset prefixes + 18 root JSONs = 120 objects.
- `floodplains#32`'s body is a **verbatim copy of #14's**, including the sentence referencing itself.
  Its title promises a producer hook the body never describes — worth re-scoping upstream.
