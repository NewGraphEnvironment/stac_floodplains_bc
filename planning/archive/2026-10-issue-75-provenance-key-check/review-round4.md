# Round 4 review — the fix for round 3 (#75)

Scope: `scratchpad/round3.diff` (146 lines) only, plus the current contents of
`scripts/01_stage.R`, `scripts/test_pipeline.R`, `scripts/stage_years-check.R` and
`scripts/fp_provenance-check.R`. Reviewed 2026-10-14.

## Verifications (all measured, nothing recalled)

- **The conversion is a no-op on every real config.** `yaml::read_yaml()` over all 24
  `config/*/area.yml` under `/Users/airvine/Projects/repo/floodplains/config` (23 rostered
  + `neexdzii`): `identical(a$k, a[["k"]])` is TRUE for `targets`, `species` and
  `primary_scenario` on every file, and `targets` is NULL on all 24 — no file carries a
  `targets:` block today, and no file carries any key with the prefix `targets`,
  `species` or `primary_scenario`. `config/morr/area.yml` mentions the retired block in
  **prose only** (line 9 comment), so the hazard the comment describes is latent, not live.
  The fix therefore cannot change what this build publishes.
- **`[[` on an absent name cannot raise here.** `read_yaml()` of a mapping returns a
  `list` (checked on `morr/area.yml` and on a synthetic two-scalar mapping); `list[["absent"]]`
  is NULL, and `NULL[["absent"]]` is also NULL (so an empty `area.yml`, which parses to
  NULL, still yields `n_expected == 1L` rather than an error). Only an **atomic** operand
  raises (`subscript out of bounds`) — and in that same shape `$` raises too
  (`$ operator is invalid for atomic vectors`), so no site in the diff trades a NULL for
  an error.
- **`vapply(declared, function(t) t[["scenario"]], character(1))`** (`test_pipeline.R:461`)
  is acceptable: `test_pipeline.R:33` is `source("scripts/01_stage.R")`, same process, so
  `01_stage.R`'s per-target `stop()` (`:235-247`) has already aborted on any target whose
  `scenario` is missing, non-scalar or empty. The `vapply` length error is unreachable from
  a tree the stage accepted.
- **The new `is.null(AREA_REGION)` arm is correctly placed and accounted.** It sits after
  the missing-tree arm (which it no longer shares) and before the `targets:` arm; the
  `AREA_REGION` loop above it is safe with no tree (`list.files()` on an absent
  `config/regions` is `character(0)`), so the ordering cannot report "no roster" for a
  missing tree. It prints the same `0 assertions, 0 failed, 1 skipped` line as the four
  sibling arms and `quit(status = 0)` like them. Both arms stay reachable (`AREA=neexdzii`
  reaches the new one). `AREA_REGION`'s two later uses (`:146` message, `:162` sandbox
  roster write) are still guaranteed non-NULL.
- **No unbalanced brace or unreachable branch.** `parse()` succeeds on all four files.
- **`fp_provenance-check.R`'s corrected count is right.** `awk '/b <- real\("bulk"\)/,0' |
  grep -cE 'expect_(true|equal|stop)\('` = **9**, as the new comment states and as its own
  cited command reproduces.

## Findings

- **[fragile]** `scripts/01_stage.R:140-148` — the **roster** read on the live publish path
  was not converted, while the new comment at `:205-212` says "`[[` throughout, never `$`".
  `rc$region` (`:140`, `:144`, `:146`, `:148`) and `rc$watershed_groups` (`:143`) are the
  identical partial-match hazard one level up: measured, a `config/regions/<r>.yml` carrying
  `watershed_groups_retired: [MORR, KISP]` and no live `watershed_groups:` makes
  `rc$watershed_groups` return `c("MORR","KISP")` while `rc[["watershed_groups"]]` is NULL.
  Under exactly the premise the round-3 fix was written for — "the producer is MID-WAY
  through retiring blocks" — that stages **whole retired watershed groups**, a strictly
  larger blast radius than the retired `targets:` block this fix closed, and it reaches
  `wsgs <- names(wsg_region)`, so every downstream gate (including `test_pipeline.R`'s
  derived `want`, which only ever sees the group it is given) agrees with it. No such key
  exists in any region file today, so this is latent at the same latency as the defect
  just fixed. Either convert these five accesses or narrow the comment's claim to the
  `targets`/`species`/`primary_scenario` block it actually covers — a comment asserting
  "throughout" over a file that still has five `$` reads of the same producer YAML is the
  copied-fact shape round 3 was about.
  Same line, same hazard, lower stakes: `scripts/stage_years-check.R:71`
  (`rc$watershed_groups`, `rc$region`) is the only `$` left in that script and sits 37
  lines above its own "`[[` throughout, never `$`" comment (`:108-111`); a
  `watershed_groups_retired:` block there sets `AREA_REGION` from the retired roster and
  so suppresses the new skip arm.

- **[fragile]** `scripts/01_stage.R:226-227` — `scenario <- tgt[["scenario"]]` and
  `species <- tgt[["species"]]` now run **before** the `for (f in c("species","scenario"))`
  guard at `:235`, whose comment calls it "the only guard on this path" and whose `stop()`
  names the file and the target index. For a target entry that is a bare scalar
  (`targets:\n  - co_ff04`, which `read_yaml` gives as `character`), `:226` raises
  `subscript out of bounds` with no file, no `wsg` and no `tgt_i`, so the carefully worded
  message never prints. Not a regression — `tgt$scenario` raised
  `$ operator is invalid for atomic vectors` in the same place — but moving the guard loop
  above `:226` would make the guard actually first, which is what its comment claims.

No bug, security or data-loss issue found in the diff. The publish-path conversion is
correct and verified no-op on current data; both findings are completeness gaps in the
fix rather than defects introduced by it.
