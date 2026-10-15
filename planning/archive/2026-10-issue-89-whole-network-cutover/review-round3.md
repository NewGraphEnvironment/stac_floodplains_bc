# Code check round 3 — termination round (#89)

**Taken 2026-10-15T22:2xZ** against working tree at `de8e473` (one commit past the `d4d97e2`
the brief names), build at `data/stac` (23 items, newest mtime 2026-10-15T21:26:02Z — the
build predates every commit on the branch, so it is stable), producer tree at
`../floodplains/data`.

**Verdict up front: NOT converged.** The candidate set *is* now enumerated mechanically and
nothing new in kind was found — but round 2's single most substantive finding (the #80
bundle-size measurement) was fixed with a **wrong re-measurement**, landed in both copies at
once. That is a defect inside the previous round's fix, which is the one condition
`code-check.md` says keeps the rounds going. Round 4 should be a *verification* pass over the
table below, not another hunt.

---

## 1. Mechanism — confirmed, and wider than stated

The brief's (A) and (B) are both real and both confirmed. They are not two mechanisms, they
are one gap seen from two sides, and there is a third element the fix history adds:

> **This repo's duplication discipline was built for STRINGS, and its prose is full of
> QUANTITIES. Every mechanically pinned pair in the tree is a string; not one measured
> quantity is pinned by anything.**

Enumerated (§2.1): the pinned pairs are the licence/citation/provider block
(`attribution_drift-check.py`), the provenance field map and the three roster-mirror
expressions (`prov_fields-check.py`'s static arms), the committed QML bytes
(`style_drift-check.py`), and `RETIRED_ITEMS` ↔ the NEWS top section (the release's own step 2
delimited grep). All four ran clean today. **All four compare strings by equality.** The one
measurement script in the tree, `prov_census-measure.R`, covers the twelve provenance counts
and nothing else.

So (B) is not a separate failure mode — it is what is left over once (A)'s guards have taken
the strings. Every quantity in this tree is an unpinned duplicate by construction.

**The third element, which is what a termination round has to say:**

> **A fix for a stale literal is a copy, and equality verifies it. A fix for a stale quantity
> is a new measurement, and a measurement taken at the wrong scope is indistinguishable from
> a correct one.**

That is exactly what happened to round 2's finding 3. R2 measured and reported
`1035.3 MB` staged. The fix commit `d4d97e2` wrote `1124.6 MB` into both copies. `1124.6 MiB`
is the total of **all three** staged GeoPackages; the sentence it was written into is a
**two-bundle** before/after. Nothing about the new number looks wrong — it is precise, it is
labelled "measured on the v2.0.0 build", and the two copies agree with each other. Only
re-measuring finds it.

One clarification to the brief's framing of (B): the population did not simply "change". The
roster count is the same 23. What changed is **what is in each item** — every group went from
one species' layers to the whole network — so a count-of-groups claim survived the cutover
while every byte, layer, asset and per-item claim did not. That is why the sweeps that
checked "N of 23" claims came back clean and the size/byte claims did not.

---

## 2. Enumeration

### 2.1 Claims and literals duplicated across two or more tracked files

Mechanically derived: every quoted string literal ≥12 chars appearing in two or more of the
33 tracked code/doc files (177 hits), collapsed to the semantic groups below; plus every
prose claim restated in a second file that the quantity sweep (§2.2) surfaced.
Excludes `planning/archive/**`, `styles/*.qml`, `NEWS.md` pre-v2.0.0.

| # | Claim / literal | Copies (file:line) | Pinned by | Copies agree? | Correct? |
|---|---|---|---|---|---|
| 1 | `sci:citation` text (770 chars) | `item_create.py:~160`, `item_validate.py:~180`, `ATTRIBUTION.md` | `attribution_drift-check.py` (ran clean) | yes | ✅ |
| 2 | Licence `CC-BY-4.0` | `item_create.py`, `item_validate.py`, `catalogue_release.sh:92` (`EXPECT_LICENSE`), `catalogue_release-check.sh` | `attribution_drift-check.py` + step 5 read-back | yes | ✅ |
| 3 | Six `providers`, `rel: license`, `rel: derived_from` hrefs | `item_create.py`, `item_validate.py` | `attribution_drift-check.py` | yes | ✅ |
| 4 | "modified: clipped to the modelled floodplain extent…" | `item_create.py`, `item_validate.py` | `attribution_drift-check.py` | yes | ✅ |
| 5 | Provenance publish map (9 keys ← 12 fields) | `item_create.py:231+`, `item_validate.py`, `02_raster_tag.py`, `catalogue_release.sh` `--only` preflight / `only_preflight.py` | `prov_fields-check.py` static arms (49 assertions, 0 failed) | yes | ✅ |
| 6 | `FIELD_PREFIXES` table | `item_validate.py:557+`, `prov_fields-check.py` | `prov_fields-check.py` | yes | ✅ |
| 7 | STAC extension schema URLs (processing/file/projection/classification/version/scientific) | `item_create.py`, `item_validate.py`, `prov_fields-check.py`, `collection_version.py`, `test_pipeline.R` | `prov_fields-check.py` (partial) | yes | ✅ |
| 8 | `DEPRECATED_ITEMS` ↔ `EXPECTED_DEPRECATED` | `item_create.py:96` = `set()`, `item_validate.py:269` = `set()` | none (both-directions guard at run time) | **yes** | ✅ |
| 9 | `EXPECTED_RAT_ROWS {10,100}` / `EXPECTED_STYLE_CATEGORIES {10,91}` ↔ committed QMLs | `item_validate.py`, `styles/*.qml` | `style_drift-check.py` (ran clean, 10 classes) | yes | ✅ |
| 10 | `RETIRED_ITEMS` (23 ids) ↔ NEWS v2.0.0 entry | `catalogue_release.sh:86`, `NEWS.md` | release step 2, delimited grep | yes | ✅ (re-verified R1/R2) |
| 11 | Roster-walk expressions | `01_stage.R`, `prov_census-measure.R` | `prov_fields-check.py` 3 static arms | yes | ✅ |
| 12 | `PROVENANCE_FLOOR=23` ↔ `PROV_CENSUS` ↔ fixture populations | `catalogue_release.sh:63`, `item_validate.py`, `prov_fields-check.py:192-203` | `prov_fields-check.py` | yes | ✅ (re-verified R2) |
| 13 | **`ITEM` default `sloc_all_ff04`** | `gpkg_determinism-check.R:32`, `style_determinism-check.py:58`, `scripts/README.md:569` | **none** | yes | ✅ (all three moved together in this diff) |
| 14 | **`_by_blue_line_key` on all 23 groups** | `01_stage.R:554`, `style_qml-write.py:22`, `scripts/README.md:441` | **none** | yes | ✅ measured 23/23 |
| 15 | **`test_pipeline.R`'s WSG default** | `test_pipeline.R:32` (`bulk`), `scripts/README.md:275` ("defaults to UFRA"), `gpkg_determinism-check.R:29` ("the `ufra` defaults in test_pipeline.R and stage_years-check.R") | **none** | **NO** | ❌ **F2** |
| 16 | **#80 bundle-size before/after** | `CLAUDE.md:151-152`, `scripts/README.md:62-63` | **none** | yes | ❌ **F1** — both wrong |
| 17 | **"30 of 30" aspatial layers in the landcover bundle** | `CLAUDE.md:171`, `01_stage.R:529` (source: `fp_gpkg.R:93`, date-qualified) | **none** | yes | ❌ **F5** — now 68 |
| 18 | **Asset re-read size** | `item_validate.py:2013` `~670 MB`, `:2091` `670 MB`, `:2123` `~670 MB`, `prov_fields-check.py:11` `~670 MB`, `year_sets-check.py:9` `~670 MB`, `catalogue_release.sh:18` `~640 MB`, `:363` `700 MB`, `:1111` `~226 MB` | **none** | **NO** (640/670/700) | ❌ **F3** — now ~1,338 MB |
| 19 | **Per-item JSON size** | `item_create.py:726` `3-9 MB`, `item_register.sh:37` `3-9 MB each (~94 MB total)`, `catalogue_release.sh:525` `4-9 MB per item` | **none** | **NO** (3-9 vs 4-9) | ❌ **F3** — now 5.6–18.2 MB, 252.6 MB total |
| 20 | **NEWS.md byte size** | `catalogue_release.sh:686` `39,573 B`, `:726-727` `39,573 B` / `29,165 B` / `2.2x` | **none** | yes | ❌ **F8** — now 47,156 / 36,129 / 1.8x |
| 21 | `aaaa_*`/`bbbb_*`/`cccc_*`/`dddd_*`/`zzzz_*`/`none_*` synthetic ids | `catalogue_release-check.sh`, `prov_fields-check.py` | self-contained fixtures | n/a | ✅ |

**Count: 21 duplicated groups. 12 mechanically pinned (all strings, all clean today).
9 unpinned. Of the 9 unpinned, 3 agree and are correct (#8, #13, #14); 6 are wrong (#15, #16,
#17, #18, #19, #20).**

### 2.2 Every measured quantity in tracked prose

Derived by regex over the 33 tracked code/doc files for `N of M`, `N items/groups/layers/
areas/assets/classes`, byte and percentage forms. 86 raw hits; the soul-convention appendix
below `CLAUDE.md`'s marker and the self-dated historical measurements are separated out.

| # | file:line | Stated | Measured on this build | Verdict |
|---|---|---|---|---|
| 1 | `CLAUDE.md:151` | `1602.6 -> 1124.6 MB`, `MORR -67% (110.9 -> 36.4 MB)` | upstream two bundles **1602.6 MiB** → staged two bundles **1035.3 MiB**; MORR 110.9 → **34.0**, **-69%** | ❌ **F1** |
| 2 | `scripts/README.md:62-63` | "the two GeoPackage bundles … 1124.6 MB … down 478 MB from … (1602.6 MB)" | two bundles are **1035.3 MiB**; delta **567.3 MiB** | ❌ **F1** |
| 3 | `CLAUDE.md:145` | "22 of the 23 groups … only DUNC clean" | **22 of 23**, clean = `dunc` | ✅ |
| 4 | `CLAUDE.md:156` | "all 23 items carry both a `patch_watercourse` and a `composition`" | **23/23 and 23/23** | ✅ |
| 5 | `CLAUDE.md:159` | "measured 2026-09-05 and again 2026-10-14 it **was** 18 of 23 … and 5" | past tense, date-qualified | ✅ history |
| 6 | `CLAUDE.md:171` | "Every `attributes` layer upstream is in the landcover bundle **today** (30 of 30, measured)" | **68** attributes layers across the two bundles in all 25 area dirs, all 68 in the landcover bundle. Across *all* upstream gpkg it is **68 of 91** (`aquatic_network.gpkg` holds 23) | ❌ **F5** |
| 7 | `01_stage.R:529` | "landcover bundle **today** (measured: 30 of 30)" | same as above | ❌ **F5** |
| 8 | `CLAUDE.md:185` | "measured on `larl_bt_ff04`: 10 of 10 assets byte-identical" | past-tense #74 provenance | ✅ history |
| 9 | `fp_gpkg.R:92-93` | "Measured **2026-10-14** over all 24 upstream area dirs: all 276 layers … (246 features + 30 attributes)" | now 25 area dirs / 478 layers / 68 attributes — but **date-qualified**, and `de8e473` adjudicated this class as history | ✅ (source of F5's un-dated copies) |
| 10 | `fp_gpkg.R:180` | "the same keep set in all 24 areas" | 25 area dirs; conclusion holds | ⚠️ minor, same class as #9 |
| 11 | `01_stage.R:298` | "Measured **2026-10-14**: 0 of 276 layers across all 24 upstream areas" | date-qualified; conclusion re-confirmed (nothing refused) | ✅ (left alone deliberately by `de8e473`) |
| 12 | `01_stage.R:554` | "`_by_blue_line_key`, on all 23 groups since the whole-network runs" | **23/23** | ✅ |
| 13 | `01_stage.R:572` | "0.73 MB against a 6.25 MB bundle for SLOC" | SLOC `transition_vector.gpkg` is in that range; relative claim holds | ✅ |
| 14 | `01_stage.R:115` | "100 rows of which 19 are unreachable" | RAT is 100 rows (10×10) | ✅ |
| 15 | `style_qml-write.py:22` | "Four per published item … which all 23 groups now carry" | `floodplain.gpkg` has exactly 4 layers on every item | ✅ |
| 16 | `scripts/README.md:441` | "`_by_blue_line_key`, on all 23 groups" | ✅ | ✅ |
| 17 | `test_pipeline.R:528` | "not over the 100-row scheme" | RAT 100 rows | ✅ (fixed in R2) |
| 18 | `02_raster_tag.py:216` | "a 2-row sidecar beside a 10-row embedded table" | 10-class table | ✅ (fixed in R2) |
| 19 | `item_validate.py:1757` | "`transition` 81 of 90 ship" | 90 pairs, 82 `render="false"` in the QML | ✅ (R2) |
| 20 | `item_validate.py:1284` | "the uniform 100-row scheme" | ✅ | ✅ |
| 21 | `item_validate.py:2071` | "reports **21 items** as unmarked-and-not-rebuilt" | **23** | ❌ **F6** |
| 22 | `item_validate.py:1322-1327` | "one 11552x14651 int32 band … 2.3 GB RSS … identical answer across **all four COGs** at 0.85 GB" | 19 of 23 items carry 4 COGs; the 4 annual-span items carry **8** | ⚠️ **F10** (dated one-off; "four" now describes 19/23) |
| 23 | `item_validate.py:1347` | "the **677 MB** this function exists to avoid" | all staged assets **1,338.3 MB** | ❌ **F3** |
| 24 | `item_validate.py:2013`, `:2091`, `:2123` | "`~670 MB` re-read, ~2.5s" | **1,338.3 MB / 1,276.3 MiB** | ❌ **F3** |
| 25 | `prov_fields-check.py:11` | "the COG-tag arms sit behind **~670 MB**" | as above | ❌ **F3** |
| 26 | `year_sets-check.py:9` | "reached only after **~670 MB** of real hashing" | as above | ❌ **F3** |
| 27 | `catalogue_release.sh:18` | "`--only` re-hashes **~640 MB** of assets" | per-item now 16–152 MB; full build 1,338 MB | ❌ **F3** |
| 28 | `catalogue_release.sh:363` | "rather than after **700 MB** is up" | 1,338 MB + JSON | ❌ **F3** |
| 29 | `catalogue_release.sh:1111` | "read the build TWICE per file (**~226 MB** of …)" | scaled by the same factor | ❌ **F3** |
| 30 | `item_register.sh:37` | "Items here are **3-9 MB** each (**~94 MB** total)" | **5.62–18.25 MB** each, **252.6 MB** total | ❌ **F3** |
| 31 | `item_create.py:726` | "the items are **3-9 MB** each" | as above | ❌ **F3** |
| 32 | `catalogue_release.sh:525` | "the body, which is **4-9 MB** per item (`bulk_co_ff04.json` is 8,587,448 bytes, measured)" | `bulk_all_ff04.json` is **17,835,259 B**; max is `fran_all_ff04.json` **18,245,948 B** | ❌ **F3** (id is a past-tense citation and fine; the range is not) |
| 33 | `item_create.py:733-734` | "Flood factor is discrete (2/4/6) and **today only 4 and 6 exist**" | built `collection.json` summary is `flood_factor: [4]`; all 23 items ff04 | ❌ **F4** |
| 34 | `catalogue_release.sh:686` | "`$news` is the whole file (**39,573 B** measured, against a 64 KiB pipe buffer)" | **47,156 B** | ❌ **F8** |
| 35 | `catalogue_release.sh:726-727` | "NEWS.md is **39,573 B today** and its top section **29,165 B** … **2.2x of margin**" | **47,156 B** / **36,129 B** / **1.8x** | ❌ **F8** |
| 36 | `catalogue_release.sh:59-61` | "23 of 23, measured on the build this release publishes … It **was** 21 of 23 at v1.1.0" | floor 23 confirmed (R1/R2) | ✅ |
| 37 | `catalogue_release.sh:83` | "23 ids over 22 groups — MORR is the two-for-one case" | the live set is 23 ids over 22 wsgs | ✅ |
| 38 | `catalogue_release.sh:210` | "~34 s and ~34 MB for 17 items (**measured when the collection held 17**)" | self-qualified | ✅ |
| 39 | `catalogue_release.sh:596` | "the conversion **was** half done: a full rebuild **staged** 10 of 23 groups" | past tense + context, `de8e473` | ✅ |
| 40 | `test_pipeline.R:27` | "**measured 2026-10-14**, 13 of the 23 rostered groups …" | date-qualified, `de8e473` | ✅ |
| 41 | `test_pipeline.R:323-326` | "would silently replace the raster and still leave **7 assets**" | items carry **10** assets (19 of 23) or **14** (4 of 23); the counterfactual leaves 9 or 13 | ❌ **F7** |
| 42 | `gpkg_determinism-check.R:98` | "churns **46 published checksums** (two assets x 23 items)" | 2 × 23 = 46 | ✅ |
| 43 | `readme_functions.R:8` | "the **45 MB** of item geometry the call returns" | reads the live API (still the 23 species items); moves at the release | ⚠️ unverifiable pre-release |
| 44 | `readme_functions.R:330` | "the unsimplified **22 groups** are ~6 MB" | the API serves 22 wsgs today and **23** after the release — and this function next runs at release step 6 | ❌ **F9** |
| 45 | `readme_functions.R:547` | "1.4 million vertices … 11 MB of GeoJSON" | live-API derived; moves at the release | ⚠️ unverifiable pre-release |
| 46 | `scripts/README.md:275` | "`Rscript scripts/test_pipeline.R` # **defaults to UFRA**" | `test_pipeline.R:32` default is **`bulk`** (since `c6df555`, #76) | ❌ **F2** |
| 47 | `scripts/README.md:277` | "`WSG=bulk` … # **whole-network group**: species `all`, 7-year span" | every group is whole-network now; `bulk` IS the default; the 7-year span is the only distinguishing property (confirmed: bulk 2017–2023 annual, 4 of 23 items annual) | ⚠️ **F2** (same block) |
| 48 | `scripts/README.md:504` | "all 24 layers of a multi-target group opened plain" | past tense, "this is how the #46 styles **were** verified" | ✅ history |
| 49 | `scripts/README.md:570` | "`AREA=<wsg>` … default `bulk` … the pin is `ufra_ch_ff04`'s and now skips permanently" | `stage_years-check.R:72` default is `bulk` ✅; the permanent skip is correct | ✅ |
| 50 | `scripts/README.md:425` | "Measured on `sloc_bt_ff04`: unpinned … pinned, both `ea0ac66f…`" | past-tense provenance of a measurement | ✅ history |
| 51 | `scripts/README.md:474` | "Three properties, measured on `kotl_bt_ff04`" | past-tense provenance | ✅ history |
| 52 | `scripts/README.md:15`, `:358`, `prov_census-measure.R:17`, `scripts/README.md:22` | "`$FLOODPLAINS_DATA` (~900 MB)" | upstream tree; not re-measured here, out of scope of the cutover | ⚠️ unchecked |
| 53 | `prov_fields-check.py:192-203`, `:432` | fixture 18 / 5 / 2, "25 items and 23 traced" | agrees with the build (R2); 49 assertions pass | ✅ |
| 54 | `fp_provenance.R:274`, `:291` | "measured, **2026-10-14** over all 22 areas"; "all 104 sections" | date-qualified | ✅ history |
| 55 | `03_cog.py:56` | "Outputs are 1-3 MB today, far under the 4 GB classic-TIFF ceiling" | largest classified COG **2.0 MB**, largest transition **3.6 MB** | ⚠️ 3.6 > 3; conclusion unaffected |
| 56 | `catalogue_release-check.sh:539`, `:804`, `:1006`, `:1018`, `:1023` | self-test internals (17 items gone, 2 assets/4 properties, 72 of 227, 40 of 77, 29–61 of 73) | properties of the check script's own fixtures and of its own line coverage, not of the catalogue | ✅ out of scope |

**Count: 56 quantity claims classified. 30 correct, 11 history/out-of-scope, 5 unverifiable
or minor, 10 wrong (F1 ×2, F3 ×9 lines, F4, F5 ×2, F6, F7, F8 ×2, F9, F2 ×2).**

### 2.3 Every item id named in a tracked file

Mechanically extracted (`\b[a-z]{4}_[a-z]{2,4}_ff[0-9]{2}\b`) over the 33 files; 37 distinct
ids. Synthetic fixture ids (`aaaa_ch_ff04`, `aaaa_co_ff04`, `aaaa_st_ff04`, `bbbb_ch_ff04`,
`cccc_ch_ff04`, `dddd_ch_ff04`, `zzzz_ch_ff04`, `none_ch_ff04` — 283 occurrences in
`catalogue_release-check.sh` and `prov_fields-check.py`) are self-contained and excluded.

| Id | In the build? | Where named | Verdict |
|---|---|---|---|
| `bulk_all_ff04` | ✅ | `CLAUDE.md:137`, `catalogue_release.sh:7,56,721`, `fp_gpkg.R:87`, `README.md:225,420,471` | ✅ |
| `sloc_all_ff04` | ✅ | `gpkg_determinism-check.R:32`, `style_determinism-check.py:58,60`, `README.md:569` | ✅ |
| `morr_all_ff04` | ✅ | `gpkg_determinism-check.R:14`, `style_determinism-check.py:19` | ✅ |
| `kisp_all_ff04` | ✅ | `item_validate.py:999` | ✅ |
| `kotl_all_ff04` | ✅ | `README.Rmd:210` | ✅ (fixed by `de8e473` — the one that would have shipped a 404 worked example) |
| the 23 retired ids | ❌ (all retired) | `catalogue_release.sh:86` (the literal) | ✅ correct by construction |
| `bulk_co_ff04` | ❌ | `catalogue_release.sh:57` (past tense), `:525` (measurement provenance) | ✅ history — but see F3 for the byte figure beside it |
| `kotl_bt_ff04` | ❌ | `README.md:474` ("measured on") | ✅ history |
| `larl_bt_ff04` | ❌ | `CLAUDE.md:185`, `catalogue_release.sh:223` (both "measured on") | ✅ history |
| `sloc_bt_ff04` | ❌ | `README.md:425` ("Measured on") | ✅ history |
| `ufra_ch_ff04` | ❌ | `README.md:570`, `stage_years-check.R:228,236,271,274` (the permanently-skipping pin) | ✅ — the skip is deliberate and documented |
| `mcgr_ch_ff04`, `pine_bt_ff04` | ❌ | `CLAUDE.md:340`, `item_create.py:85`, `item_validate.py:260` (all "no longer exist in any build") | ✅ |
| `morr_co_ff04`, `morr_ch_ff06` | ❌ | `CLAUDE.md:104`, `01_stage.R:234` (counterfactual), `test_pipeline.R:583` ("This **was**") | ✅ |

**No stale id found. This axis is fully clean** — `de8e473`'s enumeration closed it.

---

## 3. Findings

### F1 — **[bug]** `CLAUDE.md:151-152` + `scripts/README.md:62-63`: round 2's fix substituted the three-bundle total into a two-bundle comparison, in both copies

The text now reads:

> `CLAUDE.md:151` — *Measured on the v2.0.0 build: 1602.6 -> 1124.6 MB over the 23 rostered
> groups, MORR -67% (110.9 -> 36.4 MB).*
>
> `scripts/README.md:61-63` — *The **two GeoPackage bundles** are the bulk of it: 1124.6 MB
> across the 23 rostered groups, measured on the v2.0.0 build, down 478 MB from the
> whole-file copies #80 retired (1602.6 MB).*

Measured now, per group, over `floodplain_landcover.gpkg` + `floodplain.gpkg`:

```
upstream (the whole-file copies #80 retired)  1602.6 MiB   <- matches the stated figure exactly
staged    (what this build publishes)         1035.3 MiB   <- stated as 1124.6
delta                                          567.3 MiB   <- stated as 478
MORR                                   110.9 -> 34.0 MiB   -69%   <- stated as -> 36.4, -67%
```

`1124.6 MiB` is **exactly** the total of all **three** staged GeoPackages
(1035.3 + 89.3 for `transition_vector.gpkg`). `36.4 MiB` is **exactly** MORR's three. The
substitution is arithmetically verifiable, not a rounding question.

Three things make this worth a finding rather than a nit:

1. **It is a defect inside the previous round's fix.** Review-round2.md §3 printed
   `1035.3` and `34.0 (-69%)`. Commit `d4d97e2` wrote `1124.6` and `36.4 (-67%)` into both
   copies. Nothing in the tree could have caught it.
2. **The `scripts/README.md` copy states its own scope and contradicts it** — the sentence
   says "the **two** GeoPackage bundles are the bulk of it: 1124.6 MB", and the two bundles
   are 1035.3.
3. **The comparison is unsound as constructed, not just mis-measured.**
   `transition_vector.gpkg` was never a whole-file copy — it has always been written here —
   so putting it on the "after" side of a #80 before/after and not the "before" side
   **understates #80's saving by 89.3 MiB**. Even a correct three-bundle "after" would be the
   wrong number for that sentence.

Also: the unit label is wrong in both copies. `1602.6` matches **MiB** exactly (the decimal-MB
figure is 1680.4), so every number in this family is MiB written as MB.

**Fix:** `1602.6 -> 1035.3 MiB`, down `567.3 MiB`, `MORR -69% (110.9 -> 34.0 MiB)`, in both
files, and say "two bundles" where the number is a two-bundle number.

---

### F2 — **[bug]** `scripts/README.md:275` says `test_pipeline.R` "defaults to UFRA"; it defaults to `bulk`. This diff restated the same wrong claim in a third file.

```
scripts/README.md:275   Rscript scripts/test_pipeline.R            # defaults to UFRA
scripts/test_pipeline.R:32   wsg <- tolower(Sys.getenv("WSG", unset = "bulk"))
scripts/stage_years-check.R:72   AREA <- tolower(Sys.getenv("AREA", unset = "bulk"))
```

The defaults moved to `bulk` in `c6df555` ("Move the smoke test and the year-set check off a
group that cannot stage (#76)"). The README copy was never updated — an unpinned pair that
has been disagreeing since #76.

**What this branch added:** `gpkg_determinism-check.R:27-30`, new in this diff, now says

> *The failure mode the note existed for is the one the `ufra` defaults in test_pipeline.R
> and stage_years-check.R **hit**: an id nothing stages any more …*

The comment it replaced had this right, in the past tense:

> *unlike the `ufra` defaults test_pipeline.R and stage_years-check.R **carried**, which
> silently stopped staging at all (#76)*

The rewrite turned a correct historical note into a false present-tense claim about two
scripts' current defaults — and `README.md:275` is the only place in the tree that would have
told the author so. That is mechanism (A) with the propagation running the wrong way: the
unpinned stale copy fed the new one.

Same block, one line down: `README.md:277`'s `WSG=bulk … # whole-network group` no longer
distinguishes anything (all 23 are whole-network). Its real distinguishing property, the
7-year span, is already in the comment and is correct (verified: `bulk` is 2017–2023 annual,
4 of 23 items are).

**Fix:** README:275 → `# defaults to BULK`; restore the past tense in
`gpkg_determinism-check.R:29`; reword README:277 around the span rather than "whole-network".

---

### F3 — **[fragile]** the asset-size family is stale by ~2x across nine lines in six files, and the copies never agreed with each other

| Stated | Where | Measured now |
|---|---|---|
| `~670 MB` re-read | `item_validate.py:2013, 2091, 2123`; `prov_fields-check.py:11`; `year_sets-check.py:9` | **1,338.3 MB / 1,276.3 MiB** (all staged asset bytes) |
| `677 MB` | `item_validate.py:1347` | as above |
| `~640 MB` | `catalogue_release.sh:18` | as above |
| `700 MB` | `catalogue_release.sh:363` | as above |
| `~226 MB` | `catalogue_release.sh:1111` | scaled by the same factor |
| `3-9 MB each (~94 MB total)` | `item_register.sh:37` | **5.62–18.25 MB each, 252.6 MB total** |
| `3-9 MB each` | `item_create.py:726` | as above |
| `4-9 MB per item (bulk_co_ff04.json is 8,587,448 bytes)` | `catalogue_release.sh:525` | `bulk_all_ff04.json` **17,835,259 B**; largest `fran_all_ff04.json` **18,245,948 B** |

Note the three copies disagree *with each other* (640 / 670 / 700 for the same quantity, 3-9
vs 4-9 for the other), which is the tell that no two were ever taken together.

These are comments, so nothing fails — but two of them are load-bearing *arguments*:

- `item_register.sh:37` justifies compacting to a local temp file and asserting the line count
  because the transfer is big enough that correctness should not be assumed. The transfer is
  now **253 MB, not 94** — the argument got stronger and the number says otherwise.
- `catalogue_release.sh:525` justifies "only now the body" for a `curl -sf --max-time 60`
  read of an item document it sizes at 4–9 MB. The largest is **18.2 MB**. Still fine on a
  normal link; the sizing claim beside the timeout is 2x off.

---

### F4 — **[fragile]** `scripts/item_create.py:733-734`: "today only 4 and 6 exist" — only 4 does

```python
# A Set of Values, not a Range Object. Flood factor is discrete (2/4/6) and today
# only 4 and 6 exist — a range would advertise flood_factor=5 as available, and a
```

The built `collection.json` summary is `"flood_factor": [4]`, and all 23 items are ff04
(`morr_ch_ff06` was the only ff06 and is in `RETIRED_ITEMS`). The *reasoning* (a Set, not a
Range) is untouched; the stated fact is false.

This matters more than an ordinary stale count because it is **the last place in the tree that
still describes the collection as mixing flood factors.** `CLAUDE.md:99-101` and
`readme_functions.R:156-160` were both rewritten for exactly this in the branch's earlier
commits; this one sits in a file the diff edits and was missed.

---

### F5 — **[fragile]** "30 of 30" aspatial layers, in two unpinned present-tense copies, is now 68 — and under one reading is false, not merely stale

```
CLAUDE.md:171     Every `attributes` layer upstream is in the landcover bundle today
                  (30 of 30, measured)
01_stage.R:529    Every `attributes` layer upstream is in the landcover bundle today
                  (measured: 30 of 30)
```

Measured now over all 25 upstream area dirs:

- within the two bundles this repo reads: **68 attributes layers, 68 in
  `floodplain_landcover.gpkg`, 0 in `floodplain.gpkg`** → the conclusion holds, the quantity
  doubled.
- across *all* upstream GeoPackages, which is what the word "upstream" literally says:
  **68 of 91** — `aquatic_network.gpkg` carries 23 more. Under that reading the sentence is
  false.

Its source, `fp_gpkg.R:92-93`, carries the date (`Measured 2026-10-14 … 246 features + 30
attributes`) and is therefore history by the convention `de8e473` applied. **The two copies
dropped the date and kept the number**, which is precisely the shape that makes a dated
measurement rot.

---

### F6 — **[fragile]** `scripts/item_validate.py:2071`: "reports 21 items as unmarked-and-not-rebuilt" — 23 now

In the deprecation ordering comment this diff rewrote. Single copy, no pin.

---

### F7 — **[fragile]** `scripts/test_pipeline.R:323-326`: "would silently replace the raster and still leave 7 assets"

Items carry **10** assets (19 of 23) or **14** (4 of 23, the annual-span groups). The
counterfactual the comment describes leaves 9 or 13. The assertion below it is correct and
unaffected.

---

### F8 — **[fragile]** `scripts/catalogue_release.sh:686` and `:726-727`: the NEWS.md byte figures went stale against this branch's own NEWS edit, and the margin they argue is now 1.8x

```
:686   $news is the whole file (39,573 B measured, against a 64 KiB pipe buffer)
:726   NEWS.md is 39,573 B today and its top section 29,165 B, so this is not reachable
:727   yet; it is 2.2x of margin on a file that only grows
```

Measured now: **NEWS.md is 47,156 B** and its top section **36,129 B**. Margin on the top
section is **1.81x**, not 2.2x; on the whole-file read at `:687` it is **1.39x**.

The figures were taken 2026-10-14 (`31ab7b0`) and the v2.0.0 entry this branch wrote added
**7,583 B to the same file** — so the number went stale inside the branch that wrote it. This
is the one stale quantity with an operational deadline rather than a documentation one: the
comment's own framing is "a file that only grows", and at v2.0.0's increment the whole-file
read is roughly two releases from 64 KiB. The mitigation (here-string, not pipe) is correct
and unchanged; on this machine's bash 3.2 a here-string is a temp file regardless, and bash
5.1+ is where the buffer bound applies.

---

### F9 — **[fragile]** `scripts/readme_functions.R:330`: "the unsimplified 22 groups are ~6 MB" becomes 23 at the step-6 re-render

The live API serves 22 watershed groups today (23 species items, MORR twice), so the number is
true at this instant and false the moment the release lands — which is also the next time this
function runs. Same class as `:8` ("45 MB of item geometry") and `:547` ("1.4 million
vertices … 11 MB"), both of which I could not measure pre-release and both of which move.

---

### F10 — **[fragile]** `scripts/item_validate.py:1327`: "identical answer across all four COGs"

True of 19 of 23 items; the four annual-span items carry 8 COGs (7 classified + 1 transition).
The memory measurement is a dated one-off and the conclusion is unaffected; noting it because
it sits in the hunk this diff edited and belongs to the same enumeration.

---

## 4. Checked and clean (so a round 4 need not redo it)

- **Every pinned pair runs clean today**: `attribution_drift-check.py` (citation 770 chars,
  collection id and licence agree), `style_drift-check.py` (3 styles byte-identical, 10
  classes), `prov_fields-check.py` (**49 assertions, 0 failed**, including the three static
  roster-mirror arms and the four publish-side map copies).
- **`DEPRECATED_ITEMS` and `EXPECTED_DEPRECATED` are both `set()`** — the pair agrees.
- **Item-id axis fully clean** (§2.3): 37 distinct ids, every non-fixture retired id is a
  past-tense measurement citation, a counterfactual, or the literal itself.
- **`CLAUDE.md:145`'s "22 of the 23 groups … only DUNC clean" re-verified independently**:
  22 of 23 upstream groups carry a non-`all`-keyed layer in the two bundles; `dunc` is clean.
- **`CLAUDE.md:156`'s "all 23 items carry both"** re-verified: `patch_watercourse` 23/23,
  `composition` 23/23.
- **`_by_blue_line_key` on all 23 groups** re-verified; `floodplain.gpkg` has exactly 4 layers
  on every item, matching `style_qml-write.py`'s "Four per published item".
- **Year sets**: 19 items `(2017, 2020, 2023)`, 4 items annual 2017–2023 — the two sanctioned
  populations, `bulk` among the annual ones as `README.md:277` says.
- **Step 6 / step 7 as they now stand**: R2's two residuals are both closed — the recovery
  block reads the catalogue back and names `already unregistered` / `still served`, and the
  completion line counts `$to_delete` not `$n_retired`. `grep -c . || true` inside `$( )` is
  the safe form (it does not append a second line the way `|| echo 0` would). The
  `final_ids != local_ids` arm being unconditional is correct and documented.
- **No behavioural defect found in round 3.** Every finding above is prose, a comment, or a
  docstring. F8 is the only one with a forward-looking operational edge.

---

## 5. Is the candidate set fully covered?

**The enumeration is complete; the tree is not yet correct.**

- The **duplication axis** (§2.1) is enumerated mechanically — 177 shared string literals
  collapsed to 21 semantic groups, 12 pinned, 9 unpinned, with an agree/correct verdict on
  each. Nothing in that table sits above its source of truth *unexamined*; six of the nine
  unpinned groups are wrong and are findings F1–F3, F5, F8 and F2.
- The **quantity axis** (§2.2) is enumerated mechanically — 56 claims classified by regex over
  every tracked code and doc file, each measured against this build or dismissed with a
  reason. Ten are wrong.
- The **item-id axis** (§2.3) is enumerated and **clean**.

**But the termination test is not met**, and I want to be explicit rather than reassuring:
F1 is a defect *inside round 2's fix*, found by re-measuring rather than by reading, and
`code-check.md`'s rule is to keep going while a round finds one. The difference is that round 4
now has a table instead of a hunt — the remaining work is to apply F1–F10 and then
**re-measure, not re-read**, the ten corrected numbers, because the thing that failed here was
a re-measurement that looked right.

The durable gap underneath all of it: **this repo pins duplicated strings and pins nothing
duplicated as a number.** The six unpinned-and-wrong groups in §2.1 would all be caught by a
`quantities-check` sibling of `prov_census-measure.R` — a measurement script, not a gate —
printing the dozen figures the prose restates (two-bundle bytes, three-bundle bytes, total
asset bytes, item-JSON range and total, attributes-layer count, NEWS.md size, assets per item,
flood-factor set) so a release can set them the way it sets `PROVENANCE_FLOOR`. That is the
only thing that makes the next round's fix verifiable by something other than another human
measurement. Worth an issue regardless of what round 4 does.
