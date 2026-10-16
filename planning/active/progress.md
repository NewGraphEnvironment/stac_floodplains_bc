# Progress — QGIS cannot find the embedded styles in floodplain_landcover.gpkg (#95)

## Session 2026-10-16

- Plan-mode exploration: read `04_gpkg_style.py`, `style_determinism-check.py`,
  `item_validate.py::check_layer_styles`, `test_pipeline.R`'s layer arms, `fp_gpkg.R`,
  `run_pipeline.sh`, the style sections of `scripts/README.md`; probed the staged v2.0.0
  tree read-only for the `gpkg_contents` / `gpkg_spatial_ref_sys` shape; searched the
  sibling packages for the same writer and found one carrying it.
- Phases approved by user, with three scope decisions: ship the QGIS reachability check
  in this PR; file an issue in the conventions repo and correct its spatial
  code-check convention there; land code + a
  `v2.0.1` NEWS entry here and leave the rebuild, tag and release to the operator.
- Created branch `95-qgis-cannot-find-the-embedded-styles-in` off main (at `4db1fa8`).
- Scaffolded PWF baseline from issue #95 with the approved phases.
- Plan review (Plan agent, unnamed) landed 20 findings; three blockers and the mechanism
  correction verified here before acting:
  - **GDAL, not QGIS.** Reproduced the `LIST_ALL_TABLES=AUTO` heuristic on GDAL 3.8.5
    (`sf`), 3.12.4 (QGIS 4.2.1's own `ogrinfo`) and 3.13.0 (homebrew), and the
    registration fixing it on a copy. Issue body needs correcting.
  - `gpkg_determinism-check.R:121` takes its layer set from the **staged** file and copies
    from the **producer's** — a live break the first inventory missed. Confirmed by reading.
  - A bare registration INSERT raises on the regenerated-style path; the write must be
    conditional.
  - `01_stage.R:85-86` wipes `data/stac` unconditionally — witness captured first.
  Not taken: the review's suggestion to drop the committed QGIS check in favour of the
  GDAL-level arm alone. Both ship: GDAL listing the table is necessary but not sufficient
  for QGIS to apply the style (the NULL `f_table_schema` trap is the proof).
- Revised task_plan.md and findings.md pre-baseline, which is where that is free.
- Next: Phase 1.

### Phases 1-3 — the fix and the guards

Writer registers `layer_styles` in all three bundles, pinned; `item_validate.py` asserts the
row; `test_pipeline.R` asserts GDAL still LISTS it; the two staged-side `gpkg_contents`
readers exclude it by name.

Mutation table — every new guard restored to red on purpose:

| mutation | guard that fired |
|---|---|
| registration disabled (`if False`) | `item_validate.py`: **69 of 69** problems on the published tree (23 x 3), nothing else; `style_determinism-check.py` arm 4; `test_pipeline.R` names `floodplain_landcover.gpkg` |
| registration written with a wall-clock `last_change` | determinism arms 1-3 (digests differ) **and** arm 4 by name |
| bare `INSERT` instead of UPDATE-or-INSERT | determinism arm 5: `UNIQUE constraint failed: gpkg_contents.identifier` |
| `INSERT OR REPLACE` | **nothing** — see below |

Two measurements that corrected the design:

- The conflict arm's obvious setup **cannot fail**. Dropping the style table while keeping
  its registration leaves the registration comparing equal, so the writer skips that branch
  and a bare INSERT passes. The arm had to be written over a registration that *differs*
  (QGIS's own wall-clock row, or a changed `GPKG_EPOCH`), which is the path that reaches it.
- `INSERT OR REPLACE` is wrong but **not** caught here, so the comment says so rather than
  implying a guard: measured, REPLACE moves the row's rowid 7 -> 8 and the file's sha256
  with it, and the determinism check byte-compares only the fresh-build path, where both
  spellings behave as INSERT.

The writer's summary line printed "registered in gpkg_contents" on a run with the
registration disabled, so it now reads the row back and refuses on any file that ends
without one.

Verified, in order:

- QGIS 4.2.1 on the published v2.0.0 bytes vs the fix, same session, `sloc_all_ff04`:
  before, the four landcover layers come back `singleSymbol` and the other five are correct;
  after, all nine carry the expected renderer (10 and 91 categories); the de-registered copy
  falls back to `singleSymbol`.
- `item_validate.py` full tree, pre-change: PASS — which is the point. Every style arm it
  already had read the row it wrote, so none of them could see this.
- `style_determinism-check.py` warm + cold: PASS. `gpkg_determinism-check.R` all three arms:
  PASS.
- `WSG=sloc Rscript scripts/test_pipeline.R`: PASS end to end, twice, with the three bundles
  **byte-identical across the two independent builds** — so the registration does not make a
  fresh build non-reproducible. (The determinism check cannot show this: both its arms go
  through the same setup.)

### Phase 4 — the QGIS witness

`scripts/style_reach-check.py`, run under the QGIS bundle's own python3.12. Verified:

- On the published v2.0.0 bytes: 5 problems — the four landcover layers `singleSymbol`, plus
  the cold arm correctly reporting it could not set up its own state (0 registration rows to
  remove on a pre-fix file).
- On the rebuilt tree: PASS, all 9 layers, and the cold arm's de-registered copy falling back
  to `singleSymbol`.
- Under `uv run`: refuses by name, pointing at the recipe.
- The static arm against `item_validate.py`'s copies fires on drift (changed 91 -> 90 and it
  named both the drift and the two layers). Non-vacuity is structural: `literal()` raises if
  it finds nothing, and `EXPECT_RENDERER` is defined INSIDE `check_layer_styles`, so the
  reader walks the whole AST rather than the module body.

The cold arm is landcover-only on purpose. De-registering either other bundle returns it to a
state where AUTO still lists the table and QGIS still finds the style, so a per-bundle cold arm
would report two false failures.

### Phase 5 — prose and NEWS

The retired claim was live in seven tracked places, not the three the first pass found:
`04_gpkg_style.py` (two sentences, one of them the exact premise that shipped this),
`fp_gpkg.R` (twice), `test_pipeline.R`, `scripts/README.md`, `CLAUDE.md` (twice).

Also corrected: "every layer carries `wsg`/`species`/`scenario`" to "every **data** layer", in
`item_create.py`'s **published** asset description, `CLAUDE.md`, `README.Rmd`, `README.md` and
`index.html`. It was already false on two bundles, because GDAL lists `layer_styles` beside
the real layers and it has never carried a key. The two generated files are edited in place
rather than re-rendered: a render is release step 6, reads the live API, and would move the
figures.

`NEWS.md` gains the `v2.0.1` entry. Its date is the day it was written — bump it if the
release slips.

### Phase 6 — cross-repo

- **An issue filed in the conventions repo**, and fixed there on its own branch and PR, not
  merged. Both adjacent paragraphs of its spatial code-check convention were wrong, not one:
  the bullet claiming GDAL lists non-spatial tables "with or without a `gpkg_contents` row",
  and the paragraph telling every repo the registration is unnecessary. The second is the
  sentence that shipped #95. The generated index in each repo's CLAUDE.md gains a row on the
  next `/claude-md-propagate`, which is deliberately not run from here.
- **An issue filed in the field-data package** as a defect report, not a feature request: it
  writes `layer_styles` unregistered and separately registers a tracking table as
  `attributes`, and under its single multi-layer layout both land in one file beside styled
  feature layers. Not reproduced there — its shipped templates carry registered aspatial
  tables but no style table yet, so the state only exists in a built project, and that package
  owns the QGIS oracle that can settle it. The issue also answers the "does the verb belong
  there" question: probably yes, and this repo's hand-run script is the working recipe if it
  does.
