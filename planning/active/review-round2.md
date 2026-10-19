# Code-check round 2 — `98-publish-in-wsg-and-in-open-water-items`

Base `affcd31`, diff `git diff affcd31...HEAD`. Reviewer: code-check agent, 2026-10-19.
Read in full: the concatenated soul code-check conventions, the whole branch diff, repo
`CLAUDE.md`, `review-round1.md`, and every changed script.

Nothing in the working tree or under `data/` was modified. Every probe is read-only
(`sqlite3 … mode=ro`, `json.load`, `sf::st_read` with a `query=`, a module import, or a
hand-run `*-check` script that works in its own `tempfile.mkdtemp`). Three things were RUN
against the real tree, all read-only: `scripts/prov_fields-check.py` (**60 assertions, 0
failed**), `item_validate.check_gpkg_columns` / `check_metric_scopes` over `data/stac`
(**0 problems, straddle 23/23 on all five, seen 23**), and the full release-mode gate
`uv run python scripts/item_validate.py --base data/stac --expect 23 --expect-provenance 23`,
which **exits 0** — including `cog tags agree` (so all six new `SHARED_FIELDS` tags are in
every COG), `census … 12 fields` and the asserted straddle line. So the branch's own release
gate passes on the tree a release would publish; every finding below is about a claim, not
about the gate.

## Round 1's six fixes — verdict

| # | fix | verdict |
|---|---|---|
| 1 | `metric_drift` scoped to the un-rescoped window | **sound**, one wrong premise in the refusal message (F4) |
| 2 | `README.Rmd` PCEA sentence rewritten | **the replacement is false** (F1) — the new "most" is wrong in the other direction |
| 3 | `gpkg_required_columns()` per layer | **sound and exact** against the real files (measured below) |
| 4 | `01_stage.R` `st_union` comment replaced with the measurement | sound |
| 5 | `check_gpkg_columns` failure path sorted on `str(v)` | sound; `absent`/`continue` flow correct (below) |
| 6 | `test_pipeline.R`'s `0.15` pinned by a static arm | sound; regex matches both arms and survives reflow (below) |
| + | `in_wsg_flag()` zero-row + value-set refusals | **one shape of the value arm still passes and then yields NA** (F3) |

## Findings

- **[bug]** `README.Rmd:146` — *"and because the change is concentrated out there, **most of
  PCEA's gross change is outside its own group** even though most of its floodplain is
  inside."* Both halves of that clause are false **of the figures the paragraph is about**.
  Measured on `data/stac/pcea_all_ff04.json` and its `transition_vector.gpkg`:

  | quantity | in_wsg | footprint | outside |
  |---|---:|---:|---:|
  | `gross_loss_ha` | 227.7 | 238.5 | 10.8 (4.5%) |
  | `gross_gain_ha` | 225.4 | 292.5 | 67.1 (22.9%) |
  | gross change (loss + gain) | 453.1 | 531.0 | **77.9 (14.7%)** |

  So **85% of PCEA's published gross change is inside** its own group, and the change is not
  "concentrated out there" either — it is ~4x **denser inside** (453.1 ha / 491.38 km² =
  0.92 ha/km² inside against 77.9 ha / 351.96 km² = 0.22 ha/km² outside).

  The claim is true only of **total transition patch area**: `SELECT SUM(area_ha) … WHERE
  in_wsg=1` is 754.4 ha against 2,454.6 ha unclipped, i.e. 69% outside. That is precisely the
  conflation `NEWS.md:52-58` was written to stop — *"the two quantities should not be quoted
  for each other"* — and which `findings.md:184` (row A2) records as **already corrected
  once** in NEWS. Round 1's own note said *"'most' is true of total change"*; the fix moved
  that sentence into the paragraph that is entirely about `gross_loss_ha` / `gross_gain_ha` /
  `net_ha`, where it is not true. This is the public landing page
  (`README.md` + `index.html` at `www.newgraphenvironment.com/stac_floodplains_bc`).

  The last sentence (`net_ha` −2 ha against `net_footprint_ha` +54 ha) is correct, but the
  *reason* given for it is wrong: the two nets disagree because the small outside strip is
  strongly net-positive (+67.1 gain against +10.8 loss), not because the change is
  concentrated there. `progress.md:150` carries the same wrong rationale and needs the same
  correction, so the record does not re-assert it next round.

- **[bug]** `scripts/item_create.py:476-491` (the new `transition_vector.gpkg` asset
  description, published on all 23 items) — *"while `area_ha` summed over `in_wsg` is exactly
  this item's own headline figures."* It is not. Measured read-only on the staged build:

  | item | `SUM(area_ha) WHERE in_wsg=1` | `gross_loss_ha` + `gross_gain_ha` |
  |---|---:|---:|
  | `bulk_all_ff04` | 5584.9 | 4112.1 |
  | `pcea_all_ff04` | 754.4 | 453.1 |

  The transition layer holds **every** changed patch, not only tree gains and losses, so the
  sum over `in_wsg` exceeds the headline figures by every non-tree transition. The figures are
  exact only after the `from_class`/`to_class` filters the same description mentions two
  sentences earlier (verified: `SUM(area_ha) WHERE in_wsg=1 AND from_class='Trees' AND
  to_class<>'Trees'` = 2793.4 = `gross_loss_ha` on BULK, and the gain arm likewise, on both
  items). The sentence's parallel construction (*"rather than summing `area_ha` over it …
  while `area_ha` summed over `in_wsg` is exactly …"*) makes the wrong reading the natural
  one, and it is a claim a consumer will test with one SQL query on the file the description
  is attached to. Say that `in_wsg` is a true partition so the headline **computations** sum
  `area_ha` over its TRUE rows, rather than that the raw sum equals the figures.

- **[fragile]** `scripts/01_stage.R:231-250` (`in_wsg_flag()`) — the new refusals validate
  `raw` and then return `as.logical(raw)` **without checking the cast's output**, and the cast
  can introduce NA that `anyNA(raw)` cannot see. Measured in R:

  ```r
  raw <- c("0","1","1")                        # or factor(c("0","1"))
  setdiff(unique(as.character(raw)), c("0","1","TRUE","FALSE"))   # character(0)  -> passes
  anyNA(raw)                                                      # FALSE         -> passes
  as.logical(raw)                                                 # NA NA NA
  sum(c(10,20,30)[c(TRUE,FALSE,TRUE) & as.logical(raw)], na.rm = TRUE)   # 0
  ```

  So a `character`/`factor` `in_wsg` holding `"0"`/`"1"` passes both new arms and produces an
  all-NA mask; `tree_transition_metrics()`'s `tot()` then returns **0** for `gross_loss_ha`,
  `gross_gain_ha` and `net_ha` while the three `*_footprint_*` siblings are correct. That is
  the exact uniform-loss shape the function's own header says it exists to prevent, and every
  downstream arm passes it: `check_metric_scopes`'s `in_wsg <= footprint` holds (0 ≤ fp),
  `gain − loss == net` holds (0 == 0 − 0), and the straddle census **increments** because
  0 < footprint.

  Bounds, honestly: today every one of the **269** `in_wsg` columns in the staged tree is
  declared `BOOLEAN` (measured), so this is latent, not live. Two of the three guards that
  would otherwise cover it do not: `check_gpkg_columns` reads through `sqlite3`, which returns
  the **stored** type, so a `TEXT`-declared column holding integer 0/1 gives `{0, 1}` and
  passes; and `test_pipeline.R:510` uses `as.integer(iw) %in% c(0L, 1L)`, which accepts
  `"0"`/`"1"` (and truncates `1.5` to `1`) despite its message claiming *"a non-empty subset
  of {FALSE, TRUE}"*. The delineation path **does** fail loudly — `poly[NA, ]` gives NA
  geometry, so `floodplain_ffNN_km2` becomes NA and `check_metric_scopes`'s
  "expected a number" arm refuses — so only loss/gain/net are silent, and only if the two
  layers' column types ever diverge.

  One line closes it, in the place that names the cause:
  `out <- as.logical(raw); if (anyNA(out)) stop(where, ": `in_wsg` does not cast to a logical …"); out`.
  `findings.md`'s *"both valid shapes (`0`/`1` and `TRUE`/`FALSE`) pass"* should say which R
  types were tried, because the string spellings of those same two shapes do not.

- **[fragile]** `scripts/only_preflight.py:208-211` — the refusal message asserts *"and the
  live item **carries no** `*_footprint_*` key, so it predates the two-scope contract"*, but
  the window condition is `[n for n in FOOTPRINT_PROPERTIES if n in built and n not in live]`
  — *at least one* missing, not none present. `metric_drift`'s own docstring says so
  explicitly (*"A HALF-rescoped live item (some footprint keys, not all) is still inside the
  window"*), so the message is wrong in exactly the case the docstring reserves. Same class
  round 1 flagged on the previous version of this message. Unreachable today (items publish
  all twelve figures or none), and the arm's behaviour is correct; it is the diagnosis that
  would mislead.

## Checked and clean

Everything below was probed, not reasoned about.

**`metric_drift`'s window (round-1 fix 1).** `FOOTPRINT_PROPERTIES` is derived correctly — the
six `_footprint_` names, and none of the unsuffixed six contains that substring; the derivation
is pinned to the validator's copy by `prov_fields-check.py`'s `set(op.METRIC_PROPERTIES) ==
set(METRIC_PROPERTIES_V)` arm, which passes. Four attempts to fool the window, all closed:

- *live has all six, values moved* → quiet, and correct: that is an upstream re-run, the case
  `--only` exists for.
- *live has none, values moved* → refuses (proved end to end through `op.main` by
  `_drift_msg()`).
- *build is pre-#98 (no footprint keys), live is post-v2.1.0* → `rescoped` is empty so this arm
  is quiet, **but** `check_metric_scopes`' presence arm refuses the whole build
  ("metric property … is missing"), and it is not gated on `--partial`. Confirmed by reading
  `main()`'s `assert_straddle = args.expect_provenance is not None and not args.partial` —
  only the census is release-gated.
- *reaching the mixed state by `--only` before v2.1.0* → refused unless the item's twelve
  figures do not move, in which case `in_wsg == footprint` on that item and publishing it is
  harmless.
  Ordering verified: `catalogue_release.sh:436` pipes the API into `only_preflight.py` in
  step 0, and `item_validate.py` runs at step 1 (`:772`/`:774`), so the preflight is reached
  first and the validator is the backstop.

**`_drift_msg(live_rescoped=)` leaks nothing.** `sys.stdin` is swapped and restored in an inner
`finally`, the tempdir is removed in an outer one, and `op` holds no module state. It does
print `main()`'s `0|0|||` line to stdout on the expiry case — noise in the check script's
output, not state.

**`gpkg_required_columns()` is exact, not approximate.** Enumerated every registered layer of
every published GeoPackage in the build (69 files):

```
floodplain.gpkg            all_ff02, all_ff04, all_ff06, all_ff04_by_blue_line_key
floodplain_landcover.gpkg  classified_all_ff04_<year> x7, composition_*, patch_watercourse_*,
                           transition_all_ff04_2017_2023
transition_vector.gpkg     transition
```

`startswith("transition")` matches exactly two layers — `transition_all_ff04_2017_2023` and
`transition`, i.e. precisely the two the descriptions call "the transition patches" — and
nothing else. Over the 23 items: **0** missing columns (base four on all 269 data layers, the
six context columns on all 46 transition layers). The only layer family that carries any
`TRANSITION_COLUMNS` member without being matched is `composition_*` (`in_open_water`,
`in_wetland`, `in_alr`), which the prefix correctly does **not** claim. Note the unanchored
prefix is an over-claim risk in one direction only: a future upstream `transition_summary_*`
or `transition_reach_*` that is not a patch layer would be refused at release time rather
than shipped undescribed — fail-closed, but it would be a release-blocking false refusal, and
`01_stage.R`'s family census would name it on the same run.

**`check_gpkg_columns`'s `absent`/`continue` flow is right.** The value arm is skipped only
when `IN_WSG_COLUMN in absent` (where the `SELECT DISTINCT "in_wsg"` would raise
`OperationalError`); a layer missing one of the six context columns but carrying `in_wsg`
still reaches it. The `if not layers: … continue` is on the file loop, the column `continue`
on the layer loop. `compared` is incremented before the column test, so the
"asserted nothing" premise arm cannot be defeated by a tree of column-less layers. The
round-1 `str(v)` sort was reproduced: `sorted({0, 1, 'true'})` raises `TypeError`,
`sorted(…, key=lambda v: (v is None, str(v)))` does not.

**`layer_styles` exclusion.** `layer_styles` is registered `attributes` in all 69 published
GeoPackages, so the `('features','attributes')` filter would pick it up; the `table_name <> ?`
exclusion is correct, and `CLAUDE.md`'s count moving five → six is right (the six readers
enumerated in that paragraph all exist and all exclude by name).

**Round-1 fix 6's regex.** `re.findall(r"meta\$net[A-Za-z_]*\)\s*<=\s*([0-9]*\.?[0-9]+)\)")`
matches both arms in `test_pipeline.R:162-166` (the second spans a line break, and `\s`
matches `\n`, so a reflow survives); the `== [str(0.15)] * 2` form fails closed on a reversed
comparison, a renamed constant, a third arm, or a `0.150` spelling. The arm passes.

**`METRIC_NET_TOLERANCE = 0.15`.** Three independent `round(x, 1)` calls bound the identity at
3 × 0.05; the float-boundary case (`> 0.15` firing on `0.15000000000000002`) needs all three
unrounded values to land exactly on a half-step with the errors not cancelling, which
`area_ha` sums cannot do in practice.

**Measured claims that hold.** `CLAUDE.md`'s *"all 246 whole-network layers over the 23
rostered groups carry it, and the 222 that do not are the retired per-species layers"* — exact
(246/246 and 0/222, counted over `$FLOODPLAINS_DATA`). `all_ff04` is 2 features, one per side;
`all_ff04_by_blue_line_key` is one row per (key, side) — BULK 2,454 rows, 2,392 in / 62 out;
`patch_watercourse_*`'s key is `(name_basin, patch_id, in_wsg)` and `composition_*` carries
`in_wsg` + `in_open_water` — all present as described. `bbox_wgs84` is the real meta.json field
name. `flood_factor` is indeed a published property with no COG tag, so the precedent cited is
real. ff04 totals: in_wsg 10,092.27 km², footprint 10,611.35 km², difference 519.08 km² —
matching `readme_functions.R`'s new comment exactly. `NEWS.md`'s *"18 more between 0.8% and
2.7%"* holds (the 18 unnamed groups span 0.8%–2.6%). The straddle census is 23/23 on all five
pairs on this build, matching `METRIC_SCOPE_CENSUS`. The live-API claims (0 of 23 items carry a
`*_footprint_*` key; the geometry coordinate growth) could not be re-verified — the API timed
out from this machine (60 s, exit 124) — so they are taken as stated and dated.

**One ambiguity worth a word, not a finding.** `NEWS.md:96` and `CLAUDE.md:186` both say *"Both
new flags are **any-touch**, like `in_wetland`"*. In `CLAUDE.md` the antecedent is unambiguous
(`in_open_water` + `open_water_poly_id`); in `NEWS.md`'s "What a consumer should change"
paragraph it immediately follows two sentences about `in_wsg`, where the natural antecedent is
`in_wsg` + `in_open_water` — and `in_wsg` being any-touch is flatly false
(`item_create.py` says so itself: *"`in_wsg` is not, it is a true partition"*). A reader who
takes it that way stops trusting the one sum this release is built on. Both copies also call
`open_water_poly_id` a flag, which `item_validate.py:997` notes it is not.
