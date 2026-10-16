# Code-check round 2 — `95-qgis-cannot-find-the-embedded-styles-in`

Merge-base `4db1fa8`, HEAD `4ce4334`. Read in full: `04_gpkg_style.py`, `item_validate.py`,
`style_determinism-check.py`, `style_reach-check.py`, `test_pipeline.R`,
`gpkg_determinism-check.R`, `fp_gpkg.R`, `item_create.py`, plus `CLAUDE.md`, `NEWS.md`,
`scripts/README.md`, the README surfaces, and the un-diffed readers the change reaches
(`01_stage.R`, `run_pipeline.sh`, `catalogue_release.sh`, `catalogue_release-check.sh`,
`year_sets-check.py`).

## What was executed, not read

All on copies or read-only; `data/` untouched (mtimes unchanged, tree clean).

| probe | result |
|---|---|
| `style_reach-check.py` under the QGIS 4.2.1 bundle, per its docstring recipe | **PASS**, 9/9 layers, cold arm falls to `singleSymbol` @ 1.0 |
| `style_determinism-check.py` warm / `NO_PIN=1` cold | **PASS** both |
| `check_layer_styles()` on a copied tree, warm | `[]` |
| same, with the registration deleted from all three bundles | fires on all three, naming each |
| `style_gpkg()` on copies whose registration arrives as `data_type='features'` with a wrong `identifier` | repairs to `('layer_styles','attributes','layer_styles','',epoch,0)`, writes no style row for the style table, does not raise — round 1's finding 2 fix holds on all three bundles |
| `ogrinfo` (GDAL 3.13.0) on the registered copies | `layer_styles` listed in all three |
| same copies with the registration deleted | hidden in `floodplain_landcover.gpkg`, **still listed** in the other two — exactly the asymmetry the comments claim |
| `gpkg_spatial_ref_sys` / unregistered-table census on all three staged bundles | `srs_id 0` present in all three; zero unregistered non-system tables |
| producer bundles (`$FLOODPLAINS_DATA/sloc/*.gpkg`) | no `layer_styles` table, no such `gpkg_contents` row — the producer-side readers are correctly bounded |
| `item_validate.py` full run | only the pre-existing one-item-tree `ALLOWED_YEAR_SETS` artefact |

The fix itself is correct and verified in the real consumer. Nothing below is a crash, a
data-loss or a correctness defect in the published bytes.

## Mechanism

The prompt's candidates (a) and (b) are two faces of one cause, and (c) is the face round 1
left half-swept. The sharpest statement:

> **#95 converted a fact that was *structural* into a value this repo's own writer now
> writes, and simultaneously introduced the repo's first guards whose subject is
> *reachability* rather than *presence*.**

Before the branch, `layer_styles` had **no** `gpkg_contents` row. That single absence was
doing three jobs at once, silently:

1. it excluded the style table from every reader that filtered on `data_type` — **for free**,
   with no name anywhere (candidate **b**);
2. it made "the style is there" and "the style is reachable" indistinguishable, so every
   assertion about the former read as one about the latter (candidate **a**);
3. it kept the published *prose* true by accident on two of three bundles — "every layer
   carries wsg/species/scenario" was false wherever GDAL listed the table, which was already
   two bundles out of three (candidate **c**).

Registering the row retires all three accidents at once. So the branch owes three sweeps, not
one: make every exclusion explicit **and bounded to the staged side**; give every reachability
assertion a discriminator that the failure state cannot produce; and re-check every
**quantified claim and every provenance pointer** on every surface that carries it. Round 1
found one instance of (1) and one of (2) and the start of (3). Round 2's residue is entirely
in (3): the claim sweep ran over *links* and over three of five claim surfaces.

### Enumeration — every reader the mechanism reaches

Each row: does it sit **above** its source of truth (asks a question the artifact answers) or
**below** it (agrees with whatever the writer did)?

| # | reader | selection | side | verdict |
|---|---|---|---|---|
| 1 | `04_gpkg_style.py:170` `feature_layers()` | `data_type='features' AND table_name <> 'layer_styles'` | staged | **above** — round 1 fix; mutation-tested here on all three bundles, repairs rather than raising or styling the style table |
| 2 | `item_validate.py:1711` | `data_type='features'` | staged | **above** — the writer writes `attributes`; a drift to `features` is caught by the new registration arm (full equality on `[:5]`), and even if it were not, the layer would cascade as "no style row". Fails safe |
| 3 | `item_validate.py:1686` registration arm (new) | `WHERE table_name='layer_styles'`, full equality + pin | staged | **above** — the only absolute cover for the two bundles whose GDAL answer does not change. Mutation-tested: fires on all three |
| 4 | `test_pipeline.R:408` `keyed_layers()` | `IN ('features','attributes') AND <> 'layer_styles'` | staged | **above** — correct, and paired with row 5 |
| 5 | `test_pipeline.R:427` `st_layers()` positive arm (new) | name membership | staged | **above on `floodplain_landcover.gpkg` only**, and the comment says so verbatim. Measured here: de-registering leaves the table listed in the other two, so there the arm can only see "table absent", not "table unreachable". Correctly scoped, correctly documented, correctly backstopped by row 3 — not a finding |
| 6 | `test_pipeline.R:516` source layer set | `IN ('features','attributes')`, **no** name exclusion | producer | **above** — verified: producer bundles carry no style table. Correctly *not* excluded, because excluding here would weaken the loss arm |
| 7 | `gpkg_determinism-check.R:129` | `IN ('features','attributes') AND <> 'layer_styles'` | staged | **above** — needed: the list is fed to `gpkg_copy_layers()` against the **producer's** file, which would stop on `Couldn't fetch requested layer` |
| 8 | `fp_gpkg.R:113/136` `gpkg_layer_keys()` | `st_layers()` + all of `gpkg_contents` | producer | **above** — verified producer-only (its only callers are `01_stage.R:281` on `src_wsg` and, transitively, nothing staged). Comment rewritten correctly |
| 9 | `fp_gpkg.R:280` `gpkg_copy_layers()` read-back | `setequal(st_layers(dst), layers)` | fresh dst | **above** — `dst` is unlinked first, so no style table can appear on either side |
| 10 | `fp_gpkg.R:74` `gpkg_extract_layer()` | `layer %in% st_layers(src)` | staged (det-check arm 1) | **above** — membership test only; an extra listed layer is inert |
| 11 | `01_stage.R:506/541` aspatial + feature censuses | `data_type %in% ...` on producer keys | producer | **above** — runs before step 04 and on producer keys; an extra staged row cannot reach it |
| 12 | `01_stage.R:619` staged-floodplain floor | `setdiff(needed, st_layers())` | staged | **above** — one-directional; an extra listed layer is inert |
| 13 | `style_determinism-check.py:106` setup | drops the table **and** deletes the registration | staged copy | **above** — without the second statement arm 4 would have been exempted from the row it was added for |
| 14 | `style_reach-check.py:137` `feature_layers()` | `data_type='features'`, **no** name exclusion | staged | **below, but fails safe** — see finding 5 |
| 15 | `year_sets-check.py` / `catalogue_release-check.sh` | import only `ALLOWED_YEAR_SETS/check_checksums/sync_excludes`; `item_validate.py` is shimmed away | synthetic | unreachable — verified |

### Enumeration — every surface carrying the quantified claim or a provenance pointer

| surface | claim / pointer | swept? |
|---|---|---|
| `item_create.py:426` `floodplain_landcover` asset description (published) | "every **data** layer carries wsg/species/scenario" | ✓ corrected |
| `item_create.py:437-440` `floodplain` asset description (published) | "**read the layer list**… **Each layer** records its own flood factor in `scenario`" | ✗ **finding 3** |
| `item_create.py:452-457` `transition_vector` asset | no such claim | n/a |
| `README.Rmd` / `README.md` / `index.html` | "every **data** layer", plus an explicit `layer_styles` note | ✓ corrected, all three in step |
| `CLAUDE.md:148-154` | "Every **DATA** layer of all three" | ✓ corrected |
| `scripts/README.md:272` (describes the guard the branch changed) | "**every layer** of all three published GeoPackages carries wsg, species and scenario" | ✗ **finding 4** |
| `scripts/README.md:447` | "every layer of `floodplain.gpkg` — `<sp>_ff02/04/06`, plus `_by_blue_line_key`" | borderline: the enumeration bounds it. Not reported |
| `test_pipeline.R:354/363` comments | "every layer of BOTH / of every published GeoPackage" | describes the per-layer arm, whose own filter is three lines below. Not reported |
| private-repo pointers, **link** form (`<repo>#<N>`) in 6 files | ten of them | ✓ removed by `b0582fd` |
| private-repo pointers, **bare-name** form | one | ✗ **finding 1** |
| private-repo pointers, **commit-subject** form | one subject, two repos | ✗ **finding 2** |

## Findings

- **[security] `planning/active/progress.md:9`** — a tracked file in this **public** repo names
  a **private** sibling repo by name ("… searched the sibling packages for the same writer and
  found <private-repo>'s"). It is the same private repo whose `#N` citations this repo's open
  #86 tracks; `gh repo view` confirms it is PRIVATE and that this repo is PUBLIC. Commit
  `b0582fd` swept ten pointers across six files but scoped itself to the `<repo>#<N>` **link**
  form ("rather than linking them"), so this bare **name** survived in the one planning file
  the sweep did not revisit. `feature-workflow.md` forbids the pointer "not even as
  provenance", and the sentence loses nothing if it reads "found a sibling package's".

- **[security] commit `5586658`** — the subject line, "Tick Phase 6: <private-repo-A>#432 and
  <private-repo-B>#407 filed (#95)", names **both** private sibling repos with issue numbers,
  in a commit message in a public repo. `feature-workflow.md` lists commit messages among the
  public-repo surfaces the rule covers. The branch has **no upstream** (`git rev-parse @{u}`
  fails) and appears on no remote, so this is the last point at which it can be fixed without
  rewriting published history; after the first push the convention treats it as immutable.
  Decide now rather than discover it on the PR.

- **[fragile] `scripts/item_create.py:437-440`** — the **published** `floodplain` asset
  description tells a consumer to "read the layer list rather than assuming three" and asserts
  "Each layer records its own flood factor in `scenario`". Measured here with
  `ogrinfo -so` on the staged bundle, the layer list of `floodplain.gpkg` is five entries, the
  fifth being `layer_styles`, which has no `scenario` column at all. This is the identical
  claim the branch corrected ten lines above in the sibling asset — with a comment explaining
  exactly why ("GDAL lists the `layer_styles` table beside the real ones … the unqualified
  claim was already visibly false to anyone running `ogrinfo`") — and the correction stopped
  at one of the two assets that make it, while the sentence that *instructs* the consumer to
  enumerate layers is the one left uncorrected. It ships in every item JSON.

- **[fragile] `scripts/README.md:272`** — "It also asserts the attribute contract: every layer
  of all three published GeoPackages carries `wsg`, `species` and `scenario` matching the
  item". The branch changed exactly the guard this sentence describes: `keyed_layers()` now
  excludes `layer_styles` by name, so the arm covers every *data* layer. Same class as round
  1's finding 4 — a sentence claiming a scope the code does not have — on the file the claim
  sweep did not reach. The sibling sentence in `CLAUDE.md` was corrected.

- **[fragile] `scripts/style_reach-check.py:137-144, 199, 231, 238`** — `feature_layers()` here
  selects on `data_type='features'` with no name exclusion: the same reader shape round 1 fixed
  in `04_gpkg_style.py`. On a file whose `layer_styles` registration arrives as `features`,
  `style_kind()` (line 149) hits the landcover map's `None` branch and raises `SystemExit`
  **from inside the warm loop**, discarding every failure already collected — including the
  two static literal-drift findings gathered before QGIS was even initialised. That is round
  1's finding 3 one axis over, in the same file. It fails *safe* on the verdict (SystemExit
  still exits non-zero, and `app.exitQgis()` is in the `finally`), and it is only reachable on
  a hand-edited file now that `04_gpkg_style.py` repairs that registration, so this is a
  message-quality defect rather than a pass-when-broken one. Cheapest fix: add
  `AND table_name <> 'layer_styles'` to the query, matching the writer whose module this file
  already imports.

## Checked and clean — not findings

- **The registration itself.** Correct in all three bundles, pinned, `srs_id 0` backed by a
  real `gpkg_spatial_ref_sys` row in all three, no unregistered non-system tables left behind,
  no triggers, no `gpkg_ogr_contents` row, `ogrinfo` silent. Nothing in the pipeline opens a
  styled GeoPackage in GDAL **update** mode after step 04, so GDAL cannot add a
  `gpkg_ogr_contents` row and move the bytes between styling and `item_create.py`'s hashing.
- **Determinism.** Warm match / cold differ on all three bundles, and a re-run is a true
  no-op; separate comparison of rows and registration means the #95 upgrade path (rows
  already right, registration missing) is also a no-op for the rows.
- **Consumer-visible layer count.** Unchanged for `floodplain.gpkg` and
  `transition_vector.gpkg` — measured, GDAL listed `layer_styles` in both *before* the
  registration too. Only the landcover bundle goes 6 → 7, and the README/landing page now say
  so.
- **No new cross-repo citations** of any kind in the branch's added lines (checked
  mechanically over the whole diff); the only `#N` tokens added are this repo's own and three
  hex colours that look like them.
- **Release bookkeeping.** `task_plan.md:204-205` records re-taking `PROVENANCE_FLOOR` and
  `PROV_CENSUS` on the rebuild as the operator's step, which is where `CLAUDE.md` puts it.
- `item_validate.py`'s `FP_GPKG_R` is `__file__`-relative, so the release gate reads the pin
  regardless of cwd; `gpkg_epoch()` is read once per run, not per file.
- Both statically-tied literals in `style_reach-check.py` resolve (`ast.walk` reaches
  `EXPECT_RENDERER` inside `check_layer_styles` and `EXPECTED_STYLE_CATEGORIES` at module
  level, one literal assignment each) and compared equal on the live run.
- `expected_opacity()` finds exactly one distinct value (`0.5`) across all three committed
  QMLs, and the live QGIS run proved it discriminates: de-registered falls to `1.0`.
