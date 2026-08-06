# Task: Adopt the converged stac-catalog system (#14)

Publishing this catalog ends with a manual incantation borrowed from `rtj` — `scp` a script to
`root@geopro`, then `ssh` and run it. Registration is tribal knowledge living outside this repo,
nothing here validates items before they go live, and there is no repo-owned way to *remove* an item.

**The defect that matters most is an ordering bug.** `05_stac_register.py:213` already validates and
already hard-fails — but `run_pipeline.sh:27` runs `04_s3_upload.R` *first*, so ~700 MB of COGs and
GeoPackages reach the live bucket before a single item is validated. Bucket versioning is
**Suspended**, so there is no rollback. A second win: rtj's script is delete-then-reload, so between
its `DELETE` and its load the collection serves **zero items**. Upsert removes that outage window.

## Approved decisions

| Decision | Choice |
|---|---|
| Scope | Issue items **1, 2, 4, 5**. **Defer item 3** (Version Extension + NEWS.md + tags). |
| Naming | **Hybrid** — new scripts `noun_verb`; `01`–`05` keep numeric prefixes. |
| Rebuild | **Split** — release must not require the 908 MB `$FLOODPLAINS_DATA` tree. |
| Location | **Flat `scripts/`**, not `scripts/config/`. |
| Reaping | **Upsert + verify + explicit unregister.** Never auto-delete. |
| Host | `HOST="${GEOSERV_HOST:-root@geopro}"`. |
| First run | **Dry-run against a throwaway `stac-floodplains-bc-test` collection.** |
| PR split | **Two PRs.** PR 1 = Phase 0. PR 2 = Phases 1–5. |

## Do NOT port verbatim — each is a live bug in this repo's context

1. **`--delete` on the S3 sync = data loss.** `data/stac` is wiped by `01_stage.R:30-31` every run
   and rebuilt by a stager that *soft-skips* (`:97-101`, `:119-123`) and still exits 0.
2. **uav's verify can never pass here** — reads `.version` and `git describe --tags`; this repo has
   zero tags and no `version` field. Verify must assert **set identity** instead.
3. **uav's verify downloads the whole catalog** — measured 38 MB / 30 s. `fields.include` mandatory.

## Silent-success traps to close

4. `item_validate.py` passes on zero items, and `rglob` matches 68 `.tif.aux.json` sidecars.
5. A truncated ssh transfer registers fewer items and exits 0 at every layer.

## Phase 0: Baseline, preflight, safety fix (PR 1)

- [x] Move validation ahead of the asset sync in `run_pipeline.sh`.
      **Not the two-line change the plan assumed** — validation lives inside `05`, which needs the
      JSON built first, so the gate is `05` run with `SKIP_S3_UPLOAD=1` before `04`, then `05` again
      to upload JSON after the assets land. `05` runs twice by design; costs 1m29s.
- [x] Snapshot live: 17 ids + collection response → scratch. Local ids == live ids exactly.
- [x] `md5` every `data/stac/*.json` (18 files) → scratch baseline.
- [x] Proved the gate: `05a` ran clean (17 items + collection valid, no upload) and reproduced all
      18 JSONs **byte-identical** → the build is deterministic, which is the Phase 2 baseline.
- [x] Proved the negative: a failing gate aborts before `04` (`set -euo pipefail` honoured); bucket
      `LastModified` unchanged.
- [x] **`/code-check` found three real defects the gate did NOT close.** Fixed and each proven:
      1. `05`'s upload block is `if SKIP_S3_UPLOAD … elif PARTIAL_STAGE`, so the gate *always* took
         the skip branch and never evaluated the partial-stage refusal — `WSG_ONLY=morr bash
         run_pipeline.sh` would have pushed a 2-item build's assets. Fixed with a fail-fast
         `WSG_ONLY` guard plus a re-asserted marker check before `04`. (Not by reordering `05` —
         `test_pipeline.R` depends on skip winning.)
      2. An inherited `SKIP_S3_UPLOAD` would make `05b` a silent no-op — assets refreshed, JSON
         stale, pipeline still printing DONE. Fixed with `env -u`.
      3. `01_stage.R` **soft-skips** a group with no `area.yml`/rasters and exits 0 with no marker,
         so a stale `$FLOODPLAINS_DATA` would publish a short collection over the live one. Now
         writes `PARTIAL_STAGE` on any skip (`ALLOW_SKIPPED=1` escapes; strict truthiness so
         `ALLOW_SKIPPED=0` reads as off).
- [x] **Deepest hole, also from review:** `skipped` only counts groups the loop *reaches*. A missing
      region roster yml drops its groups before they are counted, so no marker is written and a
      short-but-valid collection passes the gate. Added a pre-sync check comparing the build against
      the **live** collection; refuses if any live item is absent (`ALLOW_RETRACT=1` escapes).
      Proven: 17/17 passes; a simulated dropped Peace region (14 vs 17) is blocked and names the
      three missing ids; the override works.
- [x] Docs: root `README.md` + `scripts/README.md` both describe the new order and carry an
      env-flag table marking which two flags disable interlocks.
- [ ] Preflight geopro (ssh reachable, `/tmp` headroom, `pgstac.delete_item` present) — **needs
      user go-ahead; first action touching production**
- [ ] File rtj issue to re-enable bucket versioning — **needs user go-ahead (cross-repo write)**

## Phase 1: Registration transport (additive) — PR 2 starts

- [x] `scripts/item_register.sh`, `collection_register.sh`, `item_unregister.sh` written.
- [x] **Review found five defects in the port; all fixed and verified against upstream source:**
      1. **Cross-collection deletion.** `pgstac.delete_item(_id)` leaves `_collection` NULL and its
         body is `WHERE id = _id AND (_collection IS NULL OR collection=_collection)` — unscoped
         across every collection in the shared `stac` db, which also hosts `imagery-uav-bc-prod`
         and `stac-dem-bc`. Confirmed in pgstac v0.9.8 `003a_items.sql`. Now passes the collection.
      2. **`EXCEPTION WHEN OTHERS` made `ON_ERROR_STOP=1` dead** — a permission denial or missing
         `search_path` would report "not deleted (missing?)" for every id and exit 0 having deleted
         nothing. Narrowed to `NO_DATA_FOUND`, which is exactly what `RETURNING * INTO STRICT`
         raises for an absent id (verified in the same source).
      3. **Fixed remote `/tmp` path** — a concurrent run could truncate this one's payload after its
         count guard passed. Now a per-run remote `mktemp`.
      4. **Password in `--dsn` sat in `argv`**, readable via `ps aux` on the droplet for the whole
         multi-minute load. Now `PGPASSWORD` with a password-less DSN.
      5. **The transfer guard failed OPEN.** `if [ "$got" -ne $N ]` is an if-condition, which
         `set -e` exempts, so a non-numeric `$got` printed an error and fell through to the load.
         Now a string compare with `||`.
- [x] Verified locally without touching production: compaction produces one NDJSON line per file;
      the local/remote `$` split renders correctly (`$N`/`$DB` local, `$F`/`$got`/`$PATH`/
      `${POSTGRES_PASSWORD}` remote); `$$` dollar-quoting survives into valid SQL; injection guard
      rejects `;`-bearing ids; usage guards exit 1; local temp cleaned by trap; the remote
      count-guard logic refuses a simulated 12-of-17 truncation.
- [ ] Smoke: single item register → 200 — **needs user go-ahead (writes to live pgstac)**
- [ ] Smoke: unregister round trip (404 → re-register → 200) — **needs user go-ahead**

## Phase 2: Validation gate + rebuild/publish split

- [ ] `scripts/item_validate.py` — depth-1 `glob()`, `--expect N`, collect-all-then-exit-1
- [ ] `05_stac_register.py` — drop in-process validate + upload; keep both preflight guards
- [ ] Fold `04_s3_upload.R` into the release script and delete it (carry the no-`--size-only` comment)
- [ ] `run_pipeline.sh` — no network writes at all
- [ ] `01_stage.R` comment + `test_pipeline.R` call the same gate
- [ ] Regression: md5 of 18 JSONs matches Phase 0
- [ ] Negatives: corrupt `type` → exit 1; empty `--base` → exit 1

## Phase 3: `scripts/catalogue_release.sh`

- [ ] Step 0 preflight (PARTIAL_STAGE, item count, ssh, orphan check + `--allow-retract`)
- [ ] Step 1 validate gate
- [ ] Step 2 sync assets (no `--delete`, no `--size-only`, keep `--exclude '*.json'`)
- [ ] Step 3 sync JSON (keeps bucket authoritative for rtj's all-reload)
- [ ] Step 4 register collection, then items
- [ ] Step 5 verify (fielded search, `live == local` both ways, asset probe)
- [ ] Headline test: post-smoke-test tree aborts at step 0 with zero S3/ssh calls
- [ ] Orphan drill; idempotence (second run is a no-op)
- [ ] **Dry run on `stac-floodplains-bc-test`, then unregister**

## Phase 4: Docs + retraction recipe

- [ ] `scripts/README.md` — two-command lifecycle + retraction recipe
- [ ] `README.md` + `CLAUDE.md` — registration is repo-owned
- [ ] Follow-up issue for deferred item 3
- [ ] Decide + record the rtj `stac_register-all.sh:32` entry

## Phase 5: Live release

- [ ] Clean rebuild → release; 17 live, 0 orphans, asset probe 200
- [ ] Keep rtj path as recovery until a couple of clean releases

## Validation

- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
