# Plan review — #53 (Plan agent, 2026-09-04)

The `Plan` agent type has no Write tool, so it returned the review as reply text; this file is
that review recorded, with a disposition column added after each finding was checked.

## Verified and fixed

| finding | verified how | disposition |
|---|---|---|
| **BLOCKER** — `tibble(x = NULL)` silently drops the column, `map_dfr` back-fills `NA`, `n_distinct(c(NA,NA))` is 1 so the ff04-agreement guard passes, and `fp_readme_int(NA)` renders the string `"NANA"` into a committed table. Python raised `KeyError`. | Measured all four steps in R. Restored the old shape against a feature with `floodplain_ff04_km2` removed: 23 rows, 1 NA, total rendered **`"NANA"`**. | Fixed — `fp_req()` restores the raise; proof arm added. |
| **BLOCKER** — `if_else(flood_factor == 4, ff04, ff06)` routes every non-4 factor to **ff06**, so an `ff02` item would print `Scenario = ff02` beside its ff06 area. Python indexed the column name dynamically. Duplicated in `fp_readme_map()`, wrong the same way. | Measured: for an ff02 item the dynamic pick gives 218.36 (the ff02 column) where the two-branch form gave 251.21 (the ff06 column). | Fixed — one `fp_readme_km2()` used by both callers, refusing a factor outside ff02/ff04/ff06. |
| `SPECIES[species]` yields `NA` for an unmodelled species; Python's `.get(sp, sp)` printed the code. | `c(bt="bull trout")["sk"]` → `NA`. | Fixed — `coalesce(…, species)`; proof arm added. |
| The version sentinel `"MISSING"` now ships into a **committed** artifact rather than stdout. | — | Fixed — refuse on absent, and cross-check the API version against the bucket's copy. |
| The bucket is fetched twice and the returned count is not the one the guard compared. | Read the code. | Fixed — one read, count passed into the guard. |
| Empty-features arm should run first: `any(character(0) == "next")` is FALSE, so a stripped response passes the paging arm vacuously. | — | Fixed — order swapped; the proof carries a negative control showing the same input passes once the empty arm is removed. |
| The caption said "at render time" while a normal render reads a cache that may be weeks old and name a superseded version. The Python generator had no cache and could not lie this way. | — | Fixed — the cache carries `fetched_at` and the caption names the date. |
| `params: rmd_on: true` (the sibling's default) means a bare render or a Knit-button press evaluates the DT and mapgl chunks into a gfm document and overwrites the committed landing page. | — | Fixed — defaults to `false`, the target an accidental render must not destroy. |
| `github_document` defaults to `html_preview: true`, generating a ~1.5 MB ignored `README.html` on every render. | Sibling ships one. | Fixed — `html_preview: false`. |
| `README_files/`, `index_files/`, `*.knit.md`, `*.utf8.md` untracked noise; a chunk that *prints* a plot lands its image in `README_files/` and 404s for every visitor. | — | Fixed — added to `.gitignore` with that reason. |
| **`bcfishpass` is not flatly Apache 2.0** — its `LICENSE` is three-part: SOFTWARE → Apache 2.0, DATABASE → **ODbL**, CONTENTS → DbCL. ODbL *is* share-alike, and `ATTRIBUTION.md` asserts "none is share-alike" a few lines away. | Read the LICENSE file: section headers at lines 2, 212, 761. | Fixed in both README and `ATTRIBUTION.md`, with the distinction spelled out. |
| **The USDA VCA Toolbox URL is dead and returns 200** — it 302s to `https://research.fs.usda.gov/rmrs`, a generic station page. A status-code link check passes it. `flooded`'s own README still cites it. | `curl -L -w '%{url_effective}'`. | Fixed — cite the station, and record the trap in `ATTRIBUTION.md`. |
| Popups assembled in response order while the table sorts, so a committed multi-MB `index.html` churns between identical renders. | — | Fixed — `arrange()` first. |
| The Prerequisites list written into `scripts/README.md` came from a stale dependency inventory. | — | Fixed — enumerated from the actual `library()`/`::` calls. |
| The bcdata UUID had no comment naming the record it points at. | — | Fixed. |

## Verified and already correct — no action

- **The item-count badge.** Flagged as a hardcoded fact violating acceptance item 9. It was
  already an inline `` `r nrow(props)` ``, so the committed number is generated.
- **Sister collections.** Flagged that the current README's `stac-uav-bc` is not a collection id
  (the endpoint serves `imagery-uav-bc-prod`). The rewrite already lists repo names with the
  correct collection ids beside them.
- **The md target losing the caption.** Flagged as gated to `rmd_on = TRUE`. It is emitted
  inline for the md target. The review's framing missed a **real** defect one step over, though:
  the caption was emitted inline *unconditionally* **and** again through `my_tab_caption_rmd()`,
  so `index.html` showed it twice — fixed, and asserted at one occurrence per target.
- **Figure gating.** Flagged as possibly drawn at render time when the geometry is never cached.
  `fp_readme_fig()` is already called only inside the `update_query` branch, and
  `include_graphics()` is unconditional for the md target.
- **`git check-ignore -v` semantics.** Independently hit and recorded in `findings.md`: `-v`
  prints the negation pattern and its exit status is not a per-file verdict. The per-file loop
  and a `git ls-files --error-unmatch` pass over all seven artifacts are what is used.

## Recorded, not acted on

- **Ship a `readme_guards-check.R`** so the guards run more often than once per release, as
  `gpkg_determinism-check.R` and `style_determinism-check.py` do. Correct in principle and the
  right shape for this repo. Out of scope for #53 — the proofs exist as a transcript today.
  Worth its own issue.
- **Stale claims in the current README's `## Pipeline` / `### Guards`** — "twelve `nge:`
  properties published as explicit nulls" (measured: **zero** null `nge:` values across all 23
  live items), "items are 3–9 MB each" (pre-v1.1.0), "six stages" vs `scripts/README.md`'s seven.
  The review warned that Phase 5 would *move* these into `scripts/README.md`. It does not — the
  sections are **deleted**, because `scripts/README.md` already covers that ground; only a new
  Prerequisites section was added. Confirmed `scripts/README.md` carries none of the three
  claims. They die with the deletion.
- **Pages verification is post-merge.** `source.branch=main`, so nothing serves from the feature
  branch. Enabling and verifying Pages is a post-merge step, stated as such rather than ticked.
