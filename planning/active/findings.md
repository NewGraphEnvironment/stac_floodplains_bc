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
