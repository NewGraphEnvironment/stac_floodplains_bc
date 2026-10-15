# Findings — Retire the per-species floodplain items (#76)

## Issue context

**If we do it:** the catalogue carries one floodplain model, the whole-network one (`all_ff0N`, floodplains#104), and a consumer is never offered two different floodplains for the same watershed group.
**If we never do:** each group carries both a per-species floodplain and a whole-network one. They are built on different networks and, after floodplains#117, on different DEM grids, so the two disagree with nothing in the items to say which is current.

## Decided (2026-10-13, floodplains#125)

floodplains moves every region to whole-network floodplains. The per-species items (`<wsg>_co_*`, `<wsg>_ch_*`, `<wsg>_bt_*`) are **retired, not re-run**.

## Work

- **Retire per group, as each group's `all` item is published.** The catalogue should never lose a group between the two. A group whose whole-network run is blocked upstream (MCGR, floodplains#76) keeps its species item until it is replaced.
- Use `scripts/item_unregister.sh` for the API side. Follow the retraction recipe in `scripts/README.md` for the S3 objects, or decide deliberately to keep them at their URLs.
- **Stop staging species scenarios** once a group is whole-network, so a rebuild does not re-register what was retired. floodplains' `data/<wsg>/` will still hold the species layers for a while (floodplains#125, work item 3).
- Record the retirement in the release notes for the version that carries it, listing the item ids removed.

## Depends on

- #75 (admit `all_ff04`). Nothing can be retired until its replacement can publish.
- floodplains#125 (whole-network region runs) and floodplains#123 (GeoParquet).

Relates: #75, floodplains#125, floodplains#123, floodplains#59


## Issue comments

### Comment 2026-10-14T12:43:39Z

From floodplains#125 (2026-10-14): retirement is now driven by the floodplains config.
- The converted groups' `area.yml` names only `all_ff04`, and MORR's `targets` block is gone. A rebuild after stac#75 therefore stages no species items for BULK, MORR or KISP.
- `catalogue_release.sh` will then see `bulk_co_ff04`, `morr_co_ff04`, `morr_ch_ff06` and `kisp_ch_ff04` live but absent from the build, so the first release needs `--allow-retract`, or whatever retirement mechanism this issue settles on.
- The species outputs stay on disk in `data/<wsg>/` (floodplains#131 prunes them only after this issue lands), so any staging of them in the meantime still has its files.

### Comment 2026-10-14T16:05:00Z

#79 filed from #75's exploration: the coverage table's once-per-group `floodplain_ff04_km2` total refuses when a group carries both an `all_*` and a species item, and a whole-network item genuinely disagrees with its group's species item (BULK 659.99 vs 386.53 km², measured 2026-10-14). It fails safe and the two-item state ends here, in this issue — so the ordering matters: retire the species item before regenerating the README (release step 6), or take #79's option 2.

## Measured state, 2026-10-14 — nothing can be retired yet

| fact | measurement |
|---|---|
| live collection | 23 items, **all per-species**; no `*_all_ff04` is live |
| upstream roster | 23 groups; all 4 `config/regions/*.yml` are `network: whole`; **no** `area.yml` carries a `targets:` block |
| `primary_scenario` | 17 groups `all_ff04`, 6 still `bt_ff04` (kotl larl pars pcea pine sloc) |
| whole-network rasters on disk | **4 of 23** — `data/{bulk,dunc,kisp,morr}/rasters/all_ff04/` only |
| a full rebuild today | stages 10, skips 13 → `PARTIAL_STAGE` → release refuses (`catalogue_release.sh:215-228`) |
| DUNC | in the roster, never published, blocked by floodplains#133 |
| the four orphans | 300.3 MB of assets + 24.4 MB of root `item.json` = 32% of the 1020.3 MB bucket |

Live ids, from `POST /search` over `images.a11s.one`: `bowr_ch_ff04 bulk_co_ff04 fran_ch_ff04
kisp_ch_ff04 kotl_bt_ff04 larl_bt_ff04 lchl_ch_ff04 lnth_ch_ff04 lsal_ch_ff04 mcgr_ch_ff04
mork_ch_ff04 morr_ch_ff06 morr_co_ff04 necr_ch_ff04 pars_bt_ff04 pcea_bt_ff04 pine_bt_ff04
sloc_bt_ff04 tabr_ch_ff04 thom_ch_ff04 ufra_ch_ff04 unth_ch_ff04 will_ch_ff04`.

The scenario directories, which are what `01_stage.R:379-384` addresses
(`file.path(src_wsg, "rasters", scenario)`, skip if absent):

```
bulk  all_ff04 co_ff04      dunc  all_ff04      kisp  all_ff04 ch_ff04
morr  all_ff04 ch_ff06 co_ff04
everything else: one species dir only
```

So the 13 groups whose `area.yml` says `all_ff04` but which have no `rasters/all_ff04/` —
bowr fran lchl lnth lsal mcgr mork necr tabr thom ufra unth will — each skip their one target and
land in `skipped`, which writes `PARTIAL_STAGE` (`01_stage.R:794-805`).

## The migration is one full release, not group-by-group

The issue says "retire per group, as each group's `all` item is published". Two independent
mechanisms make incremental publishing impossible, so it cannot be done that way:

1. **`--only` cannot add a new item.** Its preflight reads the live item first
   (`catalogue_release.sh:300-305`) and aborts "Could not read the live item's provenance — refusing
   to publish blind" when the id is not live. `--only` also never publishes `collection.json`.
2. **The README refuses any item/collection mismatch.** `fp_readme_check_complete()`
   (`readme_functions.R:133-148`) stops unless the API search count equals the bucket
   `collection.json`'s `rel: item` link count, read by `fp_readme_bucket()` (`:118-122`). An item
   published without `collection.json` breaks the render in one direction; an item unregistered
   without republishing `collection.json` breaks it in the other.

So the retirement waits on floodplains#125 completing the remaining 13 groups and on
floodplains#133 unblocking DUNC, and then lands as one release.

## `--allow-retract` permits, it never retracts

`catalogue_release.sh:330-342` refuses on orphans unless the flag is set, and **prints** the
`item_unregister.sh` command the operator should run. Nothing requires them to run it. Step 5's
reverse comparison (`:543-547`):

```sh
extra=$(comm -13 <(printf '%s\n' "$local_ids") <(printf '%s\n' "$after_ids") || true)
if [ -n "$extra" ] && [ -z "$ALLOW_RETRACT" ]; then
```

tolerates `extra` under the flag, so `RELEASE COMPLETE` prints with every retired item still live —
the two-floodplains-per-group state the issue exists to prevent. The deprecation read-back has the
same hole and says so at `:704-712`: a retracted item still live serving `deprecated: true` "is
reported by nothing, and RELEASE COMPLETE prints."

## The existing `## Retraction` recipe is a removal recipe, and it has an rtj hazard

`scripts/README.md:122-140` orders it: drop upstream → rebuild → `item_unregister.sh` →
delete S3 → release `--allow-retract`. Two defects for this use case:

1. **It takes the group dark.** Unregistering before the replacement publishes is the opposite of
   the issue's "the catalogue should never lose a group between the two".
2. **Between its step 4 and step 5 the bucket `collection.json` links a deleted object.** rtj's
   reload-from-S3 (`rtj/scripts/geoserv/stac_register-pypgstac.sh`) reads the bucket
   `collection.json`, extracts every `rel: item` href, then `DELETE FROM pgstac.items WHERE
   collection = ...` (step 2), downloads each href, and aborts `FATAL` if any is missing — leaving
   the collection serving **zero items**. Its own comment at ~line 91 records that happening to
   `stac-dem-bc`.

A reload is also why a leftover `<id>.json` in the bucket root is *not* a resurrection risk: the
reload is driven by `collection.json`'s links, not by a bucket sweep. Neither `aws s3 sync` passes
`--delete` (`:483-489`, `:497-498`), deliberately, so the retired objects do persist until deleted
explicitly.

## `ALLOWED_YEAR_SETS` needs no change — measured, not assumed

`item_validate.py:1908-1925` arm (b) refuses a sanctioned year set that **no** item uses, so a
retirement that emptied a tuple would require deleting it. Counting `classified_<yyyy>.tif` in every
`data/*/rasters/*/`:

- annual (2017–2023, 7 years): `bulk/all_ff04`, `bulk/co_ff04`, `kotl/bt_ff04`, `lnth/ch_ff04`,
  `necr/ch_ff04`
- three-year (2017, 2020, 2023): the other 23 scenario dirs

`kotl` stays `bt_ff04` and `bulk_all_ff04` is annual, so the annual tuple keeps users after any
retirement; the three-year tuple obviously does. Both populations survive, and
`year_sets-check.py:113-115` — which hard-asserts both tuples are present — needs no edit.

## Literals a retirement must move, and when

`PROVENANCE_FLOOR` (`catalogue_release.sh:61` = 21) and `PROV_CENSUS` (`item_validate.py:540-553`)
are exact in both directions, so both move when items are retired and `all_ff04` items added. They
are **deliberately not re-measured here**: the convention is that they are re-taken on the build the
next full release is cut from, and that build does not exist (see CLAUDE.md on the DUNC/#133 census
delta). `prov_fields-check.py` hard-asserts 18/21/23 at `:196-210`, `:269-279` and `:314-354` and
moves with them.

`DEPRECATED_ITEMS` (`item_create.py:91`) and `EXPECTED_DEPRECATED` (`item_validate.py:258`) are
`{mcgr_ch_ff04, pine_bt_ff04}`. `pine` stays `bt_ff04`; `mcgr` is configured `all_ff04` but has no
whole-network rasters, so **this branch's preflight arm is the guard, not an edit**: retiring
`mcgr_ch_ff04` while it remains in those two literals must refuse, because the marker would name an
id the build no longer contains.

Two per-species `ITEM=` defaults break if SLOC ever retires — `gpkg_determinism-check.R:27` and
`style_determinism-check.py:58`, both `sloc_bt_ff04`. SLOC stays `bt_ff04` today.

## Errors Encountered

| Error | Resolution |
|-------|------------|

## Plan review (Plan agent, 2026-10-14) — verified claims that changed the design

Spawned against the first draft of the design. Each claim below was reproduced before it was
acted on; three of them changed the shape.

### 1. The in-band delete was placed before every probe that could veto it [Blocker — accepted]

Verified: the orphan block is in **step 0** (`catalogue_release.sh:201-202`, orphans at `:330`) and
validation is **step 1** (`:414-416`); a delete "between register and verify" would precede the asset
probe (`:568-574`), the checksum probe (`:586-594`), the version read-back (`:642-668`), the licence
read-backs (`:685-693`, `:748-756`) and the deprecation read-back (`:716-746`) — all of which set
`fail=1` and fall through. The bad day is 17 items deleted and `RELEASE INCOMPLETE`.

**And a re-run would then refuse**, which is worse: an arm refusing "a literal id that is not live"
makes the second attempt impossible, while the clean-tree gate (`:377-381`) and the exact-tag gate
(`:367-371`) mean editing the literal costs a new commit, a new NEWS entry and a new tag.

Resolved by deleting **after** `fail` has been evaluated for everything else, and by a two-phase
membership expectation: phase A requires `served − build ⊆ RETIRED_ITEMS` (containment, not
equality, which is what preserves the re-run), then every probe, then the delete only if
`fail == 0`, then phase B requires `served == build` exactly.

**The invariant the first draft never named:** the bucket copy is the rollback for the pgstac
delete. Neither sync passes `--delete` and the S3 step is separate and later, so a retired item can
be re-registered straight from `s3://$BUCKET/<id>.json` by `item_register.sh`. That is the whole
reason the irreversible half is a separate script.

### 2. Half of the set-equality arm cannot fire [Gap — accepted]

`orphans = live − build` (`:330`). Any id in `RETIRED_ITEMS` that is live and not in the build is in
`orphans` **by construction**, so `RETIRED_ITEMS ⊆ orphans` is implied by the liveness and
not-in-build arms and no mutation can make it fire. Only `orphans ⊆ RETIRED_ITEMS` bites. The
mutation table says "implied" rather than pretending to cover it.

### 3. `--allow-retract` must stay, and the README's claim about it is already false [Gap — accepted]

Verified: as `scripts/README.md:122-140` orders the recipe, `item_unregister.sh` runs at step 3, so
by step 5 the id is not live, `orphans` at `:330` is empty, and nothing is refused.
`README.md:139-140` ("`--allow-retract` is required at step 5") is **false on its own recipe**, and
the step-5 `extra` escape is unreachable on that path. The rewrite fixes the claim rather than
carrying it forward.

The flag stays because the new block replaces the orphan block, and the "group survives" arm refuses
exactly the other kind of retraction — a group leaving the catalogue with no replacement. So
`orphans ⊆ RETIRED_ITEMS` **unless** `--allow-retract`, which permits the remainder and gives it no
in-band delete.

### 4. The "group survives" arm is the only guard that survives `ALLOW_SKIPPED=1` [accepted]

With `ALLOW_SKIPPED=1` (`01_stage.R:796-800`) no `PARTIAL_STAGE` is written, so the `:217-227`
interlock is **absent rather than passing** and today's 10-item build looks like a full one. The
orphan set would be 17 ids a human could legitimately write into the literal, and every other arm
would pass — publishing a collection that silently loses 13 watershed groups to a store with no
rollback. That is the arm's actual justification and it belongs in its comment.

Implemented over the `wsg` **property** on both sides, not a `${id%%_*}` prefix: live groups from a
fielded `POST /search` (`fields.include: ["id","properties.wsg"]`), build groups from
`data/raw/<item_id>/meta.json`. CLAUDE.md's rule is that nothing here parses an id apart.

### 5. `--only` + a non-empty literal was unhandled [Blocker — accepted]

The orphan block is the `else` of `:329`, so under `--only` none of the new block runs: an operator
who sets the literal and then reaches for `--only` gets no delete, no refusal and no mention, and the
literal is still there for the next release. Refused at `:106-110`, beside the existing
`--only` + `--allow-retract` refusal. Chosen over a "skipped under --only" line, which would also
have moved the harness's `grep -c` at `:604` from 4 to 5.

### 6. The DEPRECATED overlap arm was dropped [Assumption — accepted]

`item_validate.py:394-395` already refuses an `EXPECTED_DEPRECATED` id absent from the build, on the
non-`--partial` path a full release takes, and that is step 1 — also before any write. The only gain
was message quality, and the cost was a **third** copy of `DEPRECATED_ITEMS` (`item_create.py:91`,
`item_validate.py:258`) that nothing pins. Dropped; the validator is the guard, and this is recorded
so the next reader does not re-add it.

### 7. A pre-existing sync-ordering hazard, at its largest exposure ever [Ordering — accepted]

`:497-498` syncs `collection.json` **and** every item JSON in one `aws s3 sync` pass, which the CLI
parallelises. If `collection.json` lands and the pass then fails, the bucket links an object that
does not exist — and rtj's reload `DELETE`s the collection before discovering the shortfall
(`stac_register-pypgstac.sh:55`, `:100-103`), leaving it empty. This exists today, but today a
release adds zero new items; the retirement release adds 17. The fix is already written in the same
file: sync the item JSONs with `--exclude collection.json`, then `aws s3 cp` the collection last,
exactly as the `--skip-sync` path does at `:452`.

### 8. MCGR makes the release impossible, from two directions [Blocker — upstream prerequisite]

Measured: `config/mcgr/area.yml:3,6` say `species: all` / `primary_scenario: all_ff04`, and
`data/mcgr/rasters/` holds only `ch_ff04`. So `mcgr_all_ff04` cannot stage **and** `mcgr_ch_ff04` is
in no build. The "group survives" arm refuses it, and independently `item_validate.py:394-395`
refuses at step 1 because `mcgr_ch_ff04` is in `EXPECTED_DEPRECATED` and absent from the build.

The issue's own rule — "a group whose whole-network run is blocked keeps its species item until it is
replaced" — is **not implementable downstream**. It needs `config/mcgr/area.yml` back on `ch_ff04`
(or carrying a `targets:` block naming it) until floodplains#76 clears. Raised upstream; recorded in
#76's "Depends on".

### 9. Two of this repo's own guards silently stopped proving anything [Gap — accepted]

Both caused by the upstream flip, both reproduced:

- `test_pipeline.R:25` defaults `WSG=ufra`. `ufra` declares `all_ff04` and has only
  `rasters/ch_ff04`, so `01_stage.R:380-382` skips it and the smoke test stops with "no items staged
  for UFRA". True today for **13 of 23** groups.
- `stage_years-check.R:63` defaults `AREA=ufra` and derives `SCEN` from `primary_scenario` (`:99`),
  so `ITEM` is `ufra_all_ff04`; `data/ufra/provenance.json` carries only a `ch_ff04` landcover
  section, so `:128-131` skips **every case** and prints "0 assertions, 0 failed, 1 skipped — the
  call site was NOT proven". The reconciliation guard's documented default invocation proves nothing,
  and the `ufra_ch_ff04` `meta.json` fold pin at `:217-231` is unreachable behind that skip.

### 10. Harness limitations that block the mutation table [accepted]

- `catalogue_release-check.sh:232` — `if [ -n "$w" ]; then printf '200'; exit 0; fi` returns 200 for
  **every** `-w '%{http_code}'` call, before the `*/items/*` branch is reached. A retired id cannot
  be made to 404 without a new knob.
- `refused()` at `:362-365` asserts `RC != 0 && n_aws == 0`. The new destructive step goes over
  **ssh**, so a refusal firing *after* a delete would pass `refused()`. Needs an `n_delete()` in that
  conjunction.
- `FAKE_LIVE_IDS` / `FAKE_LIVE_IDS_AFTER` already exist (`:206-208`), switched by a `$COUNTER` file on
  the first search call — but the two-phase design makes **three** searches, so a third stage is
  needed or phase A would already see the retracted set.
- The harness runs a committed, tagged copy of `scripts/` (`:99-102`), so mutating the literal per
  case needs `tgit commit -am` + `tgit tag -f`, the pattern cases 11 and 13 already use
  (`:554-558`, `:571-574`).

## Red run, Phase 2 (2026-10-14)

`bash scripts/catalogue_release-check.sh` with the cases in and no implementation:

| case | red, and for the right reason |
|---|---|
| 20 | `grep -c '^RETIRED_ITEMS=""$'` is 0 — the literal does not exist |
| 20a | reaches the real orphan block and prints the OLD message; the new one is absent |
| 20b+ | `set_retired` aborts: "no RETIRED_ITEMS literal to set" |

**One false pass caught by the red run itself.** Case 3f puts `PARTIAL_STAGE` back and nothing
took it off again, so every new case — all full releases — was refused by the interlock
*upstream of the whole preflight*, and `refused()` passed on the strength of a message about
partial staging rather than about retirement. A guard failing toward pass, arriving through the
fixture rather than the code. Fixed by clearing the marker at the top of the block, and it is
the reason case 21a (the positive control) is not optional: without it every refusal above is a
grep that has never been shown to match.

## Mutation table (2026-10-14)

Each arm's refusal disabled in `catalogue_release.sh`, the whole suite re-run, and the case
that must notice recorded. Ten arms, ten reds — the second column is the case that went red,
not the case it was aimed at, so a mutation caught by the wrong case would show here.

| # | arm disabled | case that went red |
|---|---|---|
| M1 | the containment arm (orphans ⊆ `RETIRED_ITEMS`) | 20a, 20b |
| M2 | never-published vs already-retired, told apart by the bucket copy | 20c |
| M3 | already-retired is reported, not refused | 20d |
| M4 | the not-in-build arm | 20e |
| M5 | the group arm | 20f |
| M6 | the NEWS arm | 20g |
| M7 | `--only` + a non-empty literal | 20h |
| M8 | the delete's placement after the `fail` gate | 21b (+ 17 others) |
| M9 | the still-served arm in step 7 | 21c, 21f |
| M10 | the delete's scope (live subset, not the whole literal) | 20d |

**The implied half is recorded as implied, not covered.** `RETIRED_ITEMS ⊆ orphans` cannot
fire: `orphans = live − build`, so any literal id that is live and not in the build is in
`orphans` by construction, and an id failing either of those two conditions is refused by the
liveness or not-in-build arm first. No mutation can make that half red, so the relation
implemented is containment in one direction only.

**Two rounds, and the first round's STILL GREENs were both my probe, not the guard.** M4 and
M10 came back green because each mutation patched a line *inside* a branch the case never
enters — M4's inside `if [ -n "$also_built" ]`, M10's inside `if [ -n "$to_delete" ]`, which is
empty in exactly the case under test. Re-aimed at the branch conditions, both went red at
once. The prior belongs on the probe (`code-check.md`, "The probe is broken before the world
is"), and a mutation table is itself a probe.

**M9 was the one real finding.** Removing `rfail=1` from the still-served arm left case 21c
green, because the equality arm and the 404 loop both fire there too — so the arm was not
independently pinned. Case 21f isolates it: `--allow-retract` skips the equality arm by design,
and `FAKE_GONE_IDS` makes the item endpoint answer 404, so the search still listing the id is
the only thing wrong. Both arms stay, because they read different surfaces — the search index
and the item endpoint — and nothing guarantees those agree.

## Mutation table, part 2 — `item_retract_s3.sh` and the sync split

| # | guard disabled | case that went red |
|---|---|---|
| R1 | the API-404 refusal | 22 |
| R2 | the bucket `collection.json` `rel: item` refusal | 22c |
| R3 | the still-built refusal | 22d |
| R4 | the prefix's trailing slash (`s3://b/<id>/`, not `s3://b/<id>`) | 22e |
| R5 | the `--yes` requirement | 22b |
| R6 | the JSON sync split (one pass over items + collection) | case 2, 4 assertions |

R4 is the one worth naming: without the trailing slash, `aws s3 rm s3://b/<id> --recursive`
also sweeps every key sharing the prefix — `cccc_ch_ff04_anything/` — on a bucket with no
versioning.

## The two dead guards, before and after

Measured 2026-10-14, both on this branch and reproducible on `main`:

```
$ Rscript scripts/stage_years-check.R                      # the documented default
  skip  every case (ufra has no landcover record for all_ff04)
0 assertions, 0 failed, 1 skipped — the call site was NOT proven

$ AREA=bulk Rscript scripts/stage_years-check.R
13 assertions, 0 failed, 1 skipped
```

`test_pipeline.R` on `WSG=ufra` stops at "no items staged for UFRA" — `01_stage.R:380-382`
skips the one target, because ufra declares `primary_scenario: all_ff04` and holds only
`rasters/ch_ff04/`. True today for 13 of the 23 rostered groups. On `WSG=bulk` it passes
end to end, and independently reproduces #79's figure: `bulk_all_ff04` ff04 = 659.99 km².

Both defaults moved to `bulk`, which `scripts/README.md` already used for its worked
examples, and which is the only annual-span whole-network area — so it drives the
derived-year arms #75 introduced rather than the three-year constants they replaced.

**The `meta.json` fold pin is left in place, skipping permanently, deliberately.** Its own
comment anticipated going stale when floodplains#79 reached ufra; what actually happened is
stronger — floodplains#125 moved ufra to `all_ff04`, so no build produces `ufra_ch_ff04` at
all and the pinned bytes describe an item that cannot be rebuilt. It is not re-taken here,
because what it pins is #61's "this issue changes code, not data" criterion against a
**pre-change** build, and a pin re-taken from today's code would confirm today's code against
itself — verification reading its own output. Re-taking it is a different, newly-named guard,
and belongs with whoever lands ufra's whole-network run.

## Visibility check (public repo), 2026-10-14

`.claude/visibility` is `public`. `stac_dem_bc` and `stac_uav_bc` are PUBLIC, so naming the
`stac-dem-bc` incident is fine. The operations repo that manages the bucket and server is
**PRIVATE**, and `main` already names it in about a dozen tracked places including a full GitHub
link (`CLAUDE.md`) and an issue citation inside an operator-facing error message
(`catalogue_release.sh`) — the two forms the convention names outright.

This branch adds more mentions in the same bare-name style, and **no** new link and **no** new
issue citation (measured: `grep -c "rtj#"` over the branch's added lines is 0). Diverging inside a
single paragraph of a file that names it three lines up would read worse than matching it, and
rewriting a dozen pre-existing references does not belong in #76. Filed as #86 with the
occurrence table, so the wording is settled once and applied in one pass.

## Code-check round 1 — six findings, all real, all fixed

Each reproduced before being acted on.

| # | finding | verdict |
|---|---|---|
| F1 | the **Replacement** recipe told the operator to pass `--allow-retract`, and the prose claimed "neither alone retracts anything" | **both false.** Step 6 is gated on `n_retired > 0` alone, so the literal alone retracts; and the flag waives the containment arm, the group arm, step 5's surplus arm and step 7's equality arm. The documented happy path for the cutover would have deleted 17 public ids with every new membership guard inert |
| F2 | `item_retract_s3.sh`'s byte-count `summary=$(aws s3 ls … \| awk …)` under `set -o pipefail` | **real.** Measured against the real bucket: `aws s3 ls` on an absent prefix prints `Total Objects: 0` **and exits 1**. pipefail propagates it, the assignment fails, `set -e` exits — after the "permanent" banner and before the `<id>.json` delete, with stderr discarded. The re-run case the script is written to tolerate |
| F3 | the stage knob counted every `POST /search`, and a retirement release makes **five**, not three | **real, and it made the positive control vacuous.** `FAKE_LIVE_IDS_FINAL` landed on step 5's compare, which runs *before* the delete, so case 21a modelled a catalogue that had already lost the item and never exercised step 5's containment arm |
| F4 | `RETIRED_ITEMS` entries had no id-shape guard | **real.** curl normalises dot segments, so an entry of `../collection.json` HEADs the bucket's own `collection.json`, reads 200, and is reported "already retired by an earlier run" — a release completing while announcing a retirement it never performed |
| F5 | step 7 compared Python `sorted()` against a shell `sort` as plain strings | **real fragility.** They agree for id-shaped input on this machine; the exposure is a release host with a different `LC_COLLATE`, where it would report "the retirement did not take" *after* the delete |
| F6 | case 21b's "step 6 was never reached" re-grepped `RELEASE INCOMPLETE`; case 20g matched any message containing `NEWS.md` | **real.** Neither carried information about the thing it named |

### Fixes

- **F1:** `--allow-retract` and a non-empty `RETIRED_ITEMS` are now **refused together**, beside the
  `--only` refusal — the flag waives precisely the arms the literal depends on, so the combination
  is the most destructive configuration available here, reached by passing a flag that reads like
  extra caution. The flag is gone from the Replacement recipe, and the false sentence is corrected
  in `scripts/README.md`, `CLAUDE.md` and `NEWS.md`. New case 21g.
- **F2:** `|| summary=…` on the assignment.
- **F3:** the shim counts only the **id-only** search (the three shapes are distinguishable by
  `fields.include`), and the `properties.wsg` / `properties.deprecated` reads take the current
  stage rather than advancing it.
- **F4:** the same `case` guard `$ONLY` and `item_unregister.sh` carry. New case 20i.
- **F5:** `LC_ALL=C sort` for `local_ids`, which fixes every comparison in the script at once —
  including the `comm` calls, which need both sides ordered the same way to mean anything.
- **F6:** 21b asserts the step 6 banner is absent; 20g asserts the specific message.

### The harness grew two capabilities, both because a guard was otherwise unreachable

- `aws s3 ls --summarize` now models the real exit status (1 on an empty prefix, with the Total
  lines still printed). With a blanket `exit 0`, F2's guard could not be tested at all.
- The `-d` payload is captured, which is what lets the stage counter tell the three searches apart.

## Mutation table, part 3 — round 1's fixes

| # | guard disabled | case that went red |
|---|---|---|
| M11 | step 5's containment arm (→ equality) | **21a**, 21c, 21f |
| M12 | the `--allow-retract` + literal refusal | 21g |
| M13 | the `RETIRED_ITEMS` id-shape guard | 20i |
| M14 | step 7's per-id 404 probe | 21f |
| M15 | `item_retract_s3.sh`'s empty-prefix guard | 22e |

**M11 is the one that matters.** It is the reviewer's own mutation, and before the F3 fix it left
case 21a — the positive control — **fully green**, which is what proved the knob was feeding the
wrong stage. After the fix the same mutation reddens 21a. A positive control that cannot fail is
the "fixture that cannot reach the failure mode" mechanism, arriving through a test-harness knob.

**M15 needed the shim fixed first.** It came back STILL GREEN not because the guard is weak but
because the condition was unreachable — the reviewer said so. With the faithful `aws s3 ls`, the
mutant now reproduces the exact symptom: the "permanent" banner prints, nothing is deleted, and
the script exits 1 silently.

## Code-check round 2 — three findings, and the mechanism behind round 1

Round 2 did what the convention asks for from round 3 on: it named the **mechanism** rather than
more instances, and both mechanisms still had reachable members.

**Shape A — two artefacts that must agree, with nothing mechanical joining them.** Round 1's F1
(prose vs code), F3 (the harness stage counter vs the script's call sequence) and F5 (Python
`sorted()` vs shell `sort`) are all this. Each round-1 fix closed its named instance without
walking the class.

**Shape B — a guard scoped to the symptom rather than the property.** F4 guarded the *character
set* of a `RETIRED_ITEMS` entry because the symptom was `../collection.json`; the property wanted
is "this is an item id of this collection".

### The three findings

| # | finding | verdict |
|---|---|---|
| R2-1 | the step-7 recovery text, and four copies of it, say to re-register "from the bucket copy with `item_register.sh`" | **real.** `item_register.sh` does `json.load(open(f))` over its argv — local paths only — so both the `s3://` and `https://` forms die with `FileNotFoundError`. It is the text printed with a half-done retirement in front of the operator, and the stated justification for `item_retract_s3.sh` being separate. Shape A, moved into the *recovery* path |
| R2-2 | `build_wsgs` was still on a bare `sort -u`, feeding a `comm` against Python-sorted `live_wsgs` | **real.** And my own F5 comment claimed pinning `local_ids` "fixes every comparison in this script at once" — the over-claim is what hid it. It is the group arm, the one guard that survives `ALLOW_SKIPPED=1`. Direction measured by the reviewer: fails toward refusal, not pass |
| R2-3 | `RETIRED_ITEMS="collection"` passes every arm and the release completes | **real.** It clears the charset guard, is absent from `local_ids` by construction, `$S3_BASE/collection.json` answers 200 so the witness reports "already retired by an earlier run", the NEWS `grep -qF` matches any entry containing the word, `to_delete` is empty and `$API/items/collection` 404s. F4's exact symptom with no dot segment. Nothing is deleted, so not a data hazard |

### What the enumerations found that the reviewer did not

Because two findings sat inside round 1's fixes, a quiet round could not end this loop — only
walking the classes could. Three enumerations:

**E1, every `sort` whose output is compared.** One member left (R2-2). Fixed, and then closed
**statically** rather than behaviourally: no fixture can reach a collation difference, because the
synthetic group codes are ASCII and collate identically in every locale. Case `20-sorts` greps the
release script instead and refuses any `| sort` that is neither `LC_ALL=C`-pinned nor the one
feeding `xargs` for registration order. Proven by removing the pin: the case goes red.

**E2, every operator-facing message naming a remedy, against whether that remedy is available in
the state that printed it.** The reviewer found one of three. The other two are mine:

- the containment arm said "or re-run with `--allow-retract`" — **refused** when the literal is
  non-empty, which is exactly a retirement release
- the group arm said "or re-run with `--allow-retract` if the group really is leaving" — same,
  and worse, because that flag would waive *this very arm*

Both now branch on `n_retired` and say so. This is the class round 1's F1 belonged to, and it had
three members, not one.

**E3, every guard proving existence where identity is wanted.** Two members: the bucket witness
(R2-3) and the NEWS arm's `grep -qF`, which matched a substring — so an entry naming only
`bulk_all_ff04_v2` satisfied the requirement to record `bulk_all_ff04`. The witness now reads the
body and requires `type == "Feature"` and a matching `id`, which subsumes the charset guard's
whole purpose; the NEWS match is delimited. New cases 20j and 20k.

### Also fixed: a dead condition I found myself, held until round 2 finished

Step 7's equality arm carried `[ -z "$ALLOW_RETRACT" ]`, copied from the step-5 arm. The block is
gated on a non-empty literal and the flag is refused alongside one, so the test could never be
false. A condition that cannot be false reads as a live escape hatch on the one arm the retirement
turns on. Now unconditional, and the comment says why. Not applied mid-review, because round 2 was
reading that file and running the harness.

## Mutation table, part 4 — round 2's fixes

| # | guard disabled | case that went red |
|---|---|---|
| M16 | the bucket witness's identity check (→ existence) | 20j |
| M17 | the NEWS delimited match (→ `grep -qF`) | 20k |
| M18 | `build_wsgs`'s collation pin | **none** — unreachable behaviourally; closed by case `20-sorts` instead, which does go red |

## Code-check round 3 — four findings, one of them data loss, and a third mechanism

Round 3 did **not** converge, correctly: two of its four findings sit inside round 2's fixes, and
one is a member of a class round 2 declared complete at two members.

| # | finding | verdict |
|---|---|---|
| R3-1 | `scripts/item_retract_s3.sh --yes collection` **deletes the published `collection.json`** | **real, and data loss.** All three guards miss: the API 404s `collection`, `$linked` holds item ids only, and the build cross-check catches it *by accident* — and that one is skipped whenever `data/stac` is absent, which is a **release-only machine, the machine this script exists for**. Reproduced by the reviewer in a scratch copy: `s3 rm s3://stac-floodplains-bc/collection.json`, rc 0, `retracted: collection`. The third member of round 2's Shape-B class, which I had called complete at two |
| R3-2 | the round-2 bucket witness conflated "no such Item" with "could not read" | **real.** Measured over five responses — `type: Collection`, curl exit 7, a truncated body and an HTTP-200 S3 `SlowDown` document all produced the identical "never published … check the literal". This file states the opposite rule twice, for `fetch_live_version` and for the licence read-back. It matters because this arm's refusal costs a new commit, a NEWS entry and a tag |
| R3-3 | case `20-sorts` asserted less than its comment claimed | **real, and it is the construct added to close Shape A/B being Shape B itself.** `sort -u <<<"$x"` missed (no pipe); a line holding both a pinned and a bare sort missed (the `grep -v` dropped the whole line) — and that filter was dead anyway, since `| *sort` cannot match `| LC_ALL=C sort` |
| R3-4 | `grep -q` / `grep -m1` / `head -1` downstream of a pipe under `pipefail` | **real, none reachable today.** Threshold measured at 64 KiB; `NEWS.md` is 39,573 B and its top section 29,165 B — 1.6x and 2.2x of margin on a file that only grows. `item_retract_s3.sh`'s link check is the one that **fails toward pass** |

### The third mechanism, and the two members the reviewer did not name

**An early-exiting pipeline consumer under `set -o pipefail`.** `grep -q`, `grep -m` and `head -1`
stop reading at their answer, so the writer's SIGPIPE becomes the pipeline's status and the test
reports the writer's death as its own verdict. Invisible to the harness (payloads are hundreds of
bytes), to a mutation table (there is no guard to disable), and to `bash -n`.

Running the enumeration found **five** members, not three: the two the reviewer did not name are
`catalogue_release.sh`'s `--only` liveness check and its `probe_item` pick, both pre-existing, both
with ~300 B inputs, and both failing toward refusal. Converted anyway — a class is closed by having
no members, and two left behind are what the next reader copies. That is the F5/`build_wsgs` lesson
applied before it cost anything.

Closed by `case 20-pipes`, a static scan of both scripts, because no fixture can reach it. Proven
by appending a piped `grep -q`: the case goes red.

### What else the enumerations turned up

- **R3-2's fix made the two witnesses structurally identical** — the release preflight's and
  `item_retract_s3.sh`'s guard 4 now run the same three-outcome `case`. They are the pair that must
  agree about what the bucket says, and nothing but their shape joins them, which is Shape A's
  definition.
- **`NEWS.md`'s "Six arms refuse in step 0" was already wrong** (round 2 recorded it as
  not-reported). The count is gone rather than corrected: a number in prose that nothing checks is
  the same class, and the list reads fine without one.
- **Case 20c was passing vacuously, and I found that by sending the probe at the shim by hand.**
  The shim answered `200` to every `-w` HEAD, so the "never published" arm was unreachable — and
  the could-not-read message it actually triggered happens to contain the phrase 20c greps for. Two
  defects stacked: a fixture that cannot reach the state, and an assertion loose enough not to
  notice. The shim now answers per key, and 20c asserts the specific message plus a negative that
  it is *not* the could-not-read arm.
- **The harness conflated the fixture root with the build dir.** Both were `$STAC_DIR`, so case
  22a2 could not model a release-only machine: emptying the script's `data/stac` also emptied the
  bucket. Split into `FIXTURE_ROOT` (what the harness serves) and `STAC_DIR` (an input to the
  script under test).

## Mutation table, part 5 — round 3's fixes

| # | guard disabled | case that went red |
|---|---|---|
| M19 | `item_retract_s3.sh` guard 4 (identity) | 22a2 |
| M20 | `item_retract_s3.sh` unread-probe refusal | 22a3 |
| M21 | the witness's read-failure separation | 20L |
| M22 | the witness's 404 arm | 20c |
| M23 | the NEWS delimited match via here-string | 20k |
| — | a piped `grep -q` appended to the release script | `20-pipes` |
| — | three shapes of unpinned `sort` appended | `20-sorts` (all three caught, incl. the two the old pattern missed) |

M20 came back STILL GREEN on its first run, for the same reason M15 did: the arm had no fixture.
Rather than add a knob, the fix routes an unreadable body to the unread-probe arm — which is both
more accurate and what makes the two witnesses identical — and `GARBLED` then reaches it.

## Class D, enumerated here (not by a reviewer) — and made self-policing

Class D is "a fixture or assertion that cannot reach the state under test". It had bitten five
times by the end of round 3 and had never been walked. Walking it mechanically — every
`expect_out` pattern against every message the two scripts emit — found **9 ambiguous patterns of
71**, four of them real:

| pattern | why it was wrong |
|---|---|
| `RETIRE` | case 21a's "the retirement is reported", satisfied by any of **seventeen** messages containing `RETIRED_ITEMS`. The positive control again, the same place round 1's F3 landed |
| `already retired by an earlier run` | case 20d's, and the could-not-read arm's own prose contained the phrase — the identical collision that made case 20c pass vacuously, re-created two arms away |
| `Could not read` | case 20L's, printed by eight other arms, several reachable in a preflight |
| `could not read` | case 22a3's, printed by seven |

Fixed by asserting what only the arm under test prints — `=== 6: RETIRE ===`, `verdict '`,
`did not complete` — and by rewording the one prose collision, as was done for 20c. Three more
(`do not combine`, `permanent`, `full release`) were tightened although not reachable today.

**Then the class was made self-policing**, because it is the only mechanism whose instances live
in the harness itself and so cannot be caught by reviewing the scripts. `case 20-assertions`
matches every `expect_out` pattern against every emitted message and refuses any reachable from
more than one, with a three-entry allowlist that carries a reason per entry. Proven by putting
the loose `RETIRE` pattern back: the case goes red.

That gives each of the four mechanisms a terminating instrument rather than a judgement:

| class | closed by |
|---|---|
| A — two artefacts that must agree | the members walked and fixed; the two bucket witnesses made structurally identical; the unchecked arm count removed rather than corrected |
| B — a guard scoped to the symptom | identity checks on both witnesses; the NEWS match delimited |
| C — early-exiting consumer under `pipefail` | **static** `case 20-pipes` over both scripts |
| D — a fixture or assertion that cannot reach its state | **static** `case 20-assertions` over the harness |

plus `case 20-sorts` for the collation class, which is A's one mechanically-checkable member.

## Code-check round 4 — a new bug outside all four mechanisms, and a fifth mechanism

Round 4's verdict was **"the loop must continue"**, and it was right on both counts.

| # | finding | verdict |
|---|---|---|
| R4-1 | **`--skip-sync` on a full release that ADDS items publishes a `collection.json` linking objects that were never uploaded** | **real bug.** That path's only S3 write is `aws s3 cp collection.json`; no item JSON is sent, nothing refused the combination, and — grep-verified — **no bucket read anywhere touched a per-item key**. It survives a *failed* release too: the `cp` is at step 2+3, the nearest probe at step 5, so `RELEASE INCOMPLETE` printed with the hazardous document already live. This is the exact window the step-3 sync split was added to close, reached by the one path the split does not cover |
| R4-2 | `case 20-assertions`, the class-D terminator added in round 3, matched only lines whose stripped text *starts with* `echo ` | **real.** 155 of 227 emitting lines visible, **72 invisible** — every `\|\| { echo … }` and `*) echo …;;` site, which is where the refusals live. Proven by planting two patterns: one over bare `echo` sites was flagged, one over five `\|\| { echo }` sites was not. So the three-entry allowlist existed because three ambiguities were *visible*, not because the class was walked |
| R4-3 | case 20b's `expect_out "aaaa_st_ff04"` was satisfied by the **generic** orphan listing, not the containment arm | **real, a live open D member.** Proven by deleting the containment message while keeping its `exit 1`: 20a went red, 20b stayed green on both assertions |
| R4-4 | `:141` and `:159` tested `[ -n "$RETIRED_ITEMS" ]` on the raw literal — which the normalisation's own comment forbids | **real.** `RETIRED_ITEMS="   "` refuses `--only` under a message about publishing a smaller collection while `n_retired` is 0. One-directional and safe; a false refusal with the wrong remedy |
| R4-5 | `20-sorts` / `20-pipes` scanned two files; `item_unregister.sh`, which performs the delete, was in neither | **real scope gap.** Zero members there at the time — but a "no members" closure is only as wide as the files read |

### Mechanism E — an invariant established by construction, with no read-back

Distinct from A: A is two artefacts with nothing joining them; **E is an invariant whose entire
enforcement is the order of two statements**, voided silently by any path that omits one.

Its open member was the one R4-1 exploits: "the bucket's `collection.json` never links an absent
object" was enforced by `aws s3 sync` running before `aws s3 cp`, plus `set -e`, and **never read
back**. Fixed in both directions — `--skip-sync` with a non-empty added set is refused, and step 5
now HEADs `$S3_BASE/<id>.json` for **every** id the published collection links. The read-back is
the part that matters: it also catches a sync that died partway in the normal path, which nothing
did before.

Its named sub-shape is worth keeping: **when a class is closed by a hand-written scanner, the
class's boundary becomes the scanner's reach.** `20-sorts` was wrong twice in round 3;
`20-assertions` was wrong on its first outing. Hence a planted-member row for each static case.

### Round 5 fixes, and what widening the scanners then found

All five of round 4's items, plus two more that only the widened scans could see:

- `item_retract_s3.sh:88`'s `sort -u`, invisible until `20-sorts` walked the third file. It feeds
  a `grep -qxF`, so order is irrelevant — **pinned anyway rather than allowlisted**, because an
  exception is a hole and a pinned sort is one word.
- `RELEASE INCOMPLETE` reachable from two emitters, invisible until the extractor saw `printf`
  and non-leading `echo`. Allowlisted with its reason: two spellings of one outcome, and the case
  asserting it also pins `n_delete` and the absence of the step-6 banner.

## Mutation table, part 6 — round 4's fixes, and a row for every static case

| # | guard disabled | case that went red |
|---|---|---|
| M24 | the `--skip-sync` + added-items refusal | 20m |
| M25 | the per-id bucket read-back | 20n |
| M26 | the containment arm's own heading | 20a, **20b** (which stayed green under this before) |
| M27 | the hoisted normalisation (raw-literal test restored) | 20w |
| planted | three unpinned `sort` shapes, incl. the two the old pattern missed | `20-sorts` |
| planted | a piped `grep -q` | `20-pipes` |
| planted | the loose `RETIRE` pattern | `20-assertions` |

**Process note, recorded because it is my error:** I committed `e3769c0` while round 4 was reading
the tree, so for about two minutes it saw a file mid-edit. It handled that correctly — snapshotted
with `cp -r`, reviewed the snapshot, and said so — but the convention is not to edit files a long
review is reading, and I had been holding to that until this round.
