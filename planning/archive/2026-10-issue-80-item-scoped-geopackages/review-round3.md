# Code-check round 3 — #80 branch diff (`git diff f8003ef...HEAD`)

Reviewer: code-review subagent, 2026-10-14. Round 3's brief was to **close the enumeration**
rather than run a fourth search. Every candidate set below was derived by walking the current
working tree, not by reading round 2's table and agreeing with it. Every claim was reproduced
locally (R probes against `../floodplains/data`, `sqlite3` over all 24 upstream area dirs,
byte comparisons against the staged `morr_all_ff04` tree) before it was written.

Independently re-measured first, so the verdicts rest on my own numbers:

- 23 rostered groups across the four `config/regions/*.yml`; `watershed_groups: [BULK, MORR, KISP]`
  in `skeena.yml:29` with **NEEXDZII explicitly excluded**; no live `targets:` block in `bulk`,
  `kisp` or `morr` `area.yml` (all three `species: all`, `primary_scenario: all_ff04`).
- The `wsg` column over every layer of both bundles in all 24 upstream areas: 23 distinct
  values, **all uppercase**, no exceptions.
- The staged working tree is a clean `WSG_ONLY=morr` partial stage with `PARTIAL_STAGE` present;
  `meta.json` years `2017,2020,2023` against three staged `classified_*` layers — **round 2's
  claim 4 (round 1's planted mutation still in `data/`) is cleared**.
- `floodplain.gpkg` 4 layers, `floodplain_landcover.gpkg` 6 (2 of them `attributes`),
  `transition_vector.gpkg` 1 — the 13 -> 4 / 22 -> 6 selection the diff claims.
- `sort(unique(x), method = "radix")` is C-locale here: `B_ff02 Classified_x a_ff04 b_ff06 …`
  against the default's `a_ff04 B_ff02 b_ff06 Classified_x …` under `LC_COLLATE=en_US.UTF-8`.
- Both handler nestings capture both conditions (`warn=W1 err=E1` either way) — round 2's
  finding-5 correction is right.
- Areas and metrics are byte-equal read from upstream and read from the staged copy, on the
  hardest group: MORR `all_ff02/04/06` = 462.44 / 479.32 / 493.96 km² both ways and in
  `meta.json`; loss/gain 659.5 / 780.3 ha both ways. So #80's "nothing a consumer reads changes
  value" holds on a foreign-layer group, not only on `ufra_ch_ff04` where the digest pin lives.
- `gpkg_extract_layer` of `transition_all_ff04_2017_2023` from **upstream** and from the
  **staged** landcover bundle: md5 `10ea7c71017eeef3403ef8a05bae9655`, 2,408,448 B, identical
  both ways. So `transition_vector.gpkg`'s checksum does **not** move under #80, and NEWS's
  "both assets" is exactly right rather than an undercount.

---

## 1. Enumeration completeness

### M1 — every statement that executes at group scope in `scripts/01_stage.R`

Walked `for (wsg in wsgs)` (`:205`) to the target loop (`:322`), then the post-target-loop block
inside the group loop (`:715-739`), then script scope after the group loop (`:742-797`). Column 4
asks the brief's question: can it abort, mis-report, or mis-attribute when a target or group is
skipped?

| line | statement | reachable failure | verdict |
|---|---|---|---|
| `:206` | `area_yml <- file.path(…)` | none | — |
| `:207-211` | no `area.yml` -> message + `skipped` + `next` | none | **Below** |
| `:212` | `area <- yaml::read_yaml(area_yml)` | **aborts the roster** on a malformed `area.yml`, upstream of `ALLOW_SKIPPED` | Above, **pre-existing** — byte-identical position in `f8003ef`, verified by dumping the base file. Out of this diff's scope; the only member of the set carrying no recorded reasoning for its disposition. |
| `:223-227` | `targets <- area[["targets"]]` + fallback | none (`[[`, not `$`) | **Below** |
| `:229` | `src_wsg <- file.path(…)` | none | — |
| `:233` | `wsg_prov <- fp_prov_read(src_wsg)` | **aborts the roster** on four arms (unreadable JSON, `schema_version` skew, unknown top-level key, declared-area mismatch), upstream of `ALLOW_SKIPPED` | Above, **pre-existing** (same position in `f8003ef`), and the disposition is **argued in place**: `fp_provenance.R:28-31` — "01_stage.R has no per-area tryCatch, so the whole stage stops until that area is re-run. Intended: the alternative is a skip that publishes nulls." Not a finding. |
| `:242-243` | `gpkg_src <- c(floodplain =, landcover =)` | none | — |
| `:250-256` | missing bundle -> group SKIP | none | **Below** (round 1 fix) |
| `:265-275` | both `gpkg_layer_keys()` reads inside `tryCatch(error=)` -> group SKIP | none; `is.character()` separates a message from a data.frame correctly, and `gpkg_src[unreadable]` indexes a named length-2 vector | **Below** (round 2 fix) |
| `:276-277` | `keys_fp` / `keys_lc` | none | — |
| `:297-315` | `nokey`/`multi` refusal, then foreign-`wsg` refusal, per file | aborts the roster **by design** | Deliberate — the brief's accepted split ("a bundle that cannot be READ is a group skip while bad KEYS refuse"). |
| `:319-320` | `claimed_fp` / `claimed_lc` reset | none — reset **after** every `next`, so no stale carry | **Below** |
| `:728-739` | the per-group unclaimed census | mis-attribution was round 1's 2b; `claimed_*` now accumulates at `:374-377`, **above** the raster skip at `:379`, so a skipped target still claims its layers | **Below** |
| `:742-778` | the six end-of-run counters | every `… of length(staged)` counter (`traced :706`, `year_untraced :414`, `drift_untraced :686`, `family_unknown :542`) is appended **below** the raster skip, so none can count an unstaged item against a staged denominator | **Below** |
| `:786-797` | the `PARTIAL_STAGE` / `ALLOW_SKIPPED` interlock | a group skip contributes one entry to `skipped`, so the message reads "N target(s) skipped" for N groups — wording, not arithmetic; the marker's content is the group name and the count is `length(skipped)`. Pre-existing (the `area.yml` arm did the same at `f8003ef`). | **Below** |

I also walked the statements inside the target loop that sit **above** the raster skip
(`:328-331` the non-list `stop`, `:342-353` the `species`/`scenario` validation, `:370-377` the
own/claim computation). All three abort rather than skip, all three were in that position in
`f8003ef` except the own/claim block, which is round 1's 2b fix and is correct there.

**What round 2's table missed:** `:212`, `:233`, `:728-739`, `:742-778`, `:786-797`, and the
target-loop pre-skip statements. Five of the six are pre-existing in the diff's base and five of
the six carry recorded reasoning; **none is Above its source of truth in the current tree**, and
the one unargued member (`:212`) is not this branch's.

### M2 — every assertion and expectation, with the artifact its reference comes from

`scripts/test_pipeline.R` (18 arms):

| arm | reference artifact | shares an ancestor with the thing checked? | verdict |
|---|---|---|---|
| `:102` staged item count | `config/<wsg>/area.yml` (upstream, `[[`) | no | Below |
| `:118-121` COG set vs `meta$years` | `meta.json` (01) vs `data/stac` listing (03) | **yes** — both descend from 01's `years` | Below for what it is for (a COG lost in 02/03); the year set itself is owned by `fp_years_reconcile` + `stage_years-check.R`, and `:288-294` says so. Pre-existing (#61). **Round 2's table missed this row.** |
| `:122-131` gpkg count, area positivity | literals | no | Below |
| `:141-154` item JSON properties, `flood_factor` | `meta.json` vs item JSON (two scripts) | no | Below |
| `:194-203` staged provenance field set | a literal declared in the test | no | Below |
| `:215-230` published key set + software entries | `meta.json` vs item JSON | no | Below |
| `:237-240` processing-extension biconditional | item JSON **vs itself** | **yes** | Below — internal consistency is the property, forced by the schema. Pre-existing (#74). **Round 2's table missed this row.** |
| `:249-280` provenance values | the producer's raw `provenance.json`, read independently of `fp_provenance.R` | no | Below — the strongest arm in the file |
| `:286-299` asset count | `meta$years` | different artifact from the item JSON under test | Below |
| `:304-320` style + transition asset keys | literals / `meta$transition_span` | no | Below |
| `:321-338` checksum shape, `file:size` vs disk | item JSON vs a fresh `file.size()` | partly — item_create.py wrote the size from the same file | Below; the re-measurement is what catches a write landing after the build. **Round 2's table missed this row.** |
| `:382-426` per-layer key arm | `meta.json` + `want_scen_for()` re-derived in the test | no | Below (see finding 4 for what the round-2 fix gave up) |
| `:440-473` layer-set arm | the **source** file's own key table, re-derived in SQL | no | Below |
| `:484-496` absolute floor of layer names | `meta$years` + `meta$scenario` | no | Below |
| `:513-554` label decode | `transition_vector.gpkg`'s own `from_class`/`to_class` | **#80 changed this oracle's provenance** — the file is now extracted from a bundle this repo writes | Below, **measured**: `vectortranslate` carries the producer's column values through unchanged, and extracting the layer from upstream vs from the staged copy gives a byte-identical file (`10ea7c71…`, 2,408,448 B). The two sides still have different producers. Nothing in the branch records this; it is the one M2 row #80 genuinely moved and nobody checked. |
| `:579-580` staged targets vs declared | `area.yml` | no | Below |

`scripts/gpkg_determinism-check.R` (5): arm-1 source = staged landcover, layer name from
`meta.json`, no content claim (determinism only) — Below; arms 2-3 source = the **producer's**
files — Below; layer SET from the staged file — accepted tradeoff, argued at `:102-113`;
cold-path `any(same)` and warm-path `!all(same)` — Below; the `upstream_skipped` /
`NOT PROVEN` report — Below.

`scripts/01_stage.R` (11): class-table floors `:111-118` (absolute literals, Below);
region-field `:149`, `WSG_ONLY` roster `:169` (Below); the two key refusals `:297-315`
(reference is the roster + `GPKG_ITEM_KEY`, Below); target-field validation `:342-353` (Below);
`fp_years_reconcile` `:410` (disk vs record, two producers, Below); raster copy `:443`/`:449`
(Below); empty-own-set refusal `:471-477` and all-aspatial refusal `:482-489` (reference is the
item's key from the roster against the file's keys, Below — but see finding 2 for the instance
the comment names); `missing_layers` `:590-603` (Below, and it reduces to
`setdiff(needed, own_fp)` because `gpkg_copy_layers`'s own `setequal()` already pins the staged
set to `own_fp`, so it is exactly the name-vs-key cross-check it claims to be).

**Verdict on completeness:** round 2's 13-row table missed six M1 statements and four M2 arms.
I verified every one of them Below, pre-existing, or argued in place. **No missed place is Above
its source of truth in the current tree**, so the enumeration is now closed for both mechanisms.

---

## 2. Row-by-row verdicts (round 2's 13 rows, against the current tree)

| # | round 2's row | current tree | verdict |
|---|---|---|---|
| 1 | `01_stage.R:278-296` — the two group-level `stop()` arms | now `:297-315`, unchanged in disposition | **Deliberate.** The brief records the split as the user's decision. Position still group-scope; the read beside it is now a skip, which is what round 2's finding asked for. Not re-flagged. |
| 2 | `01_stage.R:243-250` — the two `gpkg_layer_keys()` reads | now `:265-275`, wrapped in `tryCatch(error=)` -> recorded group SKIP | **Below** |
| 3 | `01_stage.R:336-358` — `own_fp`/`own_lc`/`claimed_*` | now `:370-377`, above the raster skip at `:379` | **Below** |
| 4 | `01_stage.R:486-508` — aspatial report + `unfamiliar` | now `:512-519` over **both** `keys_fp` and `keys_lc`; `:532-537` anchored at both ends | **Below.** Verified mechanically against every real layer name in all 24 areas: both patterns match 100% of real names (incl. `ch_ff06_by_blue_line_key`, `co_ff04_by_gnis_name`, `classified_*_patches`, `composition_*`, `patch_watercourse_*`) and reject `bt_ff04_reach_summary`, `classified_bt_ff04_2017_summary`, `patch_crossings_…`, `reach_bt_ff04_2017`, `classified_bt_ff04`. No false positive, so the report cannot go noisy and be ignored. |
| 5 | `01_stage.R:552-569` — `missing_layers` | now `:590-603` | **Below** |
| 6 | `gpkg_copy_layers():219` — `sort(…, method = "radix")` | now `:223` | **Below.** C-locale re-verified independently. |
| 7 | `fp_gpkg.R:241-244` — the handler-nesting comment | now `:246-252`, corrected | **Below.** Both nestings re-measured: each captures warning and error. |
| 8 | `test_pipeline.R:395-404`, `:430-437`, `:470` — the ff-set rule three times | `want_scen_for()` defined once at `:368` (inside the item loop, closing over the current `meta`) and called at `:415` and `:455`; the floor arm at `:484` keeps deriving its own names, by design | **Below** |
| 9 | `test_pipeline.R:440-458` — the SQL set arm's silent `next` | now `:446-450`, prints `NOT CHECKED: …` | **Below** |
| 10 | `test_pipeline.R:468-480` — the absolute floor | now `:475-496` | **Below** |
| 11 | `test_pipeline.R:24-27` — the dead `source()` of `fp_gpkg.R` | removed; `:23` is `library(sf)` and nothing in the file calls `gpkg_layer_keys()`, `gpkg_own_layers()`, `gpkg_pin_date()`, `GPKG_EPOCH`, `gpkg_write_layer()` or `gpkg_extract_layer()` — re-grepped | **Below** |
| 12 | `gpkg_determinism-check.R:114-117` — layer set from the staged file | `:114-117`, argued in a comment | Accepted tradeoff; not re-flagged |
| 13 | `gpkg_determinism-check.R:38-43` — existence precondition over both files | `:38-43`, loops `floodplain_landcover.gpkg` + `floodplain.gpkg` | **Below** for the guard; its comment overstates its scope — finding 3 |

All 13 rows are Below or recorded as a deliberate disposition. None regressed.

---

## 3. Findings outside both mechanisms

- **[fragile]** `planning/active/findings.md:101` and `planning/active/task_plan.md:34` — round 2's
  "21 -> 20" correction landed in **one of three copies**, and `progress.md` records it as
  complete. `findings.md:174-177` now reads "including the **20** groups with no foreign layers
  (23 rostered minus bulk/kisp/morr — an earlier draft of this line said 21, counting the 24
  upstream area dirs rather than the roster)". Seventy-three lines above it, `findings.md:101`
  still reads "The other **21** rostered groups have none", and `task_plan.md:34` still reads
  "the other **21** rostered groups have none". `progress.md:229-230` states "'The 21 groups with
  no foreign layers' is 20 … `NEWS.md` had it right; `findings.md` did not" — which asserts the
  file is fixed while the wrong number survives in it. Re-derived: 23 rostered − 3 = **20**; 21
  is 24 upstream area dirs − 3, and `neexdzii` has no item. `NEWS.md` is correct. This is round
  2's finding 2 one round later — a correction whose enumeration was one short — and it is the
  class the brief says matters as much as the code, because the next session reads `findings.md`
  and `task_plan.md` as the measurement record.

- **[fragile]** `planning/active/findings.md:111-115` and `scripts/01_stage.R:461-466` — the
  empty-own-set refusal's recorded instance is unreachable, twice over.
  `findings.md:113-115` concludes: *"Its layers' `wsg` column reads `BULK` … so it never stages.
  **This is why the zero-layer stop in Phase 2 is a real guard and not a defensive one.**"* Both
  legs fail:
  1. `config/regions/skeena.yml:29` is `watershed_groups: [BULK, MORR, KISP]   # NEEXDZII (subset
     of BULK) intentionally excluded` — verified, and `neexdzii` appears in no other roster — so
     `01_stage.R` never walks it and `WSG_ONLY=neexdzii` is refused at `:169`.
  2. Even if it were rostered, the **group-level foreign-`wsg` refusal at `:306-314` fires
     first**, before the target loop ever computes `own_fp`. By line order (`:306` group scope
     vs `:374` inside the target loop) any `wsg` mismatch stops the group with the foreign-`wsg`
     message, not the empty-own-set one. After `:297-315` every layer is `status == "ok"` with a
     matching `wsg`, so `own_*` can only be empty through a **species or scenario** mismatch —
     which is exactly what `progress.md`'s mutation table actually tested (`species='xx'` on
     every floodplain layer). The guard is live; the reason written beside it names a case the
     arm above it owns.
  `01_stage.R:461-464` carries the same attribution ("An empty own set is NEEXDZII's shape — its
  layers carry `wsg = BULK`"). Same class as round 2's finding 5: a correct guard with a false
  recorded reason, and the cost is that a later reader could delete either arm believing the
  other covers its case. Remedy is one sentence: the arm's live shape is a species/scenario
  mismatch, and a `wsg` mismatch is refused at group scope.

- **[fragile]** `scripts/gpkg_determinism-check.R:35-37` — the precondition's comment claims a
  scope its loop does not have. *"**All three**, not just the one the first arm reads: **the other
  two** are what the multi-layer arms take their layer sets from"*, over
  `for (f in c("floodplain_landcover.gpkg", "floodplain.gpkg"))` — two files, with one of them
  being "the one the first arm reads". `transition_vector.gpkg` is never read by this script (it
  is arm 1's **output**, written to `tempdir()`), so two is the correct set and the quantifier is
  the defect. Introduced by round 1's fix (`637e71c`) for round 1's own minor note that the guard
  covered only one path. Costs nothing today; it is the `every`/`all N` quantifier the
  conventions say to walk before writing, in a file whose header one line up correctly says
  "three GeoPackages per item".

- **[fragile]** `scripts/test_pipeline.R:416` — round 2's finding 4 was resolved by relaxing the
  stricter of the two drifted copies, and the coverage it provided is now gone. The per-layer arm
  was `identical(k$wsg[1], meta$wsg)` and is now `identical(toupper(k$wsg[1]), toupper(meta$wsg))`.
  Every other `wsg` comparison in the repo already case-folds (`gpkg_own_layers()` at
  `fp_gpkg.R:190`, the foreign-`wsg` refusal at `01_stage.R:306`, the set arm at
  `test_pipeline.R:461`), so **nothing now asserts that the published `wsg` *column* equals the
  published `wsg` *property***, which is the join a consumer makes when merging items and
  filtering on `wsg == 'MORR'`. Measured: all 23 upstream groups write the column uppercase, so
  this is latent, not live. The direction matters though — round 2 characterised the strict
  compare as "not fatal (it fails safe)", and the fix removed a safe failure rather than fixing
  its message. Cheapest remedy keeps the key arm case-folded and adds one line with its own
  message: `identical(k$wsg[1], meta$wsg)` -> "the layer's `wsg` column is `x` but the item
  publishes `X`; a consumer filtering on the published property will not match this layer."

- **[fragile]** `scripts/README.md:149-150`, `:275`, `:326` — three published commands name an
  item a rebuild no longer produces. `bulk_co_ff04` stopped being a staged target when upstream
  retired BULK's `targets:` block (`config/bulk/area.yml` is `species: all`,
  `primary_scenario: all_ff04`, verified), so:
  - `:149-150` is a two-line recipe that cannot run as written —
    `WSG=bulk Rscript scripts/test_pipeline.R` stages `bulk_all_ff04`, and
    `catalogue_release.sh --only bulk_co_ff04` then fails step 0's "the item's JSON and asset dir
    must exist" (`bulk_all_ff04` would fail the other arm, "the item must already be live").
  - `:275` and `:326` are `ITEM=bulk_co_ff04` examples for the two determinism checks, both of
    which stop on "no staged … at data/stac/bulk_co_ff04".
  Phase 4's sweep fixed the **identical string** in `style_determinism-check.py:19`
  (`bulk_co_ff04` -> `morr_all_ff04`) and left all three copies in `scripts/README.md`, plus
  `catalogue_release.sh:7` (same `--only` example) and `:56` ("any full rebuild from today's
  producer tree carries `bulk_co_ff04`", now false, though superseded two lines later by the live
  `21 of 23` sentence). Pre-existing from floodplains#125 rather than caused by #80 — but the
  branch touched exactly this fact in one of six places, which is the same enumeration miss as
  the first finding. It fails safe (a clear refusal, no write), which is why this is `fragile`
  and not `bug`.

### Checked and correct (not findings)

- **NEWS.md's consumer-facing claims hold under measurement.** "Nothing a consumer reads changes
  value" re-derived on MORR, the hardest group: `all_ff02/04/06` areas and loss/gain identical
  read from upstream and from the staged copy, and identical to `meta.json`. And "both assets"
  is precise — `transition_vector.gpkg` is byte-identical whether extracted from upstream or
  from the staged bundle, so it is **not** a third asset whose checksum moves.
- The anchored family patterns are correct in both directions over the real population
  (0 false positives on 276 layers, 7 of 7 hypothetical new families reported). `sp_prefix` is
  interpolated into a regex unescaped, which is safe while the producer's species slot is
  `^[a-z]{2,4}$`.
- `gpkg_copy_layers`'s `setequal(written, layers)` makes `01_stage.R:590`'s `missing_layers`
  arm reduce to `setdiff(needed, own_fp)` — a genuine name-vs-key cross-check with two
  independent sources, as its comment claims.
- `aws s3 sync` is run with **no** `--size-only` on both paths, so a rewritten bundle of
  coincidentally identical size still uploads (`data/stac` is wiped each run, so local mtime is
  always newer). #80 rewriting every bundle cannot leave a stale object under a fresh
  `file:checksum`.
- `gpkg_copy_layers`'s radix sort and `gpkg_determinism-check.R`'s SQL `ORDER BY table_name`
  agree, because SQLite's default `BINARY` collation is the same byte order. The arm cannot
  prove a byte order the stage does not write.
- `tryCatch(gpkg_layer_keys(p), error=)` also swallows the unfired zero-layer precondition and
  turns it into a group skip. That is the right disposition for a crashed producer run (and the
  precondition's value — naming the file — survives in the skip message), so it is not a defect;
  worth knowing that `fp_gpkg.R:121`'s "refuses rather than passes" means "refuses the file",
  not "refuses the run", from its only live caller.
- No eleventh copy of the whole-copy premise: `grep -rniE "copied whole|whole-WSG|copied
  verbatim|whole copy|verbatim upstream|synced whole"` over the tracked tree returns only
  past-tense or correct statements (`NEWS.md:24`, `CLAUDE.md:125`, `CLAUDE.md:262`,
  `catalogue_release.sh:602`, `test_pipeline.R:346`, `gpkg_determinism-check.R:10`) plus the
  archived PWF.
- `item_create.py:427-431`'s "per-blue-line-key breakdown of **the headline scenario**" is still
  inert, as round 2 said: `needed` holds the whole ff set, so an `ff06`-headline item could
  publish an `ff04`-keyed breakdown — but MORR's `ch_ff06_by_blue_line_key` is the only `_by_*`
  layer not on `*_ff04`, and no rostered item has an `ff06` headline. Not re-flagged.
- `README.Rmd`'s `floodplain` asset line ("three flood factors") is a statement about flood
  factors, not layer count, and `README.md` / `index.html` are deliberately un-rendered until
  release step 6 (#55). Not re-flagged.
- Trivial, mentioned once and not worth a fix on its own: `progress.md:110` says KISP
  `57.2 -> 37.0`, round 2's independent re-derivation said `37.1`. `NEWS.md` carries only the
  percentage, which both support.

---

## Verdict

**Enumeration closed.** Both mechanisms' candidate sets were derived mechanically and walked
member by member; round 2's table was ten entries short of the full set and every missing entry
is Below, pre-existing, or argued in place. All 13 of round 2's rows are Below or a recorded
deliberate disposition against the current tree, and none regressed.

Five findings, **no bugs** — three are evidence-record defects in `planning/` and in two code
comments (a stale number in two files, a false reason beside a correct guard, an overstated
quantifier), one is a guard relaxed rather than repaired, and one is a set of published commands
naming a retired item id. Nothing changes what gets published, and nothing blocks the PR.

The round-1 -> round-2 -> round-3 pattern now has a measurable shape worth recording: each round's
best finding was a **correction whose own enumeration was one short** — round 1 fixed one of three
statements in the same position, round 2 fixed one of ten copies of a premise, round 3 found one
of three copies of a number. The instrument that would have ended it earlier is not another
reviewer: it is `grep` for the sentence before declaring a sweep complete, which is what round 2
itself prescribed and what its own correction then skipped.
