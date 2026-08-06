## Outcome

Publishing this catalogue no longer ends with a manual incantation borrowed from `rtj`. The
lifecycle is two repo-owned commands — `run_pipeline.sh` rebuilds locally and makes **no network
writes at all**, `catalogue_release.sh` validates, syncs, registers and verifies. Registration is a
client-side `pypgstac` upsert over SSH (`item_register.sh`, `collection_register.sh`,
`item_unregister.sh`), ported from `stac_uav_bc` but flattened into `scripts/` and materially
hardened. The first live release through the new path ran in 1m59s, leaving the bucket unchanged at
120 objects. Delivered issue items 1, 2, 4 and 5; item 3 (Version Extension + `NEWS.md` + tags) was
deliberately deferred.

**The headline defect was an ordering bug, and the first fix for it did not work.** `05` already
validated and hard-failed — but `04_s3_upload.R` ran *first*, so ~700 MB of assets reached an
unversioned bucket before anything was checked. Inserting a no-upload gate looked sufficient and
wasn't: `05`'s upload block is `if SKIP_S3_UPLOAD … elif PARTIAL_STAGE`, so the gate always took the
skip branch and **never evaluated the partial-stage refusal**. Three more holes followed, the
deepest being that `skipped` only counts groups the stage loop *reaches* — a region roster missing
from `$FLOODPLAINS_DATA` drops its groups uncounted, so a 14-item collection would have silently
overwritten the live 17. That one is now caught by comparing the build against the **live**
collection before syncing.

**Porting reference code is not the safe option it looks like.** Five defects came from the
reference implementation itself, and the worst was `pgstac.delete_item(id)` without a collection
argument — its body is `WHERE id = _id AND (_collection IS NULL OR collection=_collection)`, i.e.
**unscoped across the shared `stac` db**, which also hosts `imagery-uav-bc-prod`, `stac-airphoto-bc`
and `stac-dem-bc`. Proven live and read-only: for a real `stac-dem-bc` id the unscoped predicate
matches 1 row, the scoped one 0. Also ported-and-fixed: `EXCEPTION WHEN OTHERS` made
`ON_ERROR_STOP=1` dead (every id would report "missing?" and exit 0 having deleted nothing); a
password in `--dsn` sat in `argv` readable via `ps aux`; a fixed remote `/tmp` path allowed a
concurrent run to truncate the payload; and the transfer guard **failed open**, because
`if [ "$got" -ne $N ]` is an if-condition and `set -e` exempts those. Two further port bugs would
have been silent: `item_validate.py` had no lower bound (a wrong `--base` printed `valid: 0` and
exited 0 — the gate opening on nothing), and the preflight's unfielded `GET /items` measured
**38 MB / 31.6 s** against a 60 s timeout, versus 8.5 KB / 0.21 s fielded.

Fourteen real defects across four `/code-check` rounds, most in code that "just needed path edits".
Two of them were in claims *this session had already made and stated confidently* — the airphoto IP
was neither stale nor divergent, and the 9 MB NDJSON corruption was already fixed in the very script
being replaced. Verify against the artifact, not against the last thing you said about it.

Method worth repeating: **read-only proofs before destructive ones.** Checking that `pgstac.items` is
LIST-partitioned by collection (with `ON DELETE CASCADE`) is what made the throwaway-collection dry
run safe with real item ids — had ids been globally unique, registering the test collection would
have *moved* the live items into it. The dry run then exercised the whole orchestration (17 items,
38 MB NDJSON, idempotent on re-run) with production provably untouched. Ordering smoke tests by
ascending blast radius — register before unregister — meant the restore path was proven before
anything was deleted.

Unblocking required rtj#193 (m1 not authorized on geopro), which had been open since 2026-07-19 and
had already forced stac-dem-bc's registration onto the M4. Commented there rather than closing: only
step 1 (manual key append) is done, and it does not survive a droplet rebuild.

Open follow-ups: bucket versioning is **still Suspended** — every guard added here exists because of
that; deferred item 3; provenance (floodplains#33 → #17); and a cosmetic pypgstac timezone warning.

Closed by: PR #16 (Phase 0) and PR #18 (Phases 1-5).
