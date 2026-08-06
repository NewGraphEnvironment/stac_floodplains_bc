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
- [x] Preflight geopro — done in Phase 1 once rtj#193 step 1 unblocked SSH (see below).
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
- [x] **Unblocked:** `ssh root@geopro` was `Permission denied (publickey)` from the M1 — already
      diagnosed as **rtj#193** (open since 2026-07-19; the same gap forced stac-dem-bc's
      registration onto the M4 on 2026-07-18). Fixed via that issue's step 1, appending the M1 key
      to geopro's root `authorized_keys` from the M4. The durable `ssh_key_ids` fix stays open
      there because it can plan as a droplet replacement.
- [x] Preflight: pgstac **0.9.8**; 65 GB free on `/`; `uv` at `/root/.local/bin`; all five
      containers up; `delete_item(_id text, _collection text DEFAULT NULL::text)` confirmed.
- [x] **The delete-scoping bug proven live, read-only.** The `stac` db hosts four collections
      (`imagery-uav-bc-prod`, `stac-airphoto-bc`, `stac-dem-bc`, `stac-floodplains-bc`). For a real
      `stac-dem-bc` id, the unscoped predicate matches **1** row; scoped to this collection it
      matches **0**. The ported code would have deleted another collection's item.
- [x] Smoke: register `kisp_ch_ff04` (2.25 MB) → 3.4 s → HTTP 200, all 9 properties and 6 assets
      unchanged.
- [x] Smoke: unregister a non-existent id → WARNING, exit 0 (idempotent).
- [x] Smoke: full round trip → unregister → **404**, count 16 → re-register → **200**, count 17.
      Live id set afterwards **byte-identical** to the pre-test baseline.
- [x] Fixed: a successful delete printed nothing (server `client_min_messages` sits above NOTICE),
      so the one destructive script was silent on success. Now sets `client_min_messages=notice`.
- [ ] Noted: pypgstac emits `unknown PostgreSQL timezone: 'Canada/Pacific'; will use UTC` on every
      register — the M1's TZ rides the ssh env. Harmless (UTC is deterministic, STAC datetimes are
      explicit UTC), but worth silencing later.

## Phase 2: Validation gate + rebuild/publish split

- [x] `scripts/item_validate.py` — depth-1 `glob()` (the 68 `.tif.aux.json` sidecars are never in
      scope), `--expect N`, collect-all-then-exit-1.
- [x] `05_stac_register.py` — dropped in-process validate + upload; kept both preflight guards.
      **1m29s → 3.9s**, and validation now runs once instead of twice.
- [x] Deleted `04_s3_upload.R`, folded its sync into the release script with the no-`--size-only`
      comment carried verbatim.
- [x] `run_pipeline.sh` — no network writes at all; "a smoke test cannot clobber prod" is now
      architectural rather than env-var-dependent.
- [x] `01_stage.R` comment + `test_pipeline.R` now call the same gate a release uses.
- [x] **Regression: all 18 JSONs byte-identical to the Phase 0 baseline** — the refactor changed
      no output.
- [x] Negatives all pass: empty `--base` → exit 1 (the original printed `valid: 0` and exited 0);
      no `meta.json` → exit 1; 2 items when 17 expected → exit 1; corrupt `type` → named and exit 1.

## Phase 3: `scripts/catalogue_release.sh` — written

- [x] Steps 0–5 implemented (preflight → validate → sync assets → sync JSON → register collection
      then items → verify).
- [x] **Headline test:** the post-smoke-test tree (`PARTIAL_STAGE` present) is refused at preflight
      with **zero** validate, sync, ssh or register calls.
- [x] Orphan drill: a build missing `pars_bt_ff04` is refused at preflight, the item is named, and
      the exact `item_unregister.sh` command is printed. No sync, no register.
- [x] **Review found five defects; all fixed:**
      1. **The advertised split-machine workflow did not work.** `item_validate.py` derived
         `--expect` from `data/raw/*/meta.json`, which a release-only machine does not have → 0 →
         refuse. The release now passes `--expect "$n_local"`; detecting a *short* build is the
         live-vs-build comparison's job, which needs no `data/raw`.
      2. Preflight used an **unfielded** `GET /items` — measured **38 MB / 31.6 s**, already half
         the 60 s timeout and growing with every group added. Now the same fielded `POST /search`
         as verify: **8.5 KB / 0.21 s**.
      3. The `ALLOW_SKIPPED` banner the README promises had been deleted with the old gate block.
         Restored.
      4. `test_pipeline.R`'s closing message still said to publish with `run_pipeline.sh`, which no
         longer writes anything.
      5. **The asset probe had no teeth** — it fetched the alphabetically-first asset, which exists
         from every prior release and returns 200 even if the sync uploaded nothing. Now probes the
         **largest** local asset and compares `Content-Length` to the local byte count (verified:
         12,025,856 both sides; a missing object yields no header and fails).
- [ ] Idempotence: two consecutive releases, second a clean no-op — **needs a real release**
- [ ] **Dry run on `stac-floodplains-bc-test`, then unregister** — not yet run

## Phase 4: Docs + retraction recipe

- [x] `scripts/README.md` — two-command lifecycle, rebuild + release tables, the retraction recipe,
      and an env-flag table marking which flag disables an interlock.
- [x] `README.md` — pipeline table, the guards section, and registration documented as repo-owned
      (the rtj `stac_register-pypgstac.sh` block retired).
- [x] Recorded why rtj's `stac_register-all.sh:32` entry can stay: step 3 syncs the JSON before
      step 4 registers, so bucket and API always agree and an rtj all-reload is a no-op.
- [ ] Follow-up issue for deferred item 3 (Version Extension + NEWS.md + tags, and the
      `05_stac_register.py` rename)

## Phase 5: Live release

- [ ] Clean rebuild → release; 17 live, 0 orphans, asset probe 200
- [ ] Keep rtj path as recovery until a couple of clean releases

## Validation

- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
