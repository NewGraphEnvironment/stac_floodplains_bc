# Code review — round 1 — branch `95-qgis-cannot-find-the-embedded-styles-in`

**Scrubbed before commit:** the reviewer named two private sibling repos, their files and
their internal functions, which is the same rule its own first finding is about — this repo
is public. Every finding is intact; the identifiers are described instead.

Merge-base `4db1fa8`. Reviewed 2026-10-16. Every claim below was reproduced on this machine
against the staged `sloc_all_ff04` tree, QGIS 4.2.1's python3.12 + GDAL 3.12.4, and sf's
GDAL 3.8.5.

## Findings

- **[security] `planning/active/{findings,task_plan,progress}.md` — a PUBLIC repo's tracked
  files name two PRIVATE sibling repos and their internals.**
  Verified by `gh repo view`: this repo is PUBLIC, both siblings are PRIVATE. The branch adds
  roughly 15 new instances across the three planning files — a heading naming one sibling, six
  of its internal function names, two of its source paths, its test-helper path, and for the
  other sibling a branch name and a commit sha. HEAD's commit says the private citations were
  "described rather than linked": the links went, the **names** did not. One file says "the
  field-data package" and then names an internal function of it two clauses later.
  This is exactly the class this repo's own #86 is open for.

  (Paths under the conventions repo's own directory are arguably pre-existing, since the
  generated below-marker CLAUDE.md carries them; the sibling-package material is the part this
  branch introduces.)

- **[bug] `planning/active/findings.md` — a bare `#89` that resolves to the WRONG issue.**
  "Under the split layout (#89) tracking owns its own file" means the sibling package's #89,
  and a bare `#N` in this repo's text links to *this* repo's #89 — the v2.0.0 whole-network
  cutover, unrelated. A working link to the wrong issue is worse than none, and with that repo
  private the number cannot be qualified either, so it has to go.

- **[fragile] `scripts/style_reach-check.py:81, 197-219` — 4 of the 9 assertions in the warm
  arm cannot fail, and they are the ones covering the bundle the fix is pre-emptive for.**
  `EXPECT_RENDERER["floodplain"] == "singleSymbol"` is also exactly what QGIS builds for a
  layer with **no** style at all. Measured: on a copy of `floodplain.gpkg` with
  `DROP TABLE layer_styles` *and* its `gpkg_contents` row deleted, `QgsVectorLayer` opened
  plain gives

  ```
  all_ff02 valid singleSymbol #2e6ad0   (opacity 1.0)
  all_ff04 valid singleSymbol #677d8f   (opacity 1.0)
  ```

  against the styled file's `singleSymbol #1f78b4` at opacity 0.5 on all four layers. So the
  one consumer-side probe in the repo passes identically whether `floodplain.gpkg`'s style is
  reachable, unreachable, or absent — while CLAUDE.md, NEWS.md and `04_gpkg_style.py` all
  argue that registering *that* bundle is the forward-looking half of the fix. The
  discriminator is already in hand (symbol colour and/or opacity), and the recipe this script
  replaces read it: `scripts/README.md`'s #46 paragraph says "renderer and symbol **opacity**
  read back from QGIS". Dropping opacity on the way into the committed script is a quiet
  regression.

  Knock-on prose: `scripts/README.md`'s "after, all nine carry the expected renderer" is true
  but only discriminating for 5 of the 9, and `NEWS.md`'s table row "what does QGIS actually
  **draw**" over-reads the floodplain rows the same way.

- **[fragile] `scripts/style_reach-check.py:238` — `feature_layers(dereg)[0]` can raise
  IndexError, and the traceback loses every finding already collected.** The warm arm records
  "declares no feature layers" and `continue`s rather than aborting, so a
  `floodplain_landcover.gpkg` in that state reaches the cold arm, which indexes an empty
  list. The exception escapes `main()` past `finally: app.exitQgis()`, so the `failures` list
  assembled above is never printed and the operator sees a stack trace instead of the
  diagnosis. Narrow, but it is precisely the state the arm above just detected.

- **[fragile] `scripts/04_gpkg_style.py:198, 203` — one (rows x registration) combination
  does not repair itself and aborts with a message pointing at the wrong file.** Measured: on
  a staged copy, `UPDATE gpkg_contents SET data_type='features' WHERE
  table_name='layer_styles'` then re-running `style_gpkg()` raises

  ```
  SystemExit: floodplain_landcover.gpkg layer 'layer_styles' matches no style rule —
  add it to FILE_STYLES in 04_gpkg_style.py, ...
  ```

  because `feature_layers()` selects on `data_type='features'` and so returns the style table
  as a layer to style, before the registration-repair branch is ever reached. Every other
  combination I drove is correct and idempotent (see "Verified clean" below), and this one
  is reachable by the same hands the UPDATE branch exists for — a consumer or upstream writer
  registering the table wrongly. A one-line `AND table_name <> 'layer_styles'` in
  `feature_layers()`, or the data_type check moved ahead of `intended_rows()`, makes the
  repair total.

- **[fragile] `scripts/test_pipeline.R:409-428` — the positive arm named as the pairing for
  the new by-name exclusion only discriminates on one of the three bundles.** Measured on
  sf's GDAL 3.8.5: delete the `layer_styles` registration from all three staged files and
  `st_layers()` still lists it in `floodplain.gpkg` and `transition_vector.gpkg`, hiding it
  only in `floodplain_landcover.gpkg` — which is the AUTO heuristic the issue is about, so
  this is unfixable at this layer rather than a slip. The de-registration of the other two
  *is* caught, by `item_validate.py`'s new arm over all of `STYLED_GPKGS` (I fired it: see
  below), so the cover exists. What is wrong is the comment at 379-390, which tells the next
  reader that the name-based exclusion in `keyed_layers()` "is paired with the POSITIVE arm
  below" — true for one file in three; for the other two the pairing is `item_validate.py`.

## Smaller note, not worth a code change on its own

- `scripts/04_gpkg_style.py:236` says the bare INSERT raises
  `UNIQUE constraint failed: gpkg_contents.identifier` — correct, I reproduced exactly that
  string. `scripts/README.md:493` and `scripts/style_determinism-check.py:175` attribute the
  same raise to `gpkg_contents.table_name` being the PRIMARY KEY. Both constraints exist; only
  the `identifier` one is what SQLite reports, so the two README/docstring sentences name a
  mechanism the message does not.

## Verified clean (so these do not need re-checking)

- **`style_gpkg()` across the (rows match/differ) x (registration absent/matching/differing)
  grid**, driven directly on staged copies: already-current → no write, byte-identical;
  rows match + registration missing (the #95 repair shape) → registration inserted only,
  `(4, True)`; rows differ + registration differs → both repaired, `last_change` back to the
  pin; style table dropped with registration kept → table and 4 rows rebuilt, registration
  left alone. New `tuple[int, bool]` return breaks no caller (`main()` and
  `style_determinism-check.py` are the only ones; `style_reach-check.py` does not call it).
  Commit is guarded by `if have != want or have_gc != want_gc`.
- **`item_validate.py`'s tuple slicing lines up with the SELECT.** SELECT order is
  `table_name, data_type, identifier, description, srs_id, last_change`;
  `EXPECT_STYLE_REGISTRATION` is `(…, "attributes", …, "", 0)`; `reg[0][:5]` / `reg[0][5]`
  are right. Fired all three arms on a temp copy of the staged tree: clean → `[]`,
  de-registered → the "0 gpkg_contents row(s)" problem, re-registered unpinned → the
  last_change problem. Not vacuous. `re` and `Path` are imported; the live row is exactly
  `('layer_styles','attributes','layer_styles','',0,'2000-01-01T00:00:00.000Z')`.
- **`style_determinism-check.py`**: warm run PASS (3/3 match), `NO_PIN=1` run PASS (3/3
  differ), so the cold path still exercises both stamps. **Arm 5 proven to fire**: with
  `04_gpkg_style.py` mutated in a throwaway tree to an unconditional INSERT, all three
  bundles reported "repairing a wrong registration raised IntegrityError(...)". Arm ordering
  is safe — arm 5 mutates only `a`, per-bundle, after every digest comparison that reads it.
- **`test_pipeline.R`**: `WSG=sloc Rscript scripts/test_pipeline.R` passes end to end. The
  new loop's `gp`/`gpkg` are re-bound by the loop that follows and nothing reads the stale
  values; `item_dir` is bound at line 120, well before line 419. The `layer_styles` exclusion
  does not weaken the source-set equality arm (`expect` comes from the producer's file, which
  has no style table) or the absolute-floor arm (its names are derived from `meta.json`).
- **`gpkg_determinism-check.R`**: passes, all 3 arms MATCH. The added
  `AND table_name <> 'layer_styles'` is necessary and correctly placed — the list is handed
  to `gpkg_copy_layers()` against the producer's file, and `dst` is unlinked first so no
  staged style table can leak into the comparison.
- **`style_reach-check.py` runs green under the documented recipe** (9 layers, cold arm fires
  correctly and reports `singleSymbol` for the de-registered classified layer). Its static
  drift arm is not vacuous: `literal()` finds `EXPECT_RENDERER` (nested in
  `check_layer_styles`, line 1597) and module-level `EXPECTED_STYLE_CATEGORIES` (line 1040),
  both `ast.literal_eval`-able, and the run would have aborted had either been missing.
  `app.exitQgis()` is reached on every path except the IndexError above.
- **No other reader of `gpkg_contents` is affected.** Confirmed by grep plus reading:
  `04_gpkg_style.feature_layers()` and `item_validate`'s `layers` select `features`;
  `fp_gpkg.R::gpkg_layer_keys()` and `01_stage.R` only ever see producer files or
  freshly-unlinked staged writes; `item_create.py` hashes bytes.
- **Numbers all reconcile.** 23 items = 19 three-year + 4 annual-span, so NEWS.md's
  "four layers per item (eight on the four annual-span items)" and "108 styled layers"
  check out (19x4 + 4x8 = 108). 69 moved checksums = 23 x 3 bundles. `ogrinfo`'s
  "6 layers → 7 layers" matches the staged landcover bundle (3 classified + transition +
  composition + patch_watercourse). "all nine" matches the real layer count
  (4 floodplain incl. `all_ff04_by_blue_line_key`, 4 landcover, 1 transition_vector).
  `10` / `91` agree with `item_validate.py`'s literals. `scripts/README.md`'s
  "`ogrinfo -so` … no warning, Feature Count: 4, FID Column = id, every column typed"
  reproduced verbatim.
- **No new cross-repo issue links in code or NEWS**; the only `#N` citations added are this
  repo's own (#46, #48, #86, #89, #95) and all five resolve to the right titles.
