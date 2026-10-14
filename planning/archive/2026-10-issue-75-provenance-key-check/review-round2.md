# Code-check round 2 — branch `75-provenance-key-check-verify-each-item-fi`

Reviewed 2026-10-14 against `origin/main` merge-base (three-dot), with
`FLOODPLAINS_DATA=/Users/airvine/Projects/repo/floodplains/data`. Everything below was measured
on a `cp -r` copy of the repo at
`/private/tmp/claude-501/.../scratchpad/work/repo`; the repo's own working tree was not touched.

Round 1's three findings are not re-reported.

## The mechanism

**A fact about the upstream population, copied into this repo as a statement, with nothing that
re-derives it and a failure direction that is quiet.**

All three round-1 findings are that shape, not three unrelated slips:

- `PROV_CENSUS` — a *count* of the population, copied. The population gained DUNC; the copy
  still describes the build it was taken from.
- `which(vapply(targets, identical, ...))` — a *pointer into* the population, computed from the
  population itself. Two identical members make the pointer a vector, and `stop()` pastes it
  into a plausible wrong line number.
- `$landcover` / `$inputs` — a *read path* into the population, written in a form that keeps
  answering after the thing it names has been renamed (partial match).

The common tell is that each is correct at the moment it is written and nothing in the repo ever
asks the question again. The remedy this branch applies in three places is the right one — derive
it (`seq_along`, `area.yml`, the record's own years) or gate it (the three-way skip on the
`meta.json` digest pin) — and the two findings below are the places where the diff left a copy
ungated, or reads a moving population as if it were fixed.

## Findings

- **[fragile]** `scripts/stage_years-check.R:99` — `REC_DOC <- jsonlite::read_json(file.path(src_area,
  "provenance.json"), ...)` assumes the chosen area *has* a record. Two of the 23 rostered groups
  do not (`mcgr`, `pine` — the two `DEPRECATED_ITEMS`), and the new `AREA=` override makes them
  reachable from a documented entry point. Measured:

  ```
  AREA=mcgr Rscript scripts/stage_years-check.R
  Error in open.connection(con, "rb") : cannot open the connection
  ...cannot open file '.../data/mcgr/provenance.json': No such file or directory
  EXIT=1
  ```

  Exit 1 is this suite's "number of failed assertions", so a missing record reads as one failed
  assertion with no assertion line, no `skip`, and a message that names nothing about the cause —
  in a script whose stated discipline is "skipped OUT LOUD" and which already skips out loud for
  a missing area dir, a missing `area.yml`, a `targets:` block and a missing landcover section
  (`:104`). Note the landcover-section skip at `:104` is currently **unreachable** (every rostered
  target with a record holds its key in both sections — measured), so this crash is the *actual*
  forward-only path through the override. One guard beside the existing ones closes it:
  `if (!file.exists(p) || file.size(p) == 0) { skip(...); quit(status = 0) }`.

- **[fragile]** `scripts/fp_provenance-check.R:431-455` — the real-file arms call the reader
  **uncaught**, so any `stop()` the producer's bytes trigger aborts the whole script rather than
  failing one assertion. That is exactly the state this branch exists to fix, verified by running
  the merge-base copies of the three scripts against today's data:

  ```
  real producer files
  Error: provenance.json check: floodplain section key(s) 'all_ff02', 'all_ff04', 'all_ff06'
  are not scenario ids of the form <species>_ff<NN>. ...   EXIT=1
  ```

  (so the pre-branch `neexdzii` arms, the fold pin included, never ran — the NEWS claim is exact).
  The branch removed the current *cause* and left the *shape*: `real_item()` defaults to
  `species = "co", scenario = "co_ff04"` and `b <- real("bulk")` is pinned to bulk still carrying a
  `co_ff04` pair. Under the new rule a non-empty section missing that key is a `stop()`, so if
  upstream ever drops or re-keys bulk's retired `co_ff04` sections (bulk's roster target is
  `all_ff04` now; floodplains#125 retires the per-species items) the script halts again at the same
  line, with exit 1 and no assertion count. Before this branch that same state would have degraded
  to nulls and the `lc_present` arm at `:448-455` — which derives its expectation from the raw
  JSON — would have adapted. A `tryCatch` around each real-file arm reporting `fail()` instead of
  halting restores the property that one bad producer file costs one assertion.

- **[fragile]** `scripts/fp_provenance-check.R:463-465` (pre-existing, unchanged by the diff, but the
  immediate sibling of the pin this branch re-took) — `landcover_item_hash` is asserted against a
  literal with **no gate**, while the `landcover_key` pin 10 lines below it is gated on
  `produced_datetime == PIN_STAMP` and skips out loud. `item_hash` is a hash over the resolved STAC
  item ids, so it is stable across an in-place re-derivation but **not** across a span change — and
  floodplains#79 is converting areas to the annual span one at a time (`bulk` moved from 3 to 7
  years during this branch's own work). When it reaches `neexdzii`, the gated pin skips and this one
  **fails**, under a message that reads like the reader broke. Same for `:440`
  (`flooded_version == "0.5.0"`), a literal copied out of a file upstream is free to bump. Both want
  the same gate the fold pin has, or to be derived from the record the way `:448` is.

- **[fragile]** `scripts/fp_provenance.R:306-308` — the stated justification for the shape guard is
  false in R, and it understates what the guard is holding back: *"A JSON array reads back unnamed,
  and `[[scenario]]` on one raises 'subscript out of bounds' at the end of this function"*. Measured
  on this R: `list(1,2)[["co_ff04"]]` is **`NULL`**, not an error (only *atomic* vectors raise;
  `c(a=1)[["b"]]` does). So without the guard an array-shaped section would degrade to the
  forward-only `NULL` and publish seven nulls — the exact silent failure the function exists to
  prevent, not a loud indexing error. Worth correcting because the sentence is the argument a future
  reader would use to decide the guard is redundant. (The behaviour is right: the guard fires first,
  and `fp_provenance-check.R`'s array arm passes.)

- **[fragile]** `scripts/01_stage.R:223-225` — the new comment divides the labour backwards:
  *"fp_prov_sections() carries the same guard for its own lookup, but it is reached only when the
  area has a provenance.json, so it cannot cover the four areas that do not"*. The new roster
  assertion runs **before** `item_id` and before every `fp_prov_*` call, for **every** area, so
  `fp_prov_sections()`'s scenario guard is now unreachable from the stage altogether — which also
  makes its own message (*"An area.yml with no `primary_scenario` and no `targets` reaches here"*)
  false for the stage path. The behaviour is strictly better than the comment claims; only the
  comment is wrong, and it is the kind of claim that decides whether someone later deletes one of
  the two guards.

## Every quantified or measured claim the diff introduces, with a verdict

Measured today against the tree and `../floodplains/data` (22 records, 23 rostered targets).

| claim | where | verdict |
|---|---|---|
| "all 22 areas carrying a record" | `fp_provenance.R:275` | **TRUE** — 22 of 26 area dirs carry a non-empty `provenance.json` |
| `rasters/<scenario>/` set **equals** landcover keys, floodplain keys a superset | `fp_provenance.R:276-278` | **TRUE** — 0 violations over all 22 records |
| "measured on all 104 sections on disk, zero exceptions" (each section restates its key: `inputs$scenario` / `inputs$floodplain_layer`) | `fp_provenance.R:293-295`, NEWS | **TRUE** — 104 floodplain+landcover sections, 0 exceptions (130 incl. `network`) |
| "morr's file holds nine floodplain sections and three landcover ones" | `fp_provenance.R:200-201` | **TRUE** — fp 9 (`all/ch/co` × ff02/04/06), lc 3 (`all_ff04`, `ch_ff06`, `co_ff04`) |
| "`all2` is order 2 … a group carrying both `co3` and `all2`" | `fp_provenance.R:211-213` | **TRUE** — `bulk` carries `all2`(all) + `co3`(co); `morr` three; `min_order: 2` in all four whole-network area.yml |
| "measured 2026-10-14: lit, logs, mcgr, pine" have no record | `01_stage.R:222` | **TRUE** — exactly those four |
| "the producer's species slot … its own validator is `^[a-z]{2,4}$`" | CLAUDE.md | **TRUE** — `floodplains/scripts/floodplain_lcc/01_network_extract.R:56`, `fp_whole_fwa.R:30` |
| "`all` is the reserved token for the whole network at order ≥ 2, no access filter, attributed by `blue_line_key`" | CLAUDE.md, NEWS, `readme_functions.R:21-23` | **TRUE** — every `config/regions/*.yml` (`network: whole`, floodplains#104/#125) |
| "nothing here parses a species out of an id or a scenario"; `_ff(\d+)$`, `sub("_ff.*$","",scenario)` | CLAUDE.md | **TRUE** — only `item_create.py:351`, `01_stage.R:357`, `test_pipeline.R:146`, all off the item's own scenario |
| "23 rostered targets" | CLAUDE.md | **TRUE** — 23 (`regions/*.yml` × `area.yml`); **no** area.yml declares `targets:` any more |
| census "17 / 20 / 20, other nine 21, `PROVENANCE_FLOOR` 21 still exact" | CLAUDE.md, NEWS | **TRUE** — re-measured independently through `FP_PROV_MAP`'s paths: 17/20/20/21×9, 21 items with any field. Delta = DUNC (`link_log: null`) + KOTL/LARL/SLOC (`link_run_uid` only) |
| `PROV_CENSUS` literal reads 18 / 21 / 21 | CLAUDE.md, NEWS | **TRUE** (`item_validate.py:540-552`) — stale, accepted in round 1 |
| DUNC refused one step earlier by `item_create.py` for a half-present `link` entry (floodplains#133) | NEWS | **TRUE** — DUNC `all2.inputs.link` = `{version: "0.50.0", sha: null, sha_source: "unresolved_version_mismatch"}`; `item_create.py:499-505` raises |
| "`all_ff02`, `all_ff04`, `all_ff06` keys exist on disk now in `bulk`, `kisp`, `morr` and `dunc`" | NEWS | **TRUE** — exactly those four areas |
| "`Rscript scripts/fp_provenance-check.R` halted on the real `bulk` file — so that script's own producer-file arms had no coverage at all" | NEWS, scripts/README.md | **TRUE** — ran the merge-base scripts: halts at the first real-file arm, exit 1, `neexdzii` never reached |
| "87 assertions, 0 skipped" | NEWS | **TRUE** on this machine with the producer tree (`87 assertions, 0 failed, 0 skipped`, exit 0) |
| "a three-year item's `meta.json` byte-identical to the pre-change build" | NEWS | **TRUE** — ran it: 14 ok / 0 failed / 0 skipped; the digest arm is live (ufra stamp `2026-09-03T07:16:49Z` == `PIN_STAMP`, toolchain matches `PIN_TOOLCHAIN`) |
| "`AREA=bulk` … a whole-network record, 7-year span" | `stage_years-check.R:55`, scripts/README.md | **TRUE** — ran it: `bulk_all_ff04`, years 2017-2023, 13 ok / 0 failed / 1 skip (the ufra-only pin) |
| the re-taken `neexdzii` fold pin `sha256:170a9ef4…` at stamp `2026-10-13T23:24:26Z` | `fp_provenance-check.R:481-486` | **TRUE and correctly gated** — re-derived independently in stdlib Python over the producer's three digests (`<year>=<digest>` lines, years ascending, `\n`-joined, sha256) → `170a9ef4d7d5d668893c46d978064d4aaf8f75a2bb021db31c3645fe0af42989`; skips out loud on the next re-run |
| "MORR carries two LIVE (`morr_co_ff04` + `morr_ch_ff06`) but stages one" | CLAUDE.md, `item_create.py:4-6` | **CONSISTENT, NOT VERIFIED** — `images.a11s.one` was unreachable from this session, so the live pair could not be read back. Consistent with morr's record (landcover `ch_ff06` + `co_ff04`) and with morr's `area.yml` now declaring no `targets:` |

## Guards the diff adds — can any be satisfied by data that has since moved?

| guard | expectation | verdict |
|---|---|---|
| `fp_prov_sections()` item-finds-its-key (`fp_provenance.R:298-356`) | the item's own `scenario`, from `area.yml` | **derived** — no literal to go stale. Passes for all 23 rostered targets (no stop); refuses a re-key because every item's lookup misses |
| duplicate-key and null-valued-key refusals | the keys present in the file | **derived**; both proven by must-fail arms |
| `01_stage.R:226-237` roster assertion | the roster entry itself, `tgt_i` as the pointer | **derived** (round-1 fix verified) |
| `test_pipeline.R:456-463` target expectation | `area.yml`'s `targets:` / `primary_scenario` | **derived** — this *removes* a stale literal. Side note: with no `targets:` block anywhere upstream, the multi-target branch is now dead everywhere, so the smoke test can no longer exercise a two-item group |
| `stage_years-check.R:91-120` `SCEN` / `DROP_YEAR` / `PLANT_YEAR` / `FAKE_YEAR` / `MUT_YEARS` | the area's own `area.yml` + record | **derived** — verified on both a 3-year (`ufra`: drop 2020, plant 2024, fake 2018) and a 7-year area (`bulk`: drop 2018, plant 2024, fake→2024) |
| `stage_years-check.R:203-239` `meta.json` digest pin | three literals (area, stamp, toolchain), three gates | **gated** — correct shape; the new `AREA != "ufra"` gate is ordered before the stamp gate so it cannot blame upstream |
| `fp_provenance-check.R` fold pin | stamp-gated literal | **gated** (see above) |
| `fp_provenance-check.R:463` `item_hash`, `:440` `flooded_version` | ungated literals over a moving file | **NOT gated** — finding above |
| `stage_years-check.R:99` record read | assumes the area has a record | **NOT guarded** — finding above |

## Verified, not findings

- Every new refusal in `fp_prov_sections()` raises its own `stop()` rather than an R error:
  `list()[["x"]]` and `list(1,2)[["x"]]` are both `NULL` on lists (measured), `sum(NULL == s)` is 0,
  and the `is.null(s[[scenario]])` test is short-circuited by `scenario %in% keys`.
- `CONFIG_DIR` at `test_pipeline.R:456` is undefined in that script but supplied by
  `source("scripts/01_stage.R")` at `:33`; `wsg` is not clobbered by 01_stage.R's loop variable
  because `WSG_ONLY` restricts the loop to that one group.
- `SPECIES` in `readme_functions.R` is a coalesce-to-raw-code lookup at `:168` and `:573`, not a
  guard; `[` on a named atomic vector does not partial-match, so a new code renders as itself.
- `01_stage.R` skips a target with no `rasters/<scenario>/` **before** any provenance call, which is
  what makes the "non-empty section, my key absent" stop unreachable outside the crash state.
- Nothing in the diff adds an absolute path, host, credential or private reference (public repo).
