# Findings — Complete the whole-network cutover in one release at v2.0.0 (#89)

## Measured before the work started

`Rscript scripts/prov_census-measure.R`, 2026-10-15T20:43Z, producer `v0.1.13-3-g760b8d9-dirty`:

```
items on the roster: 23   staged: 23   carrying any provenance: 23
  link_run_uid 18, the other eleven 23
```

Fixture populations it printed: 18 items with all twelve; 5 missing only `link_run_uid`
(`kotl`, `larl`, `sloc`, `dunc`, `mcgr`); 0 with none.

Live API, same evening: exactly the 23 species ids the issue's table names. `drift` 0.20.0
installed, matching every record, so no `ALLOW_DRIFT_SKEW`. AWS credentials present; SSH to
the release host answers.

## Ordering: the deprecation literals must be emptied BEFORE the rebuild

`item_create.py` writes `deprecated: true` into the JSON from `DEPRECATED_ITEMS`, and
`item_validate.py:394` refuses an id "named in EXPECTED_DEPRECATED but absent from the build".
Neither `mcgr_ch_ff04` nor `pine_bt_ff04` exists in a whole-network build, so leaving the
literals set would fail `run_pipeline.sh` at its VALIDATE step — after the full COG pass.

## prov_fields-check.py's numbers are the FIXTURE's, not the catalogue's

`catalogue()` builds 18 full + 3 part + 2 none = 23 items, 21 with provenance, and the
`floor=21` call sites assert against that tree. Changing the part-population to 5 makes the
fixture 25 items / 23 provenanced, so every number derived from it moves too.

## The build found a real defect here: class 0 was dropped from the class table

`run_pipeline.sh` reached VALIDATE and refused:

```
FAILED: 1 layer-style problem(s)
  kisp_all_ff04/floodplain_landcover.gpkg style for 'classified_all_ff04_2020' has no
  category for 1 value(s) the layer holds (No Data) — those features draw with no symbol
```

Traced, not guessed:

- `drift::dft_class_table("io-lulc")` returns **10** classes, code 0 "No Data" among them.
  `data/raw/classes.json` had **9** — `01_stage.R:105` filtered `code != 0`.
- The stated premise for that filter was that the published rasters "never contain 0".
  Measured on this build: `kisp_all_ff04/classified_2020.tif` holds **58,540 cells of 0**
  among 3,555,686 valid ones (1.65%). Exactly one raster in the catalogue, and exactly one
  vector feature — scanned all 108 classified rasters and all 23 landcover bundles.
- **The cause is the cutover itself.** The producer's `kisp/rasters/ch_ff04/classified_2020.tif`
  — same group, same year, species-accessible extent — holds **no** zeros. The whole network
  reaches ground the accessible network did not, and io-lulc's 2020 composite has a gap there.
  So the premise was true of every build before this one.
- Not upstream: the producer's raster is faithful to io-lulc, which defines 0 as No Data. The
  drop was ours.

The second half of the dropped premise does not survive either. "A transition cross product
of 100 rows of which 19 are unreachable" is the objection that already applied to the 81, of
which KISP reaches 45; the transition RAT documents drift's *encoding*, not an item's data,
and `item_validate.py` checks that every code present in a raster has a row, not the converse.

**Fix:** keep code 0. `classes.json` 10 classes, classified RAT 10 rows, transition RAT 100,
`classification:classes` 10, `EXPECTED_RAT_ROWS` 10/100, and the three committed `styles/*.qml`
regenerated (classified 10 categories, transition 90). Full COG rebuild, because the RAT is
embedded by the `CreateCopy` in step 03.

## Errors Encountered

| Error | Resolution |
|-------|------------|

## Plan review (Plan agent, 2026-10-15) — corrections that changed the plan

1. **`catalogue_release-check.sh` cannot run on the release commit.** It copies the real
   `scripts/` into a throwaway repo and runs the real `catalogue_release.sh` against a
   two-item fixture catalogue (`LIVE="aaaa_ch_ff04 bbbb_ch_ff04"`). Nothing rewrites the
   literal at setup, so 23 real ids in `RETIRED_ITEMS` make every `--only` case refuse at
   `catalogue_release.sh:163`, every `--allow-retract` case at `:190`, and every full-release
   case fail the "never published" arm at `:540` (the curl shim 404s a key with no fixture
   file). The positive control included. **So: run it BEFORE setting `RETIRED_ITEMS`**, not
   as "one known failure". Verified by reading the shims; not executed.
2. **`## Unreleased` must be renamed, not have a heading inserted above it.**
   `catalogue_release.sh:679` reads the FIRST `## ` heading from the tagged commit and refuses
   anything that is not `## v<VERSION>`; its own comment says an `## Unreleased` above the
   entry "is exactly the state this gate exists to refuse". Verified in the code.
3. **`item_create.py` does not refuse a stale `DEPRECATED_ITEMS` id** — `:549` is a membership
   test and the branch is simply dead. The refusal is `item_validate.py:394` alone. Phase 1's
   ordering still holds, for one reason rather than two.
4. **Two `-check` scripts default to an item the rebuild stops producing** —
   `gpkg_determinism-check.R` and `style_determinism-check.py` both `ITEM=sloc_bt_ff04`, which
   stops the script rather than checking anything. Both comments predicted this.
5. **The published collection description** (`item_create.py:677-679`) said "one per modelled
   species/scenario" — user-facing text on the API, not a comment.
6. **`git push origin v2.0.0` was missing from the plan**, and goes after `RELEASE COMPLETE`.
7. `README.Rmd:142`'s "the collection mixes flood factors" is no longer true — every item is
   `ff04`.
8. A **re-run** of the release after a step-7 failure is not cheap: the `not_live` witness
   loop (`:494-556`) does a HEAD plus a full body fetch per id, and `bulk_all_ff04.json` is
   17.8 MB.

## prov_fields-check.py — the numbers are the FIXTURE's

`catalogue()` builds 18 full + 3 part + 2 none = 23 items, 21 provenanced, and the `floor=21`
call sites assert against that tree, not against the catalogue. Moving the part-population to
5 makes it 25 seen / 23 traced, so `(traced, seen)`, `per_section`, every `floor=` and three
expected message strings move with it. The all-absent population stays whatever the
measurement says: the `NGE_PROVENANCE_NULL` and conditional-extension arms live only there.

## Issue context

**If we do it:** the catalogue carries one floodplain model per watershed group, published region by region, ending at `v2.0.0` where every published area carries corrected geometry.
**If we never do:** every converted group serves two floodplains built on different networks and different DEM grids, with nothing in the items saying which is current.

The mechanism landed in #76 / PR #88. This issue holds the **path to finishing**, so it can be
picked up cold.

## Decided

- **ONE release, at `v2.0.0`** (airvine, 2026-10-15, after the Peace and Columbia runs landed).
  Every rostered group is modelled, so a staged cutover would mean deliberately holding back
  groups that are ready — and once all 23 convert, every published area carries corrected
  geometry, which is exactly what `NEWS.md` reserves `v2.0.0` for. It retires all 23 live items
  and adds all 23 whole-network ones in one upsert. **Supersedes the two bullets below and the
  "two releases, not three" revision further down**, both of which were hedges against Peace and
  Columbia not being ready; they are kept because the reasoning is still the reason the mechanism
  is built the way it is.
- ~~**Three releases, one per region**~~ (airvine, 2026-10-15; superseded above). Same total work,
  and the first one tells us whether the retirement behaves on real data with only part of the
  catalogue in flight.
- ~~**`v2.0.0` is the last of the three**, not the first~~ (superseded above). The reservation in
  `NEWS.md` is for "every published area carries corrected geometry", which is true only once
  Columbia converts — it now converts in the same release as everything else.
- **No S3 versioning for now** (airvine, 2026-10-15). Nobody depends on the collection yet.
  Measured: versioning would cost ~$0.19/month for all 246 BC watershed groups and **$0 until the
  first overwrite**, so this is not a cost decision. Revisit when either (a) someone outside
  depends on the collection, or (b) a release publishes something that cannot be re-run.
- **DUNC is not a gate for PUBLISHING — but it stops the BUILD, so release 1 cannot be cut
  while it is rostered.** Corrected 2026-10-15 (#82), from the record rather than from this
  issue: `data/dunc/provenance.json` carries `inputs.link.version: 0.50.0` with `link_log: null`,
  so `link_version` stages with a value and `link_sha` stages null. Those two publish as ONE
  `processing:software` entry, and `item_create.py:506-521` **raises** on a half-present entry
  ("software entry is half-present") rather than writing `+<sha>`. DUNC stages — it has config in
  `columbia.yml`, both bundles and its rasters (three classified plus the transition) — so `run_pipeline.sh` reaches it and
  **aborts**, whichever region the release is for. So either floodplains#133 lands first, or DUNC
  comes out of `columbia.yml`'s roster until it does. The original decision stands for the
  catalogue (DUNC has never been published and joins whenever #133 is fixed); it was wrong about
  the build.
  **Cleared the same day, 18:38Z:** the Columbia run wrote DUNC a `network/all2/link_log`
  carrying `link_sha 8215d2d0…`, so the pair is even and that arm no longer refuses (not the same
  as a rebuild having been run — nothing here ran one).
  floodplains#133 is still open as written, and the half-present state recurs whenever upstream
  cannot resolve a sha — `prov_fields-check.py` now refuses a `PROV_CENSUS` whose paired fields
  disagree, so it cannot be pasted as an expectation again.

## Measured 2026-10-15T20:08Z, no upstream run in flight (#82's script)

```
items on the roster: 23   staged: 23   carrying any provenance: 23
  link_run_uid 18, the other eleven 23
```

Uniform across all 23 areas: `flooded 0.7.0`, `drift 0.20.0` (installed drift is 0.20.0, so no
`ALLOW_DRIFT_SKEW`). Year sets are **still mixed** — 19 areas three-year, 4 annual (`necr`,
`lnth`, `bulk`, `kotl`). Live catalogue: 23 items, every one species-based.

**What that implies for each literal.** Take the census and the floor from the build's own output,
never from this block (see **Do not**); the rest are structural and settled:

| literal | now | this release |
|---|---|---|
| `RETIRED_ITEMS` | `""` | all 23 live ids (the table below) |
| `PROVENANCE_FLOOR` | 21 | from the build — expect 23 |
| `PROV_CENSUS` | `link_run_uid` 18, rest 21 | from the build — expect `link_run_uid` 18, the other eleven 23 |
| `prov_fields-check.py`'s asserted census | 18 / 21 / 23 | the same build's numbers |
| `DEPRECATED_ITEMS`, `EXPECTED_DEPRECATED` | `{mcgr_ch_ff04, pine_bt_ff04}` | **empty** — not optional |
| `ALLOWED_YEAR_SETS` | both tuples | **unchanged**, both are still occupied |

The deprecation literals are not a tidy-up: `flooded` is 0.7.0 on every area, and the guard runs
both directions — a marked item that has been rebuilt is **refused**, naming the literal to delete
it from. Those two ids also no longer exist in the build at all, so a full release's absent-id arm
fires too.

**One re-take is a judgement, not a paste.** `prov_fields-check.py`'s fixture populations become
18 with all twelve / 5 missing only `link_run_uid` / **0 with none** — and the all-absent
population must stay anyway, because the `NGE_PROVENANCE_NULL` and conditional-extension arms live
only there. The comment beside `catalogue()` says so at the point of re-taking.

**Nothing has run a build.** `prov_census-measure.R` declines the arms that need `sf`/GDAL, so the
above is the roster and the records, not a build: the layer-key refusals over 23 whole-network
groups, the style and family census, the COGs and the checksums are all unexercised. Expect
`01_stage.R` to **report** unclaimed layers on groups that still hold retired species outputs —
floodplains#131 has not pruned them, and that is reported, not refused.

## Verified state, 2026-10-15

floodplains at `760b8d9` ("Record the Fraser whole-network run; reconciled region configs").

| region | groups | whole-network outputs | note |
|---|---|---|---|
| Skeena | 3 | **3/3 ready** | `bulk`, `morr`, `kisp` |
| Fraser | 13 | **13/13 ready** | done this run |
| Peace | 3 | **3/3 ready** | `pcea`, `pars`, `pine` — the latter two converted later the same day |
| Columbia | 4 | **4/4 ready** | `kotl`/`larl`/`sloc` converted and `dunc` unblocked by the run of 2026-10-15T18:38Z |

**Re-measured 2026-10-15T18:42Z (#82's script, one command): 23 rostered / 23 staged / floor 23,
no skips, `link_run_uid` 18 and the other eleven 23.** The table above is kept as the state that
was verified when the plan was written; take the current one from
`Rscript scripts/prov_census-measure.R`, which is the only copy of these numbers that cannot go
stale. Every blocker the table names had cleared on disk within 36 hours of it being written,
which is the argument for not carrying counts in an issue body at all.

**What is no longer a blocker, each checked rather than cited:**

- floodplains#76 (MCGR/PINE) — its own body retracts the block for whole mode: the measurements are
  on the species *accessible* network, which whole mode does not read. MCGR 2,833 km / PINE
  5,768 km in `fresh.streams`, equal to bcfp. It closes when the Peace run produces PINE.
- floodplains#123 (GeoParquet) — additive. The item already ships `all_ff04_by_blue_line_key`
  inside `floodplain.gpkg`.
- The `ALLOW_DRIFT_SKEW` override — no longer needed for freshly-run groups. A BULK smoke test on
  2026-10-15 did not trip it; the whole-network runs are on drift 0.20.0, which is installed.
- floodplains#131 (prune species outputs upstream) — after the retirement, by design.

**floodplains#133 (DUNC), diagnosed precisely — and resolved on disk 2026-10-15T18:38Z, when the Columbia run wrote the missing `link_log` (`link_sha 8215d2d0…`); the diagnosis below is kept because the issue is still open:** `data/dunc/provenance.json` has
`network/all2/inputs/link` with `sha: null, sha_source: "unresolved_version_mismatch"` and **no
`network/all2/link_log` section at all**. BULK has the identical `inputs/link` and publishes fine
because it *does* carry `link_log/link_sha`. So the gap is a missing `fresh.log` row for DUNC on
link's side, not a floodplains defect.

## Peace is already running — the decision below was overtaken

**Observed 2026-10-15 09:04**, `scripts/floodplain_lcc/logs/20261015_run_region_peace.log`
(untracked, in flight): all three Peace configs reconciled (`PINE`, `PCEA`, `PARS` area.yml
updated, 6 `all` rows appended to each `flood_scenarios.csv`), and PCEA and PARS are running
steps 1–3. `pars` and `pine` still had only `bt_ff04` rasters at that moment, so the run had
not finished.

So **option (b) was taken**: Peace runs rather than having `pars`/`pine` reverted to `bt_ff04`.
The consequence for sequencing — confirm the run finished before acting on it:

- **Release 1 covers Skeena + Fraser + Peace** and retires **20** species items: the 13 Fraser
  `ch_*`, `bulk_co_ff04`, `kisp_ch_ff04`, `morr_co_ff04`, `morr_ch_ff06`, plus `pars_bt_ff04`,
  `pcea_bt_ff04`, `pine_bt_ff04`.
- `pine_bt_ff04` therefore retires in **release 1**, not release 2, so `DEPRECATED_ITEMS` and
  `EXPECTED_DEPRECATED` go **empty in release 1** — both marked items leave at once.
- ~~That leaves **two** releases, not three: release 1 above, then **Columbia** as `v2.0.0`.~~ Superseded 2026-10-15 20:08Z: Columbia finished the same evening, so it is one release (see **Decided**).
- floodplains#76 closes with release 1, since the Peace run produces PINE.

Kept for the record because the original three-release decision (airvine, 2026-10-15) was made
when Fraser looked releasable alone; it was Peace's half-converted config that made it two.

## Each release, same shape

1. **Upstream:** confirm the region's groups against floodplains#125's per-region acceptance.
2. **Rebuild here:** `bash scripts/run_pipeline.sh`. Expect no `PARTIAL_STAGE`; if there is one,
   a rostered group is config-converted ahead of its run — see the decision above.
3. **In the one commit that gets tagged** (the clean-tree and exact-tag gates leave no room after):
   - `RETIRED_ITEMS` in `scripts/catalogue_release.sh` ← exactly the live ids this release replaces.
   - The same ids named in the `NEWS.md` entry — the release refuses if they disagree.
   - All three provenance literals come from **one command**, `Rscript
     scripts/prov_census-measure.R` (#82): it walks the roster and drives this repo's own
     reader, needs `$FLOODPLAINS_DATA` but no build, and prints the floor, the census and the
     fixture populations paste-ready in one block, beside the producer HEAD it measured. It is a
     **measurement, not a gate** — nothing reads its output automatically. Run it on the tree the
     release is cut from, never carry numbers from here:
     - `PROVENANCE_FLOOR` in `scripts/catalogue_release.sh`
     - `PROV_CENSUS` in `scripts/item_validate.py`
     - the two sets of numbers in `prov_fields-check.py`: the census it asserts
       (`link_run_uid` 18 / the rest 21 / 23 seen, at `:207` and the `floor=21` call sites) **and**
       its fixture populations (18 whole / 3 missing `link_run_uid` / 2 with none, at `:195`).
       The script prints both shapes; the all-absent population stays even when the catalogue has
       none, because two arms live only there

     It is the **pre-flight, not the authority**: step 2 rebuilds anyway, and
     `item_validate.py` prints the same twelve counts from the published items as its `census:`
     line, in the same format. That line is what the literals are set from; this script saves the
     round trip and the two agreeing is worth more than either alone. Where they differ the build
     is right, and the difference is the finding — the one way they differ by construction is a
     field pair sharing a `processing:software` entry, which `prov_fields-check.py` now refuses
     over the pasted census.

     Its refusals are the point: no census at all, non-zero, if any record failed to read or if
     nothing staged. A skipped target prints a banner and still counts — but a build with a skip
     drops `PARTIAL_STAGE`, so step 2 above is still the gate on that.
   - `DEPRECATED_ITEMS` / `EXPECTED_DEPRECATED` ← drop any id this release retires. `mcgr_ch_ff04`
     goes in release 1; `pine_bt_ff04` in the Peace release; the literal ends **empty**, because
     nothing will be below `MIN_FLOODED_VERSION` and the guard's both-directions arm is satisfied
     by the empty set.
4. **Tag, then release:** `bash scripts/catalogue_release.sh` — **no `--allow-retract`**; it is
   refused alongside a non-empty literal, because it waives the arms the literal depends on.
5. **Then the assets:** `scripts/item_retract_s3.sh --yes <retired-id>...` — only after
   `RELEASE COMPLETE`, and never before.
6. **Then the README** (`params$update_query`), which must come after the retirement: the coverage
   table refuses while a group carries two items disagreeing on `floodplain_ff04_km2` (#79).

## Expected retirements

| release | version | converts | retires |
|---|---|---|---|
| 1 (the only one) | **`v2.0.0`** | all four regions — 23 groups | **all 23 live items**: `bowr_ch_ff04`, `bulk_co_ff04`, `fran_ch_ff04`, `kisp_ch_ff04`, `kotl_bt_ff04`, `larl_bt_ff04`, `lchl_ch_ff04`, `lnth_ch_ff04`, `lsal_ch_ff04`, `mcgr_ch_ff04`, `mork_ch_ff04`, `morr_ch_ff06`, `morr_co_ff04`, `necr_ch_ff04`, `pars_bt_ff04`, `pcea_bt_ff04`, `pine_bt_ff04`, `sloc_bt_ff04`, `tabr_ch_ff04`, `thom_ch_ff04`, `ufra_ch_ff04`, `unth_ch_ff04`, `will_ch_ff04` |

Counts are the shape, not the authority — take the ids from what the build reports as orphans. MORR is the two-for-one case the `RETIRED_ITEMS` mechanism was built for: two live items, one built (`morr_all_ff04`).

## Do not

- Carry `PROVENANCE_FLOOR` or `PROV_CENSUS` numbers from this issue. They are re-taken on the
  build each release is cut from; an expectation that comes from the data cannot contradict it.
- Pass `--allow-retract` with a non-empty `RETIRED_ITEMS`. Refused, and for a reason: the flag
  waives containment, group-survival and served-equals-build.
- Run `collection_register.sh` by hand. A rebuilt collection carries no version and would
  un-version the API.
- Run `item_retract_s3.sh` before `RELEASE COMPLETE`. Until it runs, the pgstac delete is
  reversible from the bucket copy.

## Relates

#76 (the mechanism, PR #88), #79 (closed by construction), #86, #87,
floodplains#125, floodplains#133, floodplains#76, floodplains#131.










