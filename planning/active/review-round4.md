# Code-check round 4 — the round-3 fixes

Scope: commit `6bf11db` only, narrowly. Three substantive files (`scripts/04_gpkg_style.py`,
`scripts/item_validate.py`, `scripts/item_create.py`) plus `CLAUDE.md` / `NEWS.md` prose.
Everything below was measured on copies in a scratch tree; `data/` and the repo's scripts were
not touched, and `test_pipeline.R` / `run_pipeline.sh` were not run.

Verdict: the round-3 closure **holds on its own terms**. The registration read-back is genuinely
independent of `intended_registration()`, the indices are right, the absent-row path short-circuits
correctly, and no realistic correct file is falsely refused. The `item_validate.py` exclusion breaks
no arm and makes none vacuous. Three residual findings, all fragile rather than bug — two in the
new refusal/read-back, one a stale copy of the very claim this commit corrected.

## Findings

- **[fragile]** `scripts/04_gpkg_style.py:347-355` — the rewritten refusal message enumerates
  **three** conditions ("the row is absent, or it is not `attributes`, or its `last_change` is not
  `<epoch>`") but the read-back at `:298-299` has **four** disjuncts: `bool(back)`,
  `back == want_gc`, `back[1] == "attributes"`, `back[4] == epoch`. The `back == want_gc` arm covers
  `identifier`, `description` and `srs_id`, and the comment directly above it says that arm exists
  precisely for "a failed UPDATE, a trigger, another writer".

  Measured (scenario G): an `AFTER INSERT` trigger on `gpkg_contents` that rewrites `identifier`
  to `'meddled'` on `floodplain.gpkg` gives `registered and pinned in 2 of 3` and the refusal —
  correctly — but the row it refused is
  `layer_styles|attributes|meddled||2000-01-01T00:00:00.000Z|0`. All three conditions the message
  names are **false of the file**: the row is present, it *is* `attributes`, and its `last_change`
  *is* the pin. Nothing in the message points at `identifier`. This is the same shape round 1
  reported against the old summary line ("it printed 'registered in gpkg_contents' on a run with
  the registration disabled") — the message states what the author expected the failure to be
  rather than what the code tested — now one level down, in the message that replaced it.

  Second half of the same line: the refusal names a **count** and no file. On the 23-item build
  that is `1 of 69` with no identity, and `style_gpkg()` already knows `path`. Cheapest fix is to
  have `style_gpkg()` return the failing column(s) (or `(path, back, want_gc)`) and let `main()`
  print them, which also removes the need for the message to restate the predicate at all.

- **[fragile]** `scripts/04_gpkg_style.py:298-299` — `back[1]` and `back[4]` are positional indices
  into `_GC_COLS` (`:104`), and nothing ties the two together. The order is correct today
  (`table_name,data_type,identifier,description,last_change,srs_id` → 1 = `data_type`,
  4 = `last_change`; checked). The residual is that a **consistent and correct** edit to `_GC_COLS`
  silently turns the guard into a false refusal of a perfectly good file.

  Measured (scenario D): `_GC_COLS` reordered to put `srs_id` before `last_change`, with
  `intended_registration()` (`:107-108`) and the `UPDATE` column list (`:267-270`) updated to match —
  i.e. a refactor that is internally consistent and writes exactly the right row. Over a
  de-registered tree the writer wrote
  `layer_styles|attributes|layer_styles||2000-01-01T00:00:00.000Z|0` into all three bundles — correct
  and reachable — and then reported `0 of 3` and aborted the build, with the message asserting that
  `last_change` is not the pin when it is. `_GC_COLS`'s order is already load-bearing for the
  `UPDATE`'s `(*want_gc[1:], want_gc[0])`, so this is a third consumer of an order that is written
  down in one string and read positionally in three places.

  It fails closed, so no bad bytes ship; the cost is a build that cannot be made to pass and a
  diagnostic that points at the wrong column. A one-line assertion is enough:
  `assert _GC_COLS.split(",")[1] == '"data_type"' and _GC_COLS.split(",")[4] == '"last_change"'`,
  or read the index by name.

- **[fragile]** `NEWS.md:104-107` — the stale copy of the claim this commit fixed in `CLAUDE.md`.
  `CLAUDE.md` now says **five** staged-side readers exclude `layer_styles` by name and names all
  five. The published release note still reads:

  > The staged-side readers of `gpkg_contents` — `test_pipeline.R` and `gpkg_determinism-check.R` —
  > exclude `layer_styles` by name

  The em-dash list reads as exhaustive and names two of five. This commit edited the bullet
  immediately below it, in the same hunk, so the stale copy was in the diff's own context. By the
  commit message's own account ("four of five excluding is how the second instance arrived"), a
  reader who learns from `NEWS.md` that there are two such readers is in exactly the state that
  produced rounds 1 and 2's defects — and `NEWS.md` is the copy that ships. Same mechanism as the
  `floodplain` asset description this commit fixed: one fact in two documents, corrected in one.

  (Lesser, same bullet region, `NEWS.md:98-100`: "`gpkg_contents.table_name` being the PRIMARY KEY
  makes an unconditional INSERT raise". It does raise, but `04_gpkg_style.py:252-257` records the
  measured constraint as `UNIQUE constraint failed: gpkg_contents.identifier`. The substance is
  right; the attribution is not the measured one.)

## Mutations run, and what each produced

All on copies of `data/stac/sloc_all_ff04` in a scratch tree, with a scratch copy of the script
whose `REPO` resolves to the scratch tree. GDAL 3.13.0 (homebrew) for the `ogrinfo` arms;
`check_layer_styles` driven by importing `scripts/item_validate.py` under `uv run` with a scratch
`--base`.

### `04_gpkg_style.py` registration read-back

| # | mutation | result |
|---|---|---|
| control | unmutated writer over an already-correct tree | `3 of 3`, exit 0, all three digests **unchanged** (true no-op). Rows: `layer_styles\|attributes\|layer_styles\|\|<epoch>\|0`, `typeof(srs_id)=integer`, `typeof(last_change)=text` |
| A | `intended_registration()` emits `data_type='features'`, warm tree | `0 of 3`, refusal, exit 1. **The literal arm is what fires** — `back == want_gc` passes, since `want_gc` carries `features` too. Round 3's claim reproduces exactly |
| B | registration row DELETEd from all three, unmutated writer | `3 of 3`, exit 0; row re-INSERTed correctly. The INSERT branch and the read-back agree |
| C | registration write disabled (`if False and have_gc != want_gc`), cold tree | `0 of 3`, refusal, exit 1. The `bool(back)` short-circuit handles the absent row |
| D | consistent `_GC_COLS` reorder (see finding 2) | **false refusal** `0 of 3` on a correct, reachable file |
| E | pre-existing row with `data_type='features'`, `description='qgis'`, `srs_id=4326`, wall-clock `last_change` — the "arrives carrying its own registration" case | repaired by the UPDATE branch to the intended row, `3 of 3`, exit 0. **No false refusal** |
| F | another table already owns `identifier='layer_styles'`, our row absent | `sqlite3.IntegrityError: UNIQUE constraint failed: gpkg_contents.identifier`, exit 1 — loud, fails closed |
| G | `AFTER INSERT` trigger rewrites `identifier` after our write (see finding 1) | `2 of 3`, refusal, exit 1 — the tuple arm fires; the message names the wrong three things |

Independence check: the only two sub-expressions that do not descend from
`intended_registration()` are the `"attributes"` literal and `epoch`. The literal is genuinely
untied (mutation A proves it). `epoch` descends from `gpkg_epoch()`, which `intended_registration()`
is also given, so `back[4] == epoch` is implied by `back == want_gc` and adds nothing on its own —
harmless, and it is not the arm round 3 claimed independence for. The comment's wording ("does not
descend from `intended_registration()`") is accurate as written.

### `item_validate.py` `layers` exclusion

| # | mutation (on `floodplain_landcover.gpkg`) | result |
|---|---|---|
| control | pristine | **0 problems** — the exclusion introduces no false positive |
| 1 | `layer_styles` registered `data_type='features'` | exactly **1** problem, the registration arm. The spurious "layer 'layer_styles' has no style row" is gone — the stated intent |
| 1b | same, with the exclusion **reverted** in a scratch copy | **2** problems: the registration arm *and* "layer 'layer_styles' has no style row". Confirms the comment's claim verbatim — the message was wrong, nothing was let through |
| 2 | `DELETE FROM layer_styles WHERE id=1` | `set(layers) - styled` fires: "layer 'classified_all_ff04_2017' has no style row". **Not vacuous** |
| 3 | style row added for `no_such_layer` | `styled - set(layers)` fires, and the `cols_of` arm fires behind it. **Not vacuous** |
| 4 | `features` registration **plus** a style row naming `layer_styles` | 3 problems, including "has a style row for 'layer_styles', which is not a feature layer in this file" — a case the pre-change code could not see, because `layer_styles` was in `layers` and so cancelled out of `styled - set(layers)`. The exclusion is a net **gain** in detection |

`geom_of` reads `gpkg_geometry_columns`, where `layer_styles` never appears, so it is unaffected.
`distinct()` is only reached after `attr in cols_of.get(table, set())`, which is now empty for
`layer_styles`, so the exclusion cannot produce a `SELECT DISTINCT` against the style table.
`EXPECT_STYLE_REGISTRATION` (`item_validate.py:1016`) is a standalone literal — the untied copy is
real, not a round trip through `04_gpkg_style.py`.

### Prose claims verified rather than taken on trust

- **`item_create.py:437-444` — "the count was five before the registration as well"**: TRUE,
  measured. `ogrinfo -so -q` on a copy of `floodplain.gpkg` with the `gpkg_contents` row DELETEd
  lists 5 layers, `layer_styles` fifth — identical to the registered copy. `gpkg_contents` for that
  bundle holds only `features` rows besides the style table, so the `LIST_ALL_TABLES=AUTO`
  heuristic had nothing to trip on. `#95` is correctly described as the reason to fix the claim,
  not the cause of it. (Bound: "five" is five wherever the `_by_blue_line_key` breakdown exists;
  `01_stage.R:558` and `style_qml-write.py:22` both record that as all 23 groups, and the published
  text itself hedges with "where one exists", so the comment and the text do not contradict.)
- **`04_gpkg_style.py:48-50` — "the right feature count (4, 4 and 1 on the three bundles)"**: TRUE.
  `ogrinfo -so <f> layer_styles` gives Feature Count 4 / 4 / 1 on `floodplain.gpkg` /
  `floodplain_landcover.gpkg` / `transition_vector.gpkg`, with `FID Column = id`, every column
  typed, and no warning.
- **`CLAUDE.md:69-75` — "Five staged-side readers"**: TRUE and complete. Enumerated mechanically
  over `scripts/` — `04_gpkg_style.py:176` (`feature_layers`), `style_reach-check.py:162`
  (`feature_layers`), `test_pipeline.R:412` (`keyed_layers`), `gpkg_determinism-check.R:132`,
  `item_validate.py:1719-1720`. No sixth. The other `data_type` readers either read the
  registration by name (`style_determinism-check.py:156`), run on the producer's side where no
  style table exists (`test_pipeline.R:516-519`, `fp_gpkg.R:136-140`), or run before styling
  (`01_stage.R:507,541-542`). The round attribution ("rounds 1 and 2 each had to add one") checks
  out against `7957a66` and `d1a5ced`.
- **`04_gpkg_style.py:350-354` — "a registration that is not `attributes` loses the style in every
  bundle"**: corroborated at the GDAL level, and more strongly than stated. With
  `data_type='features'`, `ogrinfo` lists `layer_styles` in **none** of the three bundles — it has
  no `gpkg_geometry_columns` row. De-registration hides it only in `floodplain_landcover.gpkg`
  (1/1/0 listed vs 0/0/0). So `test_pipeline.R`'s positive `st_layers()` arm, which the comments
  describe as discriminating on the landcover bundle alone, in fact catches a `features`
  registration on all three. No hole here.

## What I could not close

The style **rows** half of the summary line is still the writer's intent: `style_gpkg()` returns
`len(layers)`, and nothing reads the inserted rows back. A writer that embedded a NULL
`f_table_schema` — the trap this file's own docstring calls the standing proof that a well-formed
row still opens unstyled — would print "9 style row(s) … 3 of 3" and exit 0. That is pre-existing
and out of this round's scope, and `item_validate.py` catches it absolutely (`schema != ""`), so
it is noted rather than filed. The round-3 comment is scoped to the registration and does not
overclaim.
