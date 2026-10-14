# Code-check round 1 — branch `75-provenance-key-check-verify-each-item-fi`

Reviewed: the three-dot branch diff against `origin/main` (13 files), plus the full current
text of `scripts/fp_provenance.R`, `scripts/fp_provenance-check.R`, `scripts/01_stage.R`,
`scripts/stage_years-check.R`, `scripts/test_pipeline.R`, `scripts/readme_functions.R`, and
the surrounding guards in `scripts/item_validate.py` / `scripts/catalogue_release.sh`.

All probes were run from a **copy** of `scripts/` in the scratchpad
(`/private/tmp/.../scratchpad/rt`); the repo working tree was not modified and no stage was
run against it.

## Findings

- **[fragile]** `scripts/item_validate.py:540-553` (`PROV_CENSUS`) and `CLAUDE.md`'s
  restatement of it ("today `link_run_uid` 18, the other eleven 21") — **both are stale
  against the tree this branch unblocks, so the first full release after this merges is
  refused.**

  Measured 2026-10-14 by running the repo's *own* reader (`fp_prov_read` →
  `fp_prov_item`, driven over `config/regions/*.yml` → `config/<wsg>/area.yml` →
  `primary_scenario`, year set taken from the real `rasters/<scen>/classified_*.tif`):

  | | items | `link_run_uid` | `link_config_sha256` | `link_sha` | other nine |
  |---|---|---|---|---|---|
  | measured now | 23 staged, 21 traced | **17** | **20** | **20** | 21 |
  | `PROV_CENSUS` literal | — | 18 | 21 | 21 | 21 |

  `PROVENANCE_FLOOR=21` (`catalogue_release.sh:60`) still matches — 21 items carry at least
  one field (`mcgr`, `pine` carry none) — so the floor is fine and only the per-field census
  is wrong. The whole delta is **DUNC**, which joined `config/regions/columbia.yml` upstream
  with `link_log: null` *and* `inputs$link$sha` null on its `all2` section, so it loses three
  fields where KOTL/LARL/SLOC lose one.

  Why it matters here rather than in #76: before this branch `01_stage.R` halted on `bulk`,
  so a full build could never reach `--expect-provenance` at all. This branch is what makes
  those exact literals reachable. It fails safe (a refusal, never a wrong publish), and DUNC
  is independently blocked one step earlier at `item_create.py` (floodplains#133, filed), so
  nothing can be published on a wrong count. But `CLAUDE.md`'s figure is a *measured* claim
  that is now false, and the branch names neither it nor `PROV_CENSUS`. Either re-measure
  both as part of this branch, or say in `NEWS.md`/`CLAUDE.md` that the census is deliberately
  left for #76 and that a full release is blocked until then.

  Reproduce:
  ```bash
  # from a copy of scripts/, with FLOODPLAINS_DATA pointing at the producer tree
  # drives fp_prov_item() once per rostered target and counts non-NA fields
  ```
  (script kept at `/private/tmp/.../scratchpad/census.R`; it only reads.)

- **[fragile]** `scripts/01_stage.R:225-227` — `which(vapply(targets, identical, logical(1), tgt))`
  names the wrong target when two `targets:` entries are byte-identical. `which()` then returns
  **both** indices and `stop()` concatenates them with no separator, so two identical bad
  entries report `target 12` rather than `target 1`. Measured:

  ```
  sim(list(list(species=NULL,scenario="x"), list(species=NULL,scenario="x")))
  -> "target 12 declares no usable `species` (NULL)"
  ```

  Degenerate input, and the stop still fires — but the index is the only thing in the message
  that points at a line of `area.yml`, and `12` is a plausible-looking wrong answer rather than
  an obvious one. A `seq_along(targets)` loop index (or `[1]` on the `which`) removes it.

- **[fragile]** `scripts/stage_years-check.R:97-99` — the new `REC_YEARS` derivation reads the
  producer's record with `$` (`$landcover[[SCEN]]$inputs$years`), which is the one access form
  `fp_provenance.R` bans by name ("`[[` throughout, never `$`: `$` PARTIAL-matches on a list, so
  an upstream `inputs_v2` would silently satisfy `$inputs`"). An upstream rename to a *longer*
  sibling (`years_built`, `inputs_v2`) is matched silently here while `fp_prov_span()` — which
  uses `[[` — stops. The arms then fail loudly rather than passing wrongly, so this is a
  robustness gap, not a live defect. Same line also reports a missing landcover section for
  `SCEN` as `"the record names fewer than three years"`, which misdescribes the cause (that path
  is reachable via the new `AREA=` override on a forward-only area).

## Verified, not findings

Things the brief asked about that I checked and found correct:

- **`fp_prov_sections()`'s new guards cannot raise an R error in place of their `stop()`.**
  Probed every shape against the real reader: section key absent from the document → `NULL`
  (lists return `NULL` for a missing `[[` name, confirmed); section written as `{}` or `[]` →
  forward-only `NULL`; section a JSON string/number → the shape stop naming `character`/`integer`;
  section JSON null → `NULL`; `scenario` as `NULL` / `NA_character_` / `character(0)` /
  length-2 / numeric → the "no usable scenario" stop in every case. `sum(keys == scenario)`
  cannot be `NA`, because `any(is.na(names(s)))` is refused by the shape guard immediately above
  it, and `keys` is `NULL` (so the comparison is `logical(0)`, `sum` 0) when the section is empty.
  `is.null(s[[scenario]])` is short-circuited by `scenario %in% keys`.
- **`fp_provenance-check.R` reproduces 87 assertions, 0 failed, 0 skipped** on this machine with
  the real producer tree (the re-taken `neexdzii` fold pin is live, not skipping).
- **The new per-item check passes the whole real roster.** All 23 rostered targets resolve
  through `fp_prov_item()` with no stop; every target's `primary_scenario` is a key of both its
  `floodplain` and its `landcover` section; no section holds a null-valued or duplicate key.
- **The safety premise in the new comment block holds as measured.** `rasters/<scenario>/`
  directories equal the `landcover` key set in every area carrying a record (no exceptions), and
  the `floodplain` keys are a superset.
- **`stage_years-check.R`'s derived years are correct for both populations.** Computed for all 21
  rostered areas with a record: three-year areas give `DROP=2020, PLANT=2024, FAKE=2018,
  MUT=2017,2018,2023`; annual areas give `DROP=2018, PLANT=2024, FAKE=2024,
  MUT=2017,2019..2024`. `DROP_YEAR <- REC_YEARS[2]` is never an end of `TRANSITION_SPAN`
  (`c(2017L, 2023L)`) in any area — with `length >= 3` and a sorted vector it is strictly
  interior, and every area's min/max are 2017/2023. `FAKE_YEAR` is never a recorded year, and
  every `MUT_YEARS` still covers the transition span and has ≥ 2 members, so arms (a)/(b)/(c)
  reach the `recorded-but-absent: …; present-but-unrecorded: …` arm of `fp_years_reconcile()`
  and not one of the three structural arms above it — i.e. each arm's `grepl()` still matches
  its own message. `change_interval` is `2017,2023` in every area, so that arm is never the one
  that fires first.
- **`test_pipeline.R`'s derived `want` cannot be reached with a bad `scenario`.** The
  `vapply(..., character(1))` does raise an opaque error for a `targets:` entry with no
  `scenario`, a non-character one, or a length-2 one — but `test_pipeline.R` `source()`s
  `01_stage.R` first, and the new per-target guard there stops with a named message for exactly
  those three inputs (including the `primary_scenario`-missing fallback). Confirmed by
  simulation. Stale items from a previous `WSG=` run cannot break the new `setequal()` either:
  `01_stage.R:84-85` unlinks `data/raw` and `data/stac` before anything else. A duplicated
  scenario across two `targets:` entries would survive `setequal()` (it ignores multiplicity),
  but the pre-existing `length(meta_paths) == n_expected` check at line 99 catches it.
- **No two-letter species assumption remains on the publish path.** `item_unregister.sh:31` and
  `catalogue_release.sh:102` are character-class only; `04_gpkg_style.py`'s rules are file-level
  and prefix-level; nothing else in the repo matches `[a-z]{2}_ff`. `CLAUDE.md`'s claim that the
  producer's validator is `^[a-z]{2,4}$` is accurate (`floodplains/scripts/floodplain_lcc/01_network_extract.R:56`).
- **`SPECIES` in `readme_functions.R` is a lookup, not a guard.** Both call sites use `[`
  (single bracket) inside `dplyr::coalesce(unname(SPECIES[...]), ...)`, so a miss is `NA` and
  coalesces to the raw code — `[[` on a named *atomic* vector would have errored, and it is not
  used.
- **`MORR` does not declare a `targets:` block.** The string `targets:` in
  `config/morr/area.yml` is inside a comment, so `yaml::read_yaml()$targets` is `NULL` for every
  rostered group, and both `stage_years-check.R`'s skip arm and `test_pipeline.R`'s fallback take
  the single-target path as intended.
- All six changed R files parse.
