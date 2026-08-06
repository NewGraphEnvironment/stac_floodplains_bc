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

- [ ] Move validation ahead of the asset sync in `run_pipeline.sh`
- [ ] Snapshot live: 17 ids + collection response
- [ ] `md5` every `data/stac/*.json` — later phases must reproduce byte-identical
- [ ] Preflight geopro (ssh reachable, `/tmp` headroom, `pgstac.delete_item` present)
- [ ] File rtj issue to re-enable bucket versioning

## Phase 1: Registration transport (additive) — PR 2 starts

- [ ] `scripts/item_register.sh` (+ line-count guard, remote `trap`)
- [ ] `scripts/collection_register.sh`
- [ ] `scripts/item_unregister.sh` (keep injection guard + `EXCEPTION … RAISE WARNING`)
- [ ] Smoke: single item register → 200
- [ ] Smoke: truncation drill fails the count guard
- [ ] Smoke: unregister round trip (404 → re-register → 200)

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
