# Code-check round 2 — #89 whole-network cutover (v2.0.0)

Reviewed 2026-10-15. Scope: the full branch diff, round 1's fixes included, plus a
repo-wide (not diff-scoped) sweep for claims the cutover falsifies.

Everything below was **measured against the local build and the live API**, not read.
What I ran, all read-only, tree left clean (`git status` empty, no stray `.aux.xml`):

| probe | result |
|---|---|
| `item_validate.py --base data/stac --expect 23 --expect-provenance 23` | **exit 0** — 23 items, floor 23, census matches `PROV_CENSUS`, RAT 10/100, styles, licence, deprecation all pass |
| `prov_fields-check.py` | 49 assertions, 0 failed |
| `year_sets-check.py` | 16 assertions, 0 failed |
| `style_drift-check.py` / `attribution_drift-check.py` | pass (3 styles byte-identical, 10 classes) |
| `gpkg_determinism-check.R` / `style_determinism-check.py` with the new `sloc_all_ff04` default | both PASS |
| live API item set | exactly the 23 ids in `RETIRED_ITEMS`; 22 live wsgs, build 23, none lost |
| per-field census from the build | `link_run_uid` 18 (dunc, kotl, larl, mcgr, sloc), other eleven 23 — matches the literal |
| all 23 NEWS-listed ids vs the v2.0.0 NEWS section, with the script's own delimited grep | 23/23 named |
| QML counts | classified 10 categories; transition 91 (9 on, 82 off) — matches `EXPECTED_STYLE_CATEGORIES` |
| class-0 evidence | `kisp .../classified_2020.tif` 58,540 zeros of 3,555,686 valid; `ch_ff04` same year 0 — **exact** |
| every classified COG in the build scanned for value 0 | **1 file of 100** (kisp 2020 only) |
| every transition COG scanned for a 0-component code | **0 of 23** — so class 0 never reaches an endpoint year, the transition vector carries no `No Data` row, and loss/gain/net are untouched |
| API max page size | `limit: 1000` honoured (1000 features returned on a large collection), so `fetch_live_ids` reading 46 items at step 5 does not truncate |
| checksum probe budget | `probe_item` is `bowr_all_ff04`, largest asset 18.6 MB — well inside `--max-time 300` |

**The substance of the change is sound.** Keeping io-lulc code 0 is correct and minimal
(`src*1000+dst` is an absolute encoding, so the extra RAT rows add nothing and shift
nothing), the literals are exact against the build, and the retirement set is exactly the
live set.

---

## Findings

### 1. **[bug]** `CLAUDE.md:348` — round 1's arm count was fixed in one copy and left wrong in the other

Round 1 found "the emptied-literal comment counted vacuous arms wrongly" and the fix
*named* them in `item_validate.py:262-268`, correctly:

> Vacuous over an empty set: `(EXPECTED_DEPRECATED & seen) - marked` and
> `EXPECTED_DEPRECATED - seen` … Still live: a `deprecated` value that is neither absent
> nor True, a half-applied version extension, a marked item that has been rebuilt, a
> marker on an item NOT named here, and an unmarked item whose `flooded` entry is below
> the floor or unreadable.

That is 7 arms, 2 vacuous, **5 live** — and it matches `check_deprecated` exactly
(lines 353, 356, 373-374, 403, 405 plus the `elif not _corrected(fv)` at 381).

`CLAUDE.md`, written in the same commit, says:

> **Two of its five arms are vacuous over an empty literal and the two that matter are
> not**: a marker on an item the literal does not name is refused, and so is an unmarked
> item whose `flooded` entry is below the floor or unreadable

Wrong under either reading: there are **seven** arms, not five, and **five** survive an
empty literal, not two. If "five" was meant as the live set then none of them is vacuous.
Either way the public `CLAUDE.md` understates the remaining coverage by three arms and
contradicts the authoritative copy added beside it — the "one fact derived twice" /
"a fix lands in one of two callers" shape, and exactly the class round 1 opened.

It matters in the direction that invites deletion: a reader told only two arms are left
has no reason to keep the non-True-value arm, the half-applied-extension arm or the
marked-but-rebuilt arm, which are the three the diff drops from the sentence.

Fix: make the `CLAUDE.md` sentence say what `item_validate.py` says — seven arms, two
vacuous (`(EXPECTED_DEPRECATED & seen) - marked` and `EXPECTED_DEPRECATED - seen`), five
live.

### 2. **[fragile]** `_by_blue_line_key` "on 18 of 23 groups" is now 23 of 23, in three places — one of them the table this diff edited

Measured on the v2.0.0 build: **every one of the 23 staged `floodplain.gpkg` files**
carries `all_ff04_by_blue_line_key` (`bowr` holds `all_ff02`, `all_ff04`,
`all_ff04_by_blue_line_key`, `all_ff06`).

- `scripts/README.md:439` — the `styles/floodplain.qml` row, **in the same two-row table
  the diff rewrote** (it changed the two rows below it from 9/72 to 10/90 and left this one)
- `scripts/01_stage.R:553`
- `scripts/style_qml-write.py:22`

The `_by_gnis_name` half of `01_stage.R:553` is still correct (MORR upstream still carries
`co_ff04_by_gnis_name`); only the count is stale.

### 3. **[fragile]** `CLAUDE.md:151` — the #80 bundle-size measurement is stale by a factor of ~1.6 and carries no date

> Measured: 827 -> 643 MB over the 23 rostered groups, MORR -70%.

Re-measured on the build this release publishes:

```
whole-file copy equivalent : 1602.6 MB
selected (staged, 2 bundles):1035.3 MB
MORR                        : 110.9 -> 34.0 MB (-69%)
```

Present tense, no time qualifier, and it sits three lines below a sentence this diff
*did* re-measure for v2.0.0 ("22 of the 23 groups", which I verified: 22 upstream groups
carry a non-`all` key, only `dunc` is clean). The saving is 567 MB, not 184 MB.

`scripts/README.md:61-63` carries the same 643 / 184 / 827 triple. That one is
date-qualified ("measured 2026-10-14"), but its own next sentence says the total "is
re-taken at a full build" — which this is.

### 4. **[fragile]** Comments and a module docstring that this release makes false

Each is prose only — no behaviour — but each describes the state the cutover ends, and
three of the five are in files this diff already edits.

- `scripts/item_create.py:3-5` (module docstring, file edited by this diff) — "`morr_co_ff04`
  + `morr_ch_ff06` — both still live". They are the two ids `RETIRED_ITEMS` deletes.
- `scripts/01_stage.R:422-424` (file edited by this diff) — "only mcgr_ch_ff04 and
  pine_bt_ff04 are still in it [the forward-only state], and both already publish
  `deprecated: true`". False three ways: measured, **0 of 23** items are in the
  forward-only state (floor 23 = traced 23), nothing is marked, and neither id exists in
  any build.
- `scripts/readme_functions.R:277` (file edited by this diff) — "`deprecated` is absent on
  21 of 23 items". Now 23 of 23.
- `scripts/catalogue_release.sh:834` (file edited by this diff) — "The release that
  completes floodplains#125 adds 17 at once, which is the largest exposure this bucket has
  had, so the window is closed now rather than discovered then." Future tense about *this*
  release, and the number is 23.
- `scripts/catalogue_release.sh:12` — "the live 22-group collection" becomes 23 groups.
- `scripts/test_pipeline.R:528` — "not over the 81-row scheme" (now 100).
- `scripts/02_raster_tag.py:216` — "a 2-row sidecar beside a 9-row embedded table" (now 10).

The last two are outside the diff's paths, which is the stac_floodplains_bc#82 lesson the
repo wrote itself: a `git diff`-scoped stale-quantity sweep cannot see them.

### 5. **[fragile]** `scripts/catalogue_release.sh:1195-1211` — the new `|| { … }` is correct, but it still skips step 7, and the success line over-reports on a re-run

I traced the recovery advice through every state the block can be reached in and it holds:

- **Partial psql failure** (the case it was written for): no sync passes `--delete`, the
  bucket keeps every retired item document and `collection.json` still has the old copies,
  `item_retract_s3.sh` has not run — recoverable, correct.
- **Re-run after a partial delete**: I walked it. `not_live` → HEAD 200 on
  `$S3_BASE/$id.json` → body read → `MATCH` → `already_retired`, not the
  "never published" refusal (lines 500-556). `orphans - retired_ids` is empty, the
  group-survival arm passes, step 5's `surplus` is empty, step 6 deletes the remainder,
  step 7 requires equality and every retired id 404s. The tag/clean-tree/NEWS gates are
  all still satisfiable. So "it is idempotent" is true.
- **ssh unreachable / `item_unregister.sh` refusing before any delete**: "some of these may
  already be gone" is hedged and still correct.
- `set -o pipefail` is irrelevant here (no pipe), the unquoted `$to_delete` is safe (ids
  are charset-guarded at line 116 and `LC_ALL=C sort -u`-ed at 107), `cd "$REPO"` at 206
  makes the relative script path resolve, and `bash -n` is clean.

Two things the fix did not close, both small:

- Its own comment calls step 7 "the ONLY evidence the delete happened", and the fix still
  exits before step 7 rather than running it. The operator is handed all 23 ids with
  "some of these may already be gone" where one `fetch_live_ids` would say which. Not
  wrong, just the least informative honest answer, on the one half-finished state.
- Line 1264: `echo "retired $n_retired item(s); …"` prints the size of the **literal**,
  not the size of `$to_delete`. On the first run they are both 23, so this release is
  fine; on the re-run the recovery text recommends it would claim "retired 23" having
  deleted however many were left. That is precisely the defect the comment eight lines
  above guards against for `item_unregister.sh`'s own log line ("a log line that says
  something untrue … would make a count of deletes stop meaning anything"), one statement
  over.

---

## Checked and clean (so a later round need not redo it)

- **Class 0 cannot reach the published figures.** Only `kisp/classified_2020.tif` holds it
  (1 of 100 classified COGs), no transition raster holds a 0-component code, and no
  `transition_vector.gpkg` row has a `No Data` from/to class — so `gross_loss_ha` /
  `gross_gain_ha` / `net_ha`, which `01_stage.R:203-205` derives from
  `from_class`/`to_class` strings, are unaffected.
- **`EXPECTED_RAT_ROWS {10, 100}` and `EXPECTED_STYLE_CATEGORIES {10, 91}`** are right:
  `transition_rat` is `src*1000+dst` over 10 codes, and the committed QMLs hold 10 and 91
  categories. `check_layer_styles`'s "81 of 90 ship off by design" is also right — 90
  pairs, 9 `Trees -> *` on, plus the catch-all off (82 render="false" in the file).
- **`PROVENANCE_FLOOR=23`, `PROV_CENSUS`, and the `prov_fields-check.py` fixture (18/5/2,
  25 items, 23 traced)** all agree with the build, and the five partial items are exactly
  the five the comment names.
- **The retirement literal is the live set exactly** (23/23), 22 live groups all covered by
  the build, DUNC added.
- **`--only` and `--allow-retract` are each refused against a non-empty literal** (lines
  169, 196), above `cd "$REPO"`, before anything is read.
- **Step 5's deprecation read-back cannot false-fail** while the 23 old marked items are
  still live: `served &= built_ids` filters them out, and `built_marked` is empty.
- **README.Rmd's `dep` chunk is guarded** by `if (length(d) > 0)`, so the empty literal
  does not hit the `paste0(character(0), …)` phantom-row trap.
- **`SPECIES` carries `all = "whole network"`**, so no empty cell in the committed table.
