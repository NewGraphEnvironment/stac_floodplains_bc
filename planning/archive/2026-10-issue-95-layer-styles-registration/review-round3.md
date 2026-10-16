# Code-check round 3 — `95-qgis-cannot-find-the-embedded-styles-in`

Merge-base `4db1fa8`, HEAD `d1a5ced`. Rounds 1 and 2 each found a defect inside the previous
round's fix, so this round terminates by **enumeration**, not by a quiet pass. Every member of
every candidate set below was found by grep/parse, not by recall, and every verdict marked
"measured" was taken in this session (2026-10-16) on copies of `data/stac/sloc_all_ff04/` in a
temp directory. `data/` was never written to: its mtimes are unchanged and
`item_validate.check_checksums` re-hashes clean after the QGIS run.

Tools used for the measurements: sf's GDAL 3.8.5, QGIS 4.2.1's GDAL 3.12.4 (`ogrinfo`, PyQGIS),
homebrew's GDAL 3.13.0, `sqlite3`.

---

## Sweep 1 — every reader that selects on `gpkg_contents.data_type`, or enumerates GDAL's layer list

Candidate set from `grep -rn "data_type\|gpkg_contents\|st_layers\|layer_styles" scripts/`. 11
layer-selecting/enumerating readers, plus 3 sites that assert on the registration row rather
than select with it (those are sweep 2).

| # | reader | filter | side it reads | style table in/out | verdict |
|---|---|---|---|---|---|
| 1 | `04_gpkg_style.py:173-176` `feature_layers()` | `data_type='features' AND table_name <> ?` | staged (it is the writer) | **out**, twice | correct, and the name arm is in the right place — it sits **above** `intended_rows()`, which is what would otherwise raise/mis-style. Round 1's fix |
| 2 | `style_reach-check.py:158-163` `feature_layers()` | same | staged | **out**, twice | correct. Round 2's fix |
| 3 | `test_pipeline.R:408-414` `keyed_layers()` | `data_type IN ('features','attributes') AND table_name <> 'layer_styles'` | staged | **in** the `data_type` filter since #95; **out** by name | correct, and paired with the positive listing arm at `:427-434` |
| 4 | `gpkg_determinism-check.R:129-133` | same | staged, handed to `gpkg_copy_layers()` against the **producer's** file | **in**; **out** by name | correct. Excluding beats intersecting with the producer's layers: an upstream layer genuinely lost must still fail loudly |
| 5 | `test_pipeline.R:516-519` (`src_lyrs`) | `data_type IN ('features','attributes')`, **no** name arm | **producer** (`$FLOODPLAINS_DATA/<wsg>/`) | n/a | bounded. Producer bundles carry no style table; verified by enumerating `gpkg_layer_keys()`'s only call site (`01_stage.R:281`, over `gpkg_src` under `src_wsg`) |
| 6 | `item_validate.py:1711-1712` (`layers`) | `data_type='features'`, **no** name arm | staged | **out**, because the registration is `attributes` | bounded, and bounded by a guard rather than by luck: the registration arm 20 lines above refuses any other `data_type` first. **Measured** with a hand-set `features`: the correct refusal fires, plus one spurious `layer 'layer_styles' has no style row` message. Noisy, not a miss |
| 7 | `fp_gpkg.R:136-140` `gpkg_layer_keys()` | `gpkg_contents` **unfiltered** | producer only | n/a | bounded, and the new comment's claim ("only ever reads the PRODUCER's files") is **true** — verified by enumerating call sites |
| 8 | `01_stage.R:502-507`, `:541-542` | `data_type %in% 'features'` / `'attributes'`, from (7) | producer | n/a | bounded by (7) |
| 9 | `01_stage.R:619` `st_layers(fp_gpkg)` | `setdiff(needed, …)` | staged, **pre-04** | n/a | bounded twice: `01_stage.R:86` wipes `data/stac` on every run, and 04 runs after 01 in both entry points (`run_pipeline.sh:63`, `test_pipeline.R:68`); the `setdiff` is one-directional anyway |
| 10 | `fp_gpkg.R:69-79` `gpkg_extract_layer()` (`available`) | `st_layers()`, membership test | producer (01_stage) **and post-04 staged** (`gpkg_determinism-check.R:91`) | **in** the list | bounded: an extra name only widens a membership test |
| 11 | `fp_gpkg.R:280` `gpkg_copy_layers()` read-back | `setequal(st_layers(dst), layers)` | fresh `dst` | n/a | bounded: `dst` is absent before the write, so no style table can appear on either side |

Non-readers, confirmed by grep rather than assumed: `item_create.py` never opens a GeoPackage
(it hashes bytes); `catalogue_release.sh` / `item_register.sh` / `item_unregister.sh` /
`item_retract_s3.sh` make no GeoPackage reads; `catalogue_release-check.sh` shims
`item_validate.py` away entirely (its own line 78 says so); `readme_functions.R` reads the live
API through rstac.

**Sweep 1 closed.** 4 readers exclude by name, 1 by `data_type` with an independent guard
upstream of it, 6 bounded by the side they read or by pipeline order. Nothing is above its
source of truth: every by-name exclusion either sits beside a positive listing assertion
(member 3) or is on a reader whose `data_type` filter would not see a new aspatial family
either way (members 1, 2, 4).

---

## Sweep 2 — every assertion the branch adds or changes

18 sites. "Failure value" is what the state the assertion exists to catch actually produces.

| # | assertion | failure value | expected | able to fail? |
|---|---|---|---|---|
| 1 | `04_gpkg_style.py:277-280` registration read-back | — | `(table_name, last_change)` present | **NO, in one direction** → finding 2 |
| 2 | `04_gpkg_style.py:328-334` `total_reg != total_files` | `0 of 3` | `3 of 3` | yes — **measured** by restoring the pre-#95 writer: `SystemExit`, "3 GeoPackage(s) ended without a pinned … registration" |
| 3 | `04_gpkg_style.py:210-213` "declares no feature layers" | `[]` | non-empty | yes (unchanged); can no longer be tripped by the style table |
| 4 | `item_validate.py:1690-1694` `len(reg) != 1` | `0` | `1` | yes — **measured** on a de-registered `floodplain.gpkg` |
| 5 | `item_validate.py:1695-1699` registration shape | `('layer_styles','features','layer_styles','',0)` | `(…,'attributes',…,0)` | yes — **measured** |
| 6 | `item_validate.py:1700-1709` `last_change` pin | a wall-clock stamp | `2000-01-01T00:00:00.000Z` | yes — **measured** |
| 7 | `item_validate.py:1017-1023` `gpkg_epoch()` refusal | no regex match | the literal from `fp_gpkg.R:43` | yes; **measured** that it matches today (`2000-01-01T00:00:00.000Z`) |
| 8 | `style_determinism-check.py:160-170` arm 4 | `[]`, or a wall-clock `last_change` | `[('attributes', pinned)]` | yes. Warm-only, correctly — cold mode writes a wall-clock stamp on purpose |
| 9 | `style_determinism-check.py:186-207` arm 5 (repair) | `sqlite3.IntegrityError` | no raise, then `[(pinned,)]` | yes, and the setup is non-vacuous as the comment says (the row must **differ**, or the writer skips the branch). **Measured** that the guarded error is `UNIQUE constraint failed: gpkg_contents.identifier`, which is what three of the four copies of that claim now say |
| 10 | `test_pipeline.R:427-434` positive `st_layers()` arm | table not listed | listed | **yes on `floodplain_landcover.gpkg` only** — measured: de-registered, `layer_styles` is listed `FALSE` there and `TRUE` in the other two bundles. Accepted tradeoff, stated in the comment |
| 11 | `test_pipeline.R:413` name exclusion | — | — | not an assertion; the three arms it feeds stay non-vacuous via `if (!length(lyrs)) stop(...)` |
| 12 | `style_reach-check.py:243-250` literal-drift arms | a drifted dict, or absence (`SystemExit`) | full equality | yes. Verified there is exactly one `Assign` for each name in `item_validate.py` (`EXPECT_RENDERER` at `:1597`, inside `check_layer_styles`, which is why `ast.walk` is needed; `EXPECTED_STYLE_CATEGORIES` at `:1040`) |
| 13 | `style_reach-check.py` `expected_opacity()` multi-value refusal | >1 distinct alpha | exactly 1 | yes; **measured** one value today — `alpha="0.5"` on 10 + 91 + 1 = 102 symbols |
| 14 | `style_reach-check.py` `expected_opacity()` 1.0 refusal | `1.0` | anything else | this is the discriminator round 1 added; without it the four `singleSymbol` assertions coincide with the failure state |
| 15 | `style_reach-check.py` warm arms (renderer, categories, opacity) | `singleSymbol` @ 1.0 | per-kind renderer, 10/91 cats, opacity 0.5 | yes — **ran it**: 9/9 `ok` |
| 16 | `style_reach-check.py` cold arm | style still found | style lost | yes — **ran it**: `classified_all_ff04_2017 -> singleSymbol opacity=[1.0]` after de-registration |
| 17 | `style_reach-check.py:340` `if not checked` | 0 | >0 | yes (vacuity guard) |
| 18 | `item_validate.py:1846-1850` `checked_files == 0` | 0 | >0 | yes (pre-existing, still reached) |

Two independent re-runs for the record: `style_determinism-check.py` PASS warm (3/3 byte-identical,
re-run a no-op) and PASS cold (`NO_PIN=1`, 3/3 differ); `check_layer_styles` over `data/stac`
returns 0 problems.

Also measured, because it is the premise under `data_type='attributes'` and nothing in the repo
can re-derive it: with the registration set to `features` in all three bundles, QGIS 4.2.1 builds
`singleSymbol` at opacity 1.0 for **all nine** styled layers, the two bundles with no aspatial
table included. The branch's claim is exactly right.

**Sweep 2 closed**, with one assertion whose expected value does not separate the state it
claims to assert (finding 2) and one whose scope is narrower than its name suggests and says so
(member 10).

One shape worth naming rather than reporting: `expected_opacity()` and `literal()` raise
`SystemExit` from inside `main()`, discarding failures collected before them — the third
instance of the shape rounds 1 and 2 each fixed once. Both are deliberate hard refusals that
name their own remedy, so this is a note, not a finding. `style_kind()`'s `SystemExit` inside
the warm loop is still live but unreachable from a real tree: a layer matching no style rule
makes `04_gpkg_style.py` refuse the build first.

---

## Sweep 3 — every quantified or inherited claim the branch touches

34 claims, enumerated by `grep -inE '\b(all|every|each|both|three|four|five|…|23|46|66|91|102|108|276)\b'`
over the branch's added lines, then by `grep -rn "every layer\|each layer\|all layers"` over every
tracked surface. Verdicts: 30 true, 3 false-or-incomplete (findings 1, 3, 4), 1 true of 2 of 3
bundles (finding 6).

### `CLAUDE.md`

| claim | verdict |
|---|---|
| `features` instead loses the style in **all three** bundles | **true** — re-measured through PyQGIS, 9/9 layers |
| present, correct, complete and invisible on **all 23** items | **true**, bounded by CLAUDE.md's own "all 23 items carry both" aspatial measurement |
| measured on GDAL 3.8.5, 3.12.4 **and** 3.13.0, all three agreeing | **true** — all three re-measured here |
| registered in **all three** bundles | **true** — `gpkg_contents` dumped for all three staged files |
| **Three** guards ask three different questions | **true** |
| the staged-side readers (`test_pipeline.R`, `gpkg_determinism-check.R`) exclude it BY NAME | **incomplete** → finding 3 |
| Every **DATA** layer of all three carries `wsg`/`species`/`scenario` | **true** — `test_pipeline.R` asserts it over `features` + `attributes` |
| `:197` their mere registration is what made GDAL stop listing the unregistered table | **true** |
| `:66` maps **every feature layer** of `floodplain.gpkg` to one style unconditionally | **true** |

### `NEWS.md` v2.0.1

| claim | verdict |
|---|---|
| **All 23 items** republish | **true** (every bundle's bytes move) |
| Four layers per item, eight on the four annual-span items, **108** styled layers | **true** — 19x4 + 4x8 = 108; the annual span is 2017-2023 = 7 classified years + 1 transition, confirmed from `ALLOWED_YEAR_SETS` |
| the **10**-class `classified` / **91**-category `transition` style | **true** — QGIS reports exactly 10 and 91 |
| **18 / 5** on 2026-10-14 | **true** against CLAUDE.md's measurement of the same tree |
| three GDALs — 3.8.5 (`sf`), 3.12.4 (QGIS 4.2.1's own), 3.13.0 (homebrew) | **true**, all three present and re-measured |
| already false on **two of the three** bundles | **true** — de-registered, the table is listed in `floodplain.gpkg` and `transition_vector.gpkg` and hidden in the landcover bundle |
| corrected "in the published `floodplain_landcover` asset description and on the landing page" | **incomplete** → finding 4 |
| `style_determinism-check.py` gains **two** arms | **true** (arms 4 and 5) |
| `gpkg_contents.table_name` being the PRIMARY KEY makes an unconditional INSERT raise | true in effect; SQLite reports `identifier` (measured). The three other copies of this claim say so; this one does not. Bounded |
| no provenance floor / census line beside the entry | the repo's own rule asks for one → finding 5 |

### `scripts/README.md`

| claim | verdict |
|---|---|
| **Five** properties / five arms | **true** |
| `# 6 layers, no layer_styles` then `# 7 layers` | **true** — measured both ways on QGIS's and homebrew's `ogrinfo` |
| the registered table reads with a count, typed columns, no warning and no `gpkg_ogr_contents` row | **true** — measured |
| "every layer of `floodplain.gpkg` — `<sp>_ff02/04/06`, plus `_by_blue_line_key`, on all 23 groups" (`:449`) | bounded by its own enumeration (round 2's verdict, re-affirmed) |
| "all 24 layers of a multi-target group" | pre-existing, untouched |
| the recipe had been there since #46 and had never been pointed at this bundle | not checkable from the tree; consistent with the #46 archive |

### `scripts/item_create.py` (published strings)

| claim | verdict |
|---|---|
| `:423-426` "since #95 it does so in all three bundles … already visibly false" | **true** |
| `:436-441` "since #95 that enumeration is five entries" | **false** → finding 1 |
| published: "every **data** layer carries wsg/species/scenario" | **true** |
| published: "Each **data** layer records its own flood factor … read the **feature layers** rather than assuming three" | **true** — 4 feature layers, 3 distinct `scenario` values |

### `README.Rmd` / `README.md` / `index.html`

| claim | verdict |
|---|---|
| Every GeoPackage **data** layer carries `wsg`, `species`, `scenario` | **true** |
| "(Each file also holds a `layer_styles` table … carries no key)" | **true** for all three, and true of `layer_styles` in every version |

### Code comments elsewhere

| claim | verdict |
|---|---|
| `style_qml-write.py:20` "every **feature** layer of `floodplain.gpkg`, which carry no class attribute" | **true** |
| `test_pipeline.R:354` "every **DATA** layer of **BOTH** published GeoPackages" | bounded — "BOTH" is pre-existing and the next sentence names the two upstream bundles; the sibling claim at `:363` correctly says "every published GeoPackage" |
| `test_pipeline.R:390-397` "all three hiding it in `floodplain_landcover.gpkg` and listing it in the other two" | **true** — re-measured |
| `style_reach-check.py` "four of this script's nine assertions", "all **102** symbols", "one assertion covers all nine layers", "uniform across all three styles" | **true** — 9 styled layers; 10 + 91 + 1 = 102 `alpha="0.5"` attributes |
| `04_gpkg_style.py:94-99` the row is "shaped to match what GDAL itself wrote for the sibling `attributes` rows" (identifier = table name, empty description, NULL bbox, `srs_id` 0) | **true** — measured against `composition_*` / `patch_watercourse_*` in the same file, including the NULL bbox, and `srs_id 0` exists in `gpkg_spatial_ref_sys` in all three bundles with `PRAGMA foreign_key_check` clean |
| `04_gpkg_style.py:48` "`ogrinfo -so` on the registered table reports `Feature Count: 4`" | **true of 2 of 3 bundles** → finding 6 |
| `fp_gpkg.R:119-121`, `:132-135` the producer-only claims | **true** — call sites enumerated |

### Outside the repo

The retired premise also lives in the shared spatial code-check convention, which every repo
loads — two paragraphs of it are false. An issue **and** a PR are open in the repo that owns it,
so it is bounded. This repo's own synced copy carries index lines only, and the false sentences
are not among them (grepped).

### Privacy sweep (the branch's own rule, and round 1's first finding)

The only `<repo>#<N>` form the branch adds is `floodplains#30` (public). The one private-repo
citation inside the diff is a context line in `04_gpkg_style.py`, pre-existing and covered by
this repo's open #86. Checked every sibling checkout name against the diff: the hits are
`floodplains`, `drift`, `breaks` and `fresh` — the last two as ordinary English words.

**Sweep 3 closed**, with findings 1, 3, 4, 6 outstanding and finding 5 as a release-readiness
note.

---

## Findings

- **[fragile] `scripts/04_gpkg_style.py:277-280`** — the registration read-back asserts a
  strictly weaker predicate than the writer already holds, and it is weaker in exactly the
  direction this branch measured as fatal. It reads back `table_name` + `last_change` only, so a
  registration written as `data_type='features'` reports *"layer_styles registered and pinned in
  3 of 3 GeoPackage(s)"* and the step exits 0. **Measured**: with `intended_registration()`
  returning `"features"`, `main()` returned `rc 0` with that summary line, and the file ended
  `layer_styles|features`; separately measured through PyQGIS, that state loses the style on
  **all nine** styled layers of all three bundles — the same outcome the refusal six lines below
  describes in its message. The comment above the read-back is explicit that its job is to read
  the registration back "rather than reporting the intent", and `want_gc` is in scope one line
  away. Bounded, and the bound is a different file: `item_validate.py`'s independent copy refuses
  it (measured), and it runs in `run_pipeline.sh`, in `test_pipeline.R` and as
  `catalogue_release.sh`'s gate, with and without `--partial`. Fix is one line — compare the full
  `want_gc` tuple on read-back instead of two of its six fields.

- **[fragile] `scripts/item_create.py:436-441`** — the comment on the `floodplain.gpkg` asset
  description says *"since #95 that enumeration is five entries, the fifth being `layer_styles`"*.
  The attribution is false: `floodplain.gpkg` declares no aspatial content, so
  `LIST_ALL_TABLES=AUTO` listed the **unregistered** style table too — the enumeration was five
  entries before #95 as well. **Measured**: on a de-registered copy, `sf::st_layers()` and both
  `ogrinfo` builds still list `layer_styles` in `floodplain.gpkg` and `transition_vector.gpkg`.
  `NEWS.md:150-153` and `CLAUDE.md:155` both get this right ("already false on two of the three
  bundles", "never did"), so the comment contradicts the two prose surfaces that explain it, and
  it is inside round 2's own fix. It matters because a reader could conclude the published
  correction is contingent on the registration and revertible with it; it is not.

- **[fragile] `CLAUDE.md:68-70` and `scripts/fp_gpkg.R:133-135`** — both say *"the staged-side
  readers (`test_pipeline.R`, `gpkg_determinism-check.R`) exclude `layer_styles` by name"*, in a
  parenthetical that reads as the complete list. Four staged-side readers exclude it by name:
  those two plus `04_gpkg_style.py::feature_layers()` and
  `style_reach-check.py::feature_layers()` — which are precisely the two rounds 1 and 2 had to
  add, and the ones a future editor adding a third copy most needs pointed at. The distinction
  the sentence is reaching for is real (the two it names are the readers whose `data_type IN
  ('features','attributes')` filter now *includes* the row; the other two filter on `'features'`
  and exclude by name defensively) — so say that, rather than naming two of four.

- **[fragile] `NEWS.md:150-151`** — *"is now 'every **data** layer', in the published
  `floodplain_landcover` asset description and on the landing page"*. The branch corrected
  **both** GeoPackage asset descriptions, and the `floodplain` one is the substantive half: it is
  the description that instructs the consumer to enumerate ("read the feature layers rather than
  assuming three"), and leaving it uncorrected was round 2's finding 3. The release note as
  written reproduces the omission the round fixed.

- **[fragile] `NEWS.md:28` (v2.0.1 entry)** — the entry carries no provenance floor / census
  line, where CLAUDE.md's rule is that *"every release records the count beside its NEWS entry"*
  and that the literals are re-taken on the build the release is cut from, never carried. The
  literals are currently carried over from v2.0.0. **Measured now** with
  `Rscript scripts/prov_census-measure.R`: 23 rostered, floor **23**, `link_run_uid` **18**, the
  other eleven **23** — identical to `PROVENANCE_FLOOR=23` in `catalogue_release.sh:63` and
  `PROV_CENSUS` in `item_validate.py:558`, so nothing refuses today and no literal needs
  changing. The gap is only the recorded line, which is what makes the number recoverable per
  release; CLAUDE.md's own history has the same command giving five answers in one hour.

- **[fragile] `scripts/04_gpkg_style.py:48`** — *"`ogrinfo -so` on the registered table reports
  `Feature Count: 4`, `FID Column = id` and every column typed"*. Measured: 4 in
  `floodplain_landcover.gpkg` and `floodplain.gpkg`, **1** in `transition_vector.gpkg`, which has
  a single feature layer. The sentence names no bundle, and the paragraph above it is about all
  three. `FID Column = id`, the typed columns and the absent warning hold everywhere.

Nothing in the three sweeps sits above its source of truth. The two literals that could have
drifted are tied: `item_validate.py` reads `GPKG_EPOCH` from `fp_gpkg.R` rather than restating
it, and `style_reach-check.py` compares its renderer expectations against `item_validate.py`'s
statically. The three independent spellings of the expected registration row
(`04_gpkg_style.intended_registration()`, `item_validate.EXPECT_STYLE_REGISTRATION`,
`style_determinism-check`'s inline pair) use three different column orders and are **not** tied
to each other — which is correct here rather than a gap, because each is a guard over the others'
output and drift between them fails in the refusing direction (verified by mutation).
