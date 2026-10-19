# Code-check round 1 — `98-publish-in-wsg-and-in-open-water-items`

Base `affcd31`, diff `git diff affcd31...HEAD`. Reviewer: code-check agent, 2026-10-18.
Read in full: the concatenated soul code-check conventions, the whole branch diff, repo
`CLAUDE.md`, and every changed script. Nothing in the working tree or under `data/` was
modified; every probe below is a read-only `sqlite3 … mode=ro` / `json.load` / module import,
or a hand-run `*-check` script that works in its own `tempfile.mkdtemp`.

## Findings

- **[fragile]** `scripts/only_preflight.py:87-110` + `:183-193` — `metric_drift()` refuses
  **any** `--only` whose twelve figures differ from the live item, permanently and with no
  override. The hazard it was written for is #98's one-time rescoping, which disappears the
  moment v2.1.0 is live; the arm does not. After that release the ordinary reason to republish
  one item is that the group was **re-run upstream**, and a re-run changes `gross_loss_ha`,
  `gross_gain_ha`, `net_ha` and the three areas without redefining anything. The module's own
  docstring names the case it then refuses — *"A per-item value that legitimately moves when
  one area is re-run — a checksum, a provenance digest, a year set — is exactly what `--only`
  exists to publish"* — and the file's existing comment at `:199-203` gives the same argument
  for the asymmetric `gained` arm (*"Refusing that direction would block the next
  kotl/larl/sloc republish"*). Those three items lack `link_run_uid` because their upstream
  block predates link#262; they gain it when the area is re-run, and that re-run moves the
  metrics too, so the two arms now disagree about the same event.
  The refusal message asserts a premise that is false in that case (*"a redefinition is a
  full-release change by construction"*). `grep -n "metric\|METRIC" scripts/catalogue_release.sh
  scripts/catalogue_release-check.sh` returns nothing, so there is no flag, env knob or
  `--allow-*` past it: the only route is editing the script, which is the shape
  `code-check.md` ("A guard's scope, escape hatches, and remedies") is about. The refusal
  *does* reach the shell correctly — `only_prov=$(curl … | python3 …) || { … exit 1; }` takes
  the pipeline's last status — so this is over-refusal, not a hole.
  Worth deciding deliberately rather than at the next `--only`: either scope the arm to the
  pre-v2.1.0 window (e.g. refuse only when the live item carries **no** `*_footprint_*` key,
  which is exactly the un-rescoped state), or give it a named override the release script has
  to pass.

- **[bug]** `README.Rmd:146` — *"for `pcea_all_ff04` it is 42%, because **most** of that item's
  floodplain lies in Williston Reservoir's arms inside `PARS` and `FINA`"*. Measured on the
  build in `data/stac`: `pcea_all_ff04` is `floodplain_ff04_km2` 491.38 against
  `floodplain_ff04_footprint_km2` 843.34, i.e. **41.73% outside** and 58.27% inside PCEA's own
  group. "Most" is false — it is a minority, and the sentence's own "42%" says so one clause
  earlier. This is the public landing page (`index.html` + `README.md` at
  `www.newgraphenvironment.com/stac_floodplains_bc`). The same fact is stated **correctly** in
  all three other copies the branch touched — `CLAUDE.md` ("41.7% of its floodplain lying in
  Williston's PARS and FINA arms"), `scripts/README.md`, and `scripts/01_stage.R:674-676` — so
  only this one needs the edit. (`planning/active/task_plan.md:9` and `findings.md:136` carry
  the same wording about the *change* figures, where `findings.md` measures 754.4 ha inside
  against 2,454.6 unclipped, so "most" is true of total change; `NEWS.md` already corrects the
  "roughly triple" version of that. The floodplain-area sentence is the one that is wrong.)

- **[fragile]** `scripts/item_create.py:473-486` and `:740-756`, against
  `scripts/item_validate.py:962-1037` — this release starts **publishing a claim about six
  more columns that nothing reads**. The `transition_vector.gpkg` asset description now asserts
  `in_open_water`, `open_water_poly_id`, `in_fire`, `in_harvest`, `in_wetland` and `in_alr` on
  all 23 items, and the collection description repeats the first two.
  `grep -rn "in_open_water\|open_water_poly_id" scripts/*.py scripts/*.R` returns
  **`item_create.py` only** — `check_gpkg_columns` is hardcoded to the single scalar
  `IN_WSG_COLUMN`, and `test_pipeline.R`'s new arm likewise. That is exactly the B5 defect class
  this branch fixed for `in_wsg` ("a published claim about 23 items x 13 layers was being
  checked on one item, by a script outside the release path"), re-introduced in the same commit
  for the columns the same commit started claiming. Measured today: all six are present on all
  23 `transition_vector.gpkg`, so it is a watch-nothing gap and not yet a false statement — the
  cheap fix is to make the check a `{gpkg name: required columns}` map rather than one constant.
  Consequence inside the diff: `item_validate.py:2409-2411`'s success line ("every data layer
  … carries `'in_wsg'`, holding only TRUE/FALSE — **which is what the asset descriptions
  claim**") over-claims; the descriptions claim six columns more than that line verifies.

- **[fragile]** `scripts/01_stage.R:997-1000` — the new comment above the `st_union()` says
  *"`st_union()` over the two pieces of what was one polygon is the same geometry, so the split
  does not move this"*, which **this branch's own measurement disproves**.
  `planning/active/findings.md:476-491` records "geometry byte-identical to live: **0 of 23**"
  and "+8 (DUNC) to +364 (FRAN)" coordinates, and `CLAUDE.md:76-89` concludes "**no** item's
  geometry is byte-identical to the published one … Do not assert byte or vertex equality on
  this geometry". The call-site comment is the copy a maintainer reads before deciding whether
  a geometry diff is expected, and it currently says the opposite of the measurement. (The
  *ground* claim is fine — 11.9 m² symmetric difference on BULK — it is "does not move this"
  that is wrong.) `planning/active/task_plan.md:729` carries the same pre-measurement wording;
  that one is a historical record and can stay.

- **[fragile]** `scripts/item_validate.py:1025-1026` — the failure-reporting path of
  `check_gpkg_columns` crashes instead of reporting. `sorted(vals, key=lambda v: (v is None, v))`
  raises when `vals` mixes types, which SQLite permits in any column whatever its declared
  type. Probed: `sorted({0, 'x'}, key=lambda v: (v is None, v))` →
  `TypeError: '<' not supported between instances of 'str' and 'int'`. So a layer whose
  `in_wsg` holds `0`/`1` plus a stray `'true'` dies with a traceback rather than the message
  that names the values. Non-zero exit either way, so the release still fails closed — this
  costs the diagnosis, not the gate. Sorting on `(v is None, str(v))` fixes it.

- **[fragile]** `scripts/test_pipeline.R:162` and `:165` hardcode `0.15` while
  `scripts/item_validate.py:834` names the same number `METRIC_NET_TOLERANCE`, and the R
  comment claims they are the "same constant and same reason". Nothing joins them. Every other
  literal this repo duplicates across the R and Python halves is pinned —
  `prov_fields-check.py` holds four publish-side copies of the provenance map in place, and the
  new `SHARED_FIELDS` pin was added in this very diff for exactly this reason (B4). A change to
  `METRIC_NET_TOLERANCE` would silently leave the staged-side arm on the old value, in the
  direction that matters: a looser `test_pipeline.R` passes a build the release then refuses,
  or a tighter one fails a build that is fine. A static arm in `prov_fields-check.py` reading
  the number out of `test_pipeline.R` (the file already has `_code_only()` for exactly this
  kind of R-source arm) would close it.

## Minor — noted, not blocking

- `scripts/01_stage.R:911-924` — `in_wsg_flag()` validates presence and NA but not the value
  set: `as.logical(2L)` is `TRUE`, so a corrupt `in_wsg = 2` is silently counted as in-group
  while the metrics are computed. Caught downstream by `check_gpkg_columns`'s `{0, 1}` arm and
  `test_pipeline.R`'s value-set arm, both of which run before anything is published, so the
  pipeline is fail-closed overall; the staged figures would just be wrong in the message that
  names the cause.
- `planning/active/task_plan.md:842` says `stage_years-check.R` is "the only thing that
  exercises `in_wsg_flag()`'s refusals on a tree that is not `data/`".
  `grep -rn "in_wsg" scripts/stage_years-check.R` is **empty** — it re-runs `01_stage.R`, so the
  function executes, but neither refusal branch is restored by any committed check.
  `progress.md` records both as "proved" by hand. Not a defect in shipped code; it does mean
  the restore-the-bug proof for those two arms is not reproducible from the repo.
- `scripts/item_create.py:481-486` — "**All of them** are any-touch, so read areas by flag from
  `composition_*` … rather than summing `area_ha` over a flag" sits two sentences after "each
  patch carries `in_wsg`, and the headline properties sum the TRUE rows". Read as including
  `in_wsg` it tells a consumer not to do the thing the item's own `gross_loss_ha` does.
  `README.Rmd:220` scopes the same sentence correctly ("Like `in_wetland`, **it** is an
  any-touch flag"); the asset description would read unambiguously as "All of those context
  flags are any-touch".

## Checked and correct — the quantified claims, re-derived from the artifacts

Every "every / all 23 / N" in the diff that I could measure, measured rather than read:

| claim | where | verdict |
|---|---|---|
| 246 whole-network layers carry `in_wsg`, 222 do not | `CLAUDE.md`, `NEWS.md`, `task_plan.md` | **exact**: over the 23 staged groups' `../floodplains/data/<wsg>/{floodplain,floodplain_landcover}.gpkg`, 246 with / 222 without. The staged side is 269 data layers = 246 + the 23 `transition_vector.gpkg` copies, which is the same number from the other direction |
| `layer_styles` is one of `floodplain_landcover.gpkg`'s **three** `attributes` rows | `CLAUDE.md:18` | correct — `composition_*`, `layer_styles`, `patch_watercourse_*` |
| **Six** staged-side `layer_styles` by-name exclusions | `CLAUDE.md:10-19` | correct, and no seventh: `04_gpkg_style.py:211`, `style_reach-check.py:162`, `item_validate.py:1007` (new), `item_validate.py:1948`, `gpkg_determinism-check.R:132`, `test_pipeline.R:441` |
| `METRIC_SCOPE_CENSUS` = 23 on all five | `item_validate.py:862-868` | `check_metric_scopes(data/stac, census=True)` → no problems, straddle 23/23/23/23/23, seen 23 |
| every data layer of all three gpkgs carries `in_wsg` ∈ {0,1} | `item_create.py` descriptions, `README.Rmd`, the new guard | `check_gpkg_columns(data/stac)` → `[]`, over 23 items x (4 + 10 + 1) layers |
| NEWS table: PCEA 41.7 / LCHL 3.3 / TABR 3.2 / MCGR 3.0, "18 more between 0.8% and 2.7%", UNTH 0.8 | `NEWS.md` | holds: the 18 unnamed groups span 0.83%–2.65%, UNTH 0.81%, and the four named round as printed |
| 10,611 → 10,092, difference 519 km² | `readme_functions.R:1798-1802` | exact: footprint sum 10611.35, in_wsg sum 10092.27, diff 519.08 |
| census asserted only at release time | `item_validate.py:2396` | correct: `catalogue_release.sh:772` passes `--partial` under `--only`, `:774-775` passes `--expect-provenance` on a full release, `run_pipeline.sh:74` passes neither, and a full release with `PARTIAL_STAGE` is refused at step 0 — so `args.expect_provenance is not None and not args.partial` is exactly the release-time full build |
| `check_metric_scopes` / `check_gpkg_columns` cannot pass vacuously | both | `census=True` over an empty tree fails on 0≠23; `check_gpkg_columns` has the `compared == 0` arm; and `main()`'s `items != expected` floor runs ahead of both |
| `DERIVATION_STATEMENT` survives the description append | `item_create.py:740-756` | `check_collection_metadata(data/stac/collection.json)` → `[]`, and `in_wsg` is in the served description |
| the new guards fire | `prov_fields-check.py` | ran it: **58 assertions, 0 failed**, including all five new metric-scope cases and the end-to-end `only_preflight.main()` drift case |
| attribution literals still agree | `attribution_drift-check.py` | PASS, citation 770 chars |
| `_drift_msg()` leaks nothing | `prov_fields-check.py:245-271` | `sys.stdin` restored in an inner `finally`, tempdir removed in an outer `finally`; both survive a non-`SystemExit` exception |
| 17 → 23 `meta.json` core fields | `01_stage.R:807-810`, `test_pipeline.R:224-228` | both lists are 23 and agree |

Other things I checked and found sound: `poly[keep, ]` is ordinary `[.sf` row subsetting with a
full-length logical (no `drop` surprise, and `in_wsg_flag()` has already refused NA so no
NA-row injection); `ff_layers` is a named character vector so `lapply` + `ff_areas[["ff02"]]`
resolves; rounding at assembly keeps `net = round(gain - loss, 1)` over the unrounded sums and
the 3 × 0.05 tolerance is the right bound, with `> 0.15` in Python and `<= 0.15` in R agreeing
on the boundary; `round()` is monotonic so `in_wsg <= footprint` cannot invert under
independent rounding; `isTRUE()` on every new `test_pipeline.R` arm fails closed on a NULL
field; `bool` is excluded explicitly in the numeric arm; `STYLED_GPKGS`/`STYLE_TABLE` are
defined after `check_gpkg_columns` but resolved at call time, so the forward reference is fine;
`span` is in scope at `item_create.py:482`; `MANAGED_KEYS` growing in `02_raster_tag.py` makes
the re-tag skip check strictly stricter; and `check_cog_tags`'s `want`/`got` diff covers the
six new unprefixed tags in the drop direction, with the new static pin in
`prov_fields-check.py` covering the add direction that `managed` cannot see.
