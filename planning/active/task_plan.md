# Task: Retire the per-species floodplain items as each group's whole-network item publishes (#76)

**If we do it:** the catalogue carries one floodplain model, the whole-network one (`all_ff0N`,
floodplains#104), and a consumer is never offered two different floodplains for the same watershed
group.
**If we never do:** each group carries both a per-species floodplain and a whole-network one. They
are built on different networks and, after floodplains#117, on different DEM grids, so the two
disagree with nothing in the items to say which is current.

floodplains#125 retires the per-species items rather than re-running them. The publish path has no
mechanism for that: `--allow-retract` *permits* publishing past a live item absent from the build but
never removes one (`catalogue_release.sh:543-547` tolerates `extra` under the flag, so
`RELEASE COMPLETE` prints with the retired items still live), and `scripts/README.md`'s
`## Retraction` recipe is a *removal* recipe that unregisters before publishing — taking the group
dark, and opening a window in which the bucket `collection.json` links a deleted object.

## Decisions taken (airvine, 2026-10-14)

1. **S3:** delete both `s3://stac-floodplains-bc/<id>/` and `<id>.json`, after the release verifies.
   The irreversible step lives in its own guarded script, not in the release path.
2. **Retraction:** the release performs the pgstac delete, from a `RETIRED_ITEMS` literal.
3. **#79:** closes by construction — note the mechanism and close it.

**The invariant the whole design rests on:** the bucket copy is the rollback for the pgstac delete.
Neither `aws s3 sync` passes `--delete` and the S3 step is separate and later, so a retired item can
be re-registered from `s3://$BUCKET/<id>.json` by `item_register.sh`. That is why the irreversible
half is a separate script, and why the delete is safe to put inside the release at all.

## Phase 1: Harness knobs the new arms cannot be proven without

`scripts/catalogue_release-check.sh` runs a committed, tagged copy of `scripts/` against shimmed
`aws`/`ssh`/`uv`/`curl`. Three limitations block the mutation table; fix them first.

- [x] a `FAKE_GONE_IDS` knob, honoured **before** the blanket `printf '200'` at `:232` and in the
      `*/items/*` branch, so a retired id can be made to 404
- [x] `n_delete()` — count `delete_item` payloads in the `ssh` shim log — and add it to `refused()`
      (`:362-365`), which today asserts only `RC != 0 && n_aws == 0` and so would pass a refusal that
      fired *after* a destructive ssh call. Add it to case 3's existing refusals too.
- [x] a third live-id stage beside `FAKE_LIVE_IDS` / `FAKE_LIVE_IDS_AFTER` (`:206-208`): the
      two-phase design makes three searches, so without it phase A already sees the retracted set

## Phase 2: Tests — the new arms, failing

- [x] 20a orphans present, `RETIRED_ITEMS` empty, no `--allow-retract` → refused, no `aws`, no delete
- [x] 20b an orphan **not** in `RETIRED_ITEMS` → refused, naming the unintended id
- [x] 20c a literal id neither live nor in the bucket → refused ("never published — check the literal")
- [x] 20d a literal id not live but **present in the bucket** → *reported*, release proceeds
      (idempotency: the re-run after a verify failure must not refuse)
- [x] 20e a literal id present in the build → refused
- [x] 20f a live watershed group covered by no build item → refused (the `ALLOW_SKIPPED=1` arm)
- [x] 20g a `RETIRED_ITEMS` id absent from the tagged `NEWS.md` top section → refused
- [x] 20h `--only` with a non-empty `RETIRED_ITEMS` → refused at `:106-110`
- [x] 21a positive control: literal set == orphans, every group replaced → the delete runs (proved
      from the `ssh` shim argv log) and the release completes
- [x] 21b a probe fails before the delete → `RELEASE INCOMPLETE` with **zero** `delete_item` payloads
- [x] 21c phase B: a retired id still served after the delete → `RELEASE INCOMPLETE`
- [x] 21d empty literal, clean release → zero `delete_item` payloads, completion line unchanged
- [x] 21e `--allow-retract` remainder: an orphan outside the literal is permitted, gets **no** delete
      (this is harness case 9m's successor; 9m itself must be rewritten, not deleted)
- [ ] 22 `item_retract_s3.sh` refuses while the id is still served or still linked from the bucket
      `collection.json`
- [ ] anchored-sed twin for `RETIRED_ITEMS` beside `:393`'s `PROVENANCE_FLOOR` check, asserting it is
      one bare literal **and empty on `main`** — a shipped non-empty literal is itself a failure
- [ ] mutation table in `findings.md`; the implied half of the set relation recorded as implied
      rather than covered

## Phase 3: `RETIRED_ITEMS` and the preflight arms

- [ ] `RETIRED_ITEMS` literal beside `PROVENANCE_FLOOR` (`:61`) and `EXPECT_LICENSE` (`:67`); empty by
      default, no env override
- [ ] refuse `--only` + non-empty literal at `:106-110`
- [ ] replace the orphan block (`:330-342`) with: `orphans ⊆ RETIRED_ITEMS` **unless**
      `--allow-retract` (which permits the remainder and gives it no delete); the split typo/
      already-retired arm using `$S3_BASE/<id>.json` as the one independent witness; not-in-build;
      live-groups ⊆ build-groups; every literal id named in the tagged `NEWS.md`
- [ ] `fetch_live_wsgs()` — a fielded `POST /search` with `fields.include: ["id","properties.wsg"]`;
      build groups from `data/raw/<item_id>/meta.json`. No id is parsed apart.
- [ ] comment the `ALLOW_SKIPPED=1` justification on the group arm, and that the DEPRECATED overlap
      arm was deliberately **not** added (`item_validate.py:394-395` is the guard; a third copy of
      `DEPRECATED_ITEMS` is drift nothing pins)

## Phase 4: the delete, placed after every probe

- [ ] phase A, in place of `:540-547`: keep the `missing` arm; require `extra ⊆ RETIRED_ITEMS`
      (containment, not equality — equality is what breaks the re-run)
- [ ] run every existing probe; if `fail != 0`, exit **without deleting**
- [ ] delete via `COLLECTION="$COLLECTION" GEOSERV_HOST="$HOST" bash scripts/item_unregister.sh …`
      — neither variable is exported (`:37`, `:42`), so omitting them silently targets the default
      collection. `item_unregister.sh` itself is reused unchanged.
- [ ] phase B: re-read the live set; require `served == build` exactly, and each retired id 404s.
      `item_unregister.sh` warns and exits 0 when it deletes nothing (`:49-51`) and the release never
      parses its NOTICEs, so the 404 assertion is the **only** evidence the delete happened.
- [ ] on phase-B failure, print the two-line remedy and name the bucket-copy rollback

## Phase 5: the sync-ordering hazard this release maximises

- [ ] `:497-498` syncs `collection.json` and every item JSON in one parallelised pass. Sync the item
      JSONs with `--exclude collection.json`, then `aws s3 cp` the collection last, as the
      `--skip-sync` path already does at `:452`
- [ ] a harness case asserting the collection is the **last** JSON object written

## Phase 6: the two dead guards the upstream flip left behind

- [ ] `test_pipeline.R:25` — default `WSG=ufra` is unstageable today (13 of 23 groups are); move it to
      a group that stages
- [ ] `stage_years-check.R:63` — default `AREA=ufra` skips every case and prints "the call site was
      NOT proven"; move it, and re-take or retire the `ufra_ch_ff04` `meta.json` fold pin at `:217-231`
      that sits unreachable behind that skip

## Phase 7: documentation

- [ ] `scripts/README.md`: split `## Retraction` into **Removal** and **Replacement**, both ordered
      release-first; correct `:139-140`, which claims `--allow-retract` is required at a step where
      its own recipe has already made it a no-op; name the rtj reload hazard
- [ ] `## Cut a release`: the retirement happens inside step 4-5, and step 6 (README rebuild) is
      after it — the ordering #79 turns on
- [ ] fix stale prose in `catalogue_release.sh`: `:12`, `:17` ("20-group" / "20-item"), `:116`
      ("17 items")
- [ ] `CLAUDE.md`: the Collection model paragraph on MORR's two live orphans, and the Catalog
      registration paragraph on upsert-and-orphans

## Phase 8: release bookkeeping and issue hygiene

- [ ] `NEWS.md` **Unreleased**: the mechanism; that the first retirement release names its ids in
      `RETIRED_ITEMS` and in its own entry; and that it retires **17 at once**, not per group
- [ ] record the literals re-taken on the build the release is cut from — `PROVENANCE_FLOOR`,
      `PROV_CENSUS` (`item_validate.py:540-553`), `prov_fields-check.py`'s 18/21/23 — all in the same
      commit as the tag, since the clean-tree gate leaves no room to fix them after
- [ ] record that `ALLOWED_YEAR_SETS` needs **no** change (measured), and the two per-species `ITEM=`
      defaults that would break if SLOC ever retires
- [ ] record the `v2.0.0` collision: `NEWS.md:13-18` reserves it for corrected geometry everywhere,
      and `mcgr_ch_ff04` survives this release, so a release deleting 17 public item ids ships as a
      minor bump
- [ ] raise MCGR upstream (floodplains, our own repo): its `area.yml` must go back to `ch_ff04` until
      floodplains#76 clears, or neither of its items can stage
- [ ] comment on #79 with the mechanism and close it
- [ ] edit #76's body: the migration is one full release retiring 17 items, not group-by-group, and
      add the MCGR prerequisite to "Depends on"

## Validation

- [ ] `bash scripts/catalogue_release-check.sh` — every case, old and new, green
- [ ] `bash -n` on every edited shell script; `shellcheck` if available
- [ ] the smoke test passes on its **new** default, and `stage_years-check.R` reports assertions
      rather than a skip
- [ ] mutation table: every new arm, defect restored, arm red
- [ ] Tests pass
- [ ] `/code-check branch` clean
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion

**Not verifiable on this branch, and said so:** no live retirement runs here. No `*_all_ff04` item is
live, and a full release is blocked upstream by floodplains#125 (13 of 23 groups unrun),
floodplains#133 (DUNC) and the MCGR config state above. The first exercise is the release that
publishes them.
