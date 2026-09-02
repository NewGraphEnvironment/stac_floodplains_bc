# Review round 1 — #40 (`40-nge-landcover-key-publishes-item-hash-th`)

Diff: `main..HEAD` over `scripts/` + `CLAUDE.md` (3 commits, 449 lines). Every changed file
read in full. Nothing in `data/` touched; `01_stage.R` / `test_pipeline.R` not run.

## Verdict: Clean

No bug, security issue, or data-loss path found in the diff.

## What was checked, and how

### Field-list copies and consumers (grep `landcover_key|PROV_FIELDS|nge:|item_hash` over `scripts/`, `README.md`, `NEWS.md`, `CLAUDE.md`)

Six copies of the field set, all carry the twelfth field: `01_stage.R:53`,
`item_create.py:62`, `02_raster_tag.py:84`, `item_validate.py:88`, `test_pipeline.R:136`,
`FP_PROV_MAP` in `fp_provenance.R:54`. Every consumer derives from one of those lists rather
than restating it (`item_create.py:312/407/408`, `02_raster_tag.py:120-122/250`,
`item_validate.py:121-126/158-166`, `01_stage.R:395`), so nothing was missed. `README.md`
carries no `nge:` field list. `catalogue_release.sh`'s `--only` read-back (l.436-454)
compares property sets wholesale with the build-null / served-absent rule, so a twelfth
key round-trips after register (non-null) or reads as equal (null); the pre-sync guard
compares item ids only. No consumer expects the old `landcover_key` semantics: every live
item's `nge:` block was published null (memory: BULK pilot, all 11 absent from the API).

### The fold hook against the three leaf states and the `link_log` exception

- section absent → `fp_prov_leaf` returns NA at l.257 before the fold is reached.
- leaf JSON-null → NULL with name retained, NA at l.282, fold not reached (check case
  "a JSON-null map publishes NA"; restoring the wrong order aborts the check at the null
  case — measured, see table).
- leaf absent under a present section → stop at l.271 (the `classified_sha256 →
  classified_content_sha256` rename signal; a v1 file is refused earlier by the version pin).
- `link_log` exception is keyed on `i == 1L && key == "link_log"`; the fold path is
  `c("inputs", "classified_content_sha256")`, so the two cannot interact.
- `spec[["fold"]]` on a spec without the key is NULL (`[[` on a list, exact match), so the
  eleven unfolded fields take the scalar guard unchanged.

### `match.fun`, `years` type, locale — probed, not reasoned

Probe script in the scratchpad (`probe.R`), run against the branch's `fp_provenance.R`:

| probe | result |
|---|---|
| `years = c(2017, 2020, 2023)` (double, as 01_stage.R passes) vs `c(2017L, …)` (as the check passes) | identical fold |
| `LC_COLLATE` C / en_US.UTF-8 / de_DE.UTF-8 | identical fold (equal-length digit strings collate the same everywhere) |
| reader `sys.source`d into a non-global env, global `fp_fold_year_digests` removed | fold resolves through the closure chain (`match.fun` → `parent.frame(2)` → `get(inherits = TRUE)`) |

Both real sourcing sites (`01_stage.R:68`, the check script l.30) are `source()` into the
global env, the easy case.

### Upstream serializer for `item_hash` (the unfolded twelfth field)

`landcover_item_hash` has no shape guard beyond "atomic scalar", so a producer writing
`NA_character_` as the string `"NA"` would publish a wrong value counted as traced. Checked
the producer: `floodplains/scripts/floodplain_lcc/fp_provenance.R:103` writes with
`na = "null", null = "null"`, and `fp_prov_stac_items` (l.677-699) builds `item_hash` with the
same `<year>=…` newline-joined `sha256:` construction the fold cites. Both real files read
today are `schema_version` 2 with the expected top-level key set; `neexdzii` carries a
three-year `classified_content_sha256` map, `bulk` no landcover section for `co_ff04`.

### Restore-the-bug: does each check case reach its guard?

The check script sources `scripts/fp_provenance.R` by relative path, so each defect was
restored in a **scratch copy** of `scripts/` (`$SCRATCHPAD/probe_<case>/`) and the check run
from there — the working tree was never patched, because a smoke test is sourcing that file
right now. `FLOODPLAINS_DATA` set to the absolute path so the real-file cases ran too.

| restored defect | result |
|---|---|
| baseline | 38 assertions, 0 failed, 0 skipped |
| year-set equality guard removed | 2 failed: "missing year" (stopped at the hex guard on a NULL `x[["2023"]]` — reported as *stopped for another reason*, so the pattern check works), "extra year did not stop" |
| join `"\n"` → `","` | 2 failed: "stated rule, recomputed here", "neexdzii pinned value" |
| `x[[y]]` → `x[[1]]` (first year's digest for every year) | 4 failed incl. "one changed hex digit in one year moves it" |
| fold called before the `is.null(cur)` check | script aborts at the JSON-null-map case with the fold's own message |
| `years` taken from `names(x)` instead of the item | 2 failed: missing / extra year did not stop |
| hex-shape guard removed | 1 failed: "not sha256:<64 hex> did not stop" |
| fold hook removed from `fp_prov_leaf` | script aborts: scalar guard refuses the map as object/array |
| `got` left unsorted | script aborts at the key-order case with "covers year(s) 2023, 2017, 2020" |

Every guard the script claims to exercise is reachable, and the `expect_stop` pattern match
distinguishes the intended stop from a downstream one.

## Non-issues worth a line (no action required for merge)

- `fp_provenance-check.R:159` comments `2017L` as "as 01_stage.R passes it"; `01_stage.R:29`
  passes doubles. Measured identical through `as.character()`, so the fixture cannot miss a
  failure here — the comment is merely imprecise.
- `NEWS.md:33` says "11 `nge:` run-provenance properties". That entry describes the released
  catalogue and was true of it; the next release entry will say 12. Release bookkeeping, not
  a defect in this diff.
