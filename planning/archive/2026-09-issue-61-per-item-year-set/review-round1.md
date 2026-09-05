# Review round 1 — #61, the classified year set read per item

Reviewed 2026-09-05. Scope given: `scripts/01_stage.R`, `scripts/fp_provenance.R`,
`scripts/fp_provenance-check.R`, `scripts/stage_years-check.R`.

**The tree moved during the review.** At the first `git status` only those four paths were
staged; by the end sixteen were, including two files not in the brief
(`scripts/year_sets-check.py`, new; `scripts/item_validate.py`, `scripts/item_create.py`,
`scripts/run_pipeline.sh`, `scripts/test_pipeline.R`, `NEWS.md`, `README.Rmd`, `README.md`,
`index.html`). I read and exercised those too. Every finding below is against the working
tree as of the end of the session.

## What I verified by running, not by reading

| command | result |
|---|---|
| `Rscript scripts/fp_provenance-check.R` | 72 assertions, 0 failed, 0 skipped |
| `Rscript scripts/stage_years-check.R` | 13 assertions, 0 failed, 0 skipped |
| `uv run python scripts/year_sets-check.py` | 10 assertions, 0 failed |
| disk vs record year set, all 23 rostered targets | 21 match, 2 no-record (`mcgr_ch_ff04`, `pine_bt_ff04`) — **no target is made unstageable by this change** |
| `years` + `change_interval` present in every landcover section, all 24 upstream areas | present in all; `fp_prov_span`'s new schema-break stop cannot fire on today's tree |
| `unlink(dir, recursive = TRUE)` over a directory holding a symlink to a real tree | R removes the link, **not** the target (measured; the sandbox cannot eat `REPO/scripts`) |
| `index.html` regeneration | 3 hunks, all the prose change — **no id/timestamp churn**, the `#53` pinning holds |

I did **not** run `test_pipeline.R`: it stages in the repo's own cwd and `01_stage.R:80-81`
unlinks `data/raw` and `data/stac`, which would have destroyed the `ufra_ch_ff04` build
already sitting in the tree.

Things the brief asked me to stress-test that came back **clean**, so they are not findings:
`vapply` over a list vs a numeric vector (both fine; a JSON null is rejected before
`unlist()` is reached — `is.numeric(NULL)` is `FALSE` and short-circuits); `sort(as.integer(
unlist(v)))` unreachable with a null present; `list.files(pattern=)` is anchored both ends so
the `.aux.xml` sidecars cannot double-count; `sub()` on `character(0)` flows to
`integer(0)` and is caught by the length floor; `anyDuplicated()` in `if` (0 is falsy);
`invisible(FALSE)` read correctly by `if (!fp_years_reconcile(...))`; `expect_stop` uses
`fixed = TRUE` so the parenthesised needles (`year(s)`, `raster(s)`) match literally;
`system(intern = TRUE)` does capture stderr because the command carries its own `2>&1`;
`tempdir()` reuse is safe (per-case subdirectory, `unlink`ed on entry); every arm of both new
check scripts greps for its own message, so a different guard firing cannot read as a pass.
The ordered dispatch in `fp_years_reconcile` is sound: arms 1-3 are unconditional failures
and sit above the one conditionally-sanctioned return (`is.null(span_rec)`), which is the
placement link#262 says to get right.

## Findings

- **[fragile] `scripts/stage_years-check.R:136-137` — the assertion's claim is wider than its
  predicate.** The description says *"the sandbox holds the build, and the repo's tree was not
  written"*, but the condition is only
  `dir.exists(file.path(sbx, "data", "stac", "ufra_ch_ff04"))`. Nothing in the script ever
  observes `REPO/data`. That matters more than a wording slip because `01_stage.R:80-81`
  unlinks `data/raw` and `data/stac` **unconditionally and before anything else**, so the one
  failure this sentence advertises protection against — a sandbox that silently resolved to
  the repo cwd — is exactly the one the predicate cannot see, and it would take an unstaged
  ~GB build with it. I measured that the current script is in fact isolated (the `scripts`
  symlink survives `unlink`, and `cd` failing kills the whole `&&` chain), so this is a
  claim/predicate gap rather than a live bug. Cheap fix: snapshot `list.files(file.path(REPO,
  "data"), recursive = TRUE)` plus mtimes before the first `run_in()` and assert it is
  unchanged after the last, or at minimum narrow the description to what is tested.

- **[fragile] `scripts/stage_years-check.R:119-134` — the byte-identity pin's currency gate
  covers upstream but not the local toolchain.** `PIN_META_SHA256` digests a `meta.json` whose
  content includes `epsg`, three `floodplain_ff0N_km2` areas, `bbox_wgs84` and a full GeoJSON
  geometry, all produced by sf/GDAL/PROJ on the machine that runs it. The skip is gated only
  on `ufra`'s `produced_datetime`, so a different GDAL or PROJ makes this **FAIL**, not skip —
  under a description that says "byte-identical to the pre-change build", which points the
  reader at "the code moved the data". Same class as the `neexdzii` pin the same PR gated
  correctly, one axis over. Either widen the gate (record the sf/GDAL/PROJ versions beside the
  digest and skip out loud when they differ) or say in the failure message that a toolchain
  difference produces this too.

- **[fragile] neither new check script is reachable from anything.** `run_pipeline.sh` was
  touched in this diff and does **not** call `stage_years-check.R` or `year_sets-check.py`;
  `catalogue_release.sh` does not; and `scripts/README.md` — which documents
  `gpkg_determinism-check.R`, `style_determinism-check.py`, `style_drift-check.py`,
  `fp_provenance-check.R` and `attribution_drift-check.py`, each with its invocation — is not
  in the diff at all. Two suites that between them are the whole evidence for this issue exist
  only for whoever remembers to type them, which is the failure mode the repo already names
  ("a check that must be remembered has the same failure mode as the script that had to be
  remembered"). At minimum add both to `scripts/README.md` beside their siblings.

- **[bug] `NEWS.md:50` — "grew 25 cases" is not the number in the artifact.** Measured:
  `fp_provenance-check.R` goes from 49 to 72 assertions (24 `expect_*` added, 1 removed, net
  **23**), and the script's own last line prints `72 assertions`. No count of the diff yields
  25. This is the release-note class CLAUDE.md calls out by name — a figure restated rather
  than derived from the thing it describes, in the one document whose readers cannot check it.

- **[bug] `NEWS.md:33-37` — `change_interval` is listed as an absolute and it is not.**
  `fp_provenance.R:428` returns `invisible(FALSE)` when `span_rec` is `NULL`, so the
  `change_interval` comparison at `:442` is *record-dependent*: for the two forward-only items
  (`mcgr_ch_ff04`, `pine_bt_ff04`, both published `deprecated: true`) it never runs. The three
  guards that really are unconditional are the ones above that return — no duplicate year,
  length >= 2, both ends of `TRANSITION_SPAN` classified. As written the note tells a reader
  every published item had its `change_interval` reconciled against the transition span, and
  two did not.

- **[fragile] `CLAUDE.md:83` is now stale.** *"Assets per item: 3 classified-year COGs + a
  transition COG, plus three GeoPackages"* — this is the sentence the whole issue falsifies.
  `README.Rmd`, `README.md`, `index.html` and `item_create.py`'s collection description were
  all updated in this diff; the repo's own checklist was not, and it is the document the next
  session reads first.

- **[fragile] `scripts/fp_provenance-check.R:88` — a stale comment sitting on a
  type-mismatch trap.** `YEARS <- c(2017, 2020, 2023)` is a **double** vector, and its comment
  claims *"01_stage.R passes doubles, folded identically"*. `01_stage.R:241` has passed
  `sort(as.integer(...))` since before this branch, so the comment is already false. It is
  harmless for the fold (which goes through `as.character`), but `fp_years_reconcile` compares
  with `identical()` at `:433` and `:442`, which is type-strict — so wiring `YEARS` into that
  function, the obvious next reuse of the file's own span constant, produces a guard that
  fires on correct input and always will. Either make it `c(2017L, 2020L, 2023L)` or drop the
  sentence about doubles.

## Not findings, recorded so the next reviewer does not re-derive them

- The `fp_years_reconcile` / `fp_prov_span` split does keep two producers on the two sides of
  the `landcover_key` fold at the real call site. The one place they share a source is
  `real_item()` in `fp_provenance-check.R:327-330`, which the comment above it bounds
  correctly — and the `neexdzii` pin is gated on that file's own landcover stamp, so an
  upstream re-run reads as "re-take the pin".
- `item_validate.py`'s `ALLOWED_YEAR_SETS` is a literal a human sets, checked in **both**
  directions (an unsanctioned span refused; a sanctioned span nobody uses reported), and the
  `--partial` partition is right: the only arm dropped is the one asking about members a
  subset legitimately lacks. `year_sets-check.py` proves both directions, including the
  uniform-loss case a cross-item compare cannot see.
- Arm (d) (published `classified_*` assets vs the COGs on disk) reads `base / item_id`, which
  is where `03_cog.py:80` writes them — verified, not assumed.
- `test_pipeline.R`'s `n_expected <- 7L + length(unlist(meta$years))` is anchored on
  `meta.json`, a different artifact from the item JSON under test. `sprintf("%d", ...)` on the
  doubles jsonlite may hand back is fine in R for integer-valued doubles.
