# Code check — round 1 (#53 README rebuild)

Reviewed: staged diff on `53-readme-rebuild-from-readme-rmd-into-a-la`
(`.gitignore`, `ATTRIBUTION.md`, `README.Rmd`, `README.md`, `scripts/README.md`,
`scripts/readme_functions.R`, deletion of `scripts/readme_coverage-table.py`), plus the
committed binaries `index.html` and `data/readme_items.rds`.

## Findings

### 1. **[bug]** `scripts/readme_functions.R:455-457` — `fp_readme_map()` computes `km2` from the *unsorted* `props` and assigns it into an *already re-sorted* frame. 22 of 23 popups in the committed `index.html` carry another item's floodplain area.

```r
pop <- props |>
    dplyr::arrange(.data$wsg, .data$flood_factor, .data$species) |>   # 455 — reorders rows
    dplyr::mutate(
      km2 = fp_readme_km2(props),                                     # 457 — reads the ARGUMENT
```

`fp_readme_km2(props)` is evaluated against the function's `props` argument, not against the
piped-and-arranged frame. `mutate()` recycles that vector **positionally**, so row *i* of the
sorted frame receives the km² of row *i* of the unsorted input. Every other value in the popup
(`id`, `species`, `scenario`, `gross_loss_ha`, `gross_gain_ha`, `net_ha`, `deprecated`) is read
from the data mask and is correct — which is exactly what makes it silent: the popup names the
right item and pairs it with a plausible number.

`fp_readme_table()` (line 155-162) has the same call and is **correct**, because there the
`mutate()` precedes the `arrange()`. The two consumers of one derived fact diverged; only one of
them shipped the defect. (`code-check.md`, "One fact derived twice".)

**Measured, not inferred.** The cache is ordered reverse-alphabetically by id
(`WILL … BOWR`), and `arrange(wsg, flood_factor, species)` is very nearly its exact reverse, so
row *i* gets row *24-i*'s value:

| item | README.md table (correct) | `index.html` popup (shipped) | source of the wrong value |
|---|---:|---:|---|
| `bulk_co_ff04` | 387 km² | **101 km²** | UNTH |
| `kotl_bt_ff04` | 676 km² | **155 km²** | TABR |
| `pcea_bt_ff04` | 1,052 km² | **152 km²** | LNTH |
| `thom_ch_ff04` | 87 km² | **190 km²** | KISP |
| `morr_co_ff04` | 358 km² | **372 km²** | its own sibling's ff06 |
| `morr_ch_ff06` | 372 km² | **417 km²** | MORK |
| `bowr_ch_ff04` | 236 km² | 236 km² | WILL 236.09 — coincidence, not correctness |

Verification commands:

```bash
grep -o "bulk_co_ff04.\{0,90\}" index.html
#> bulk_co_ff04</b><br>coho, co_ff04 &middot; 101 km<sup>2</sup><br>loss 1,565 ha ...
```

```r
x <- readRDS("data/readme_items.rds")          # BULK's own ff04 is 386.53; 100.60 is UNTH's
```

`README.md`'s table and total row were checked against the same cache and are **correct**
throughout (KOTL 676 … BULK 387; total 7,273 / 17,008 / 13,775 / −3,233). The blast radius is
`index.html` only.

**Fix**: compute inside the pipeline rather than from the argument, e.g. move the `km2` mutate
above the `arrange()` as `fp_readme_table()` does, or use `dplyr::pick(dplyr::everything())`.

**Written data outlives the fix** (`code-check.md`). Correcting the function does not correct the
committed page — `index.html` must be re-rendered and re-committed. That render reads the cache
(`update_query = FALSE`), so it needs no network and the correct values are already in
`data/readme_items.rds`.

**Guard suggestion, not a test suggestion**: this class is invisible to every existing check
because all the guards are about *completeness*, none about *alignment*. One `stopifnot()` closes
it — after building `pop`, assert the popup text for a known id contains that id's own km²,
or simply assert `identical(sort(pop$km2_source_id), sort(props$id))` by keying the join on `id`
rather than on position.

### 2. **[fragile]** `scripts/readme_functions.R:352` — `REGION_COLS` is pinned to the four regions the collection publishes today, and nothing asserts the data stays inside it.

The four names are consumed three ways, none of which is derived from the data:

- `:395` `tm_scale_categorical(values = unname(REGION_COLS[sort(names(REGION_COLS))]))` — tmap
  assigns these to the **sorted levels of `w$region`**. A fifth region sorting anywhere but last
  shifts every colour one position while the figure still renders.
- `:410-415` `tm_add_legend(labels = ..., fill = ...)` — labels and swatches both come from
  `REGION_COLS`, so the legend cannot report the shift above; it would confidently mislabel.
- `:480-482` the maplibre `match` expression ends in a `"#999999"` fallback, so an unknown region
  draws **silently grey** with no legend entry at all.

`stopifnot(!anyNA(w$region))` at `:372` and `:478` only proves the join found a region, not that
the region is one we have a colour for. This is `code-check.md`'s "A guard's scope is usually a
coincidence, and it will not announce itself" — the scope here is "the regions that happened to
be published on 2026-09-04", and the failure direction is a rendered, committed, plausible-looking
artifact rather than an error.

**Fix**: one line beside the existing `stopifnot`s —
`stopifnot(all(props$region %in% names(REGION_COLS)))` — so a new region stops the render instead
of quietly recolouring the province.

## Checked and clean

- **Completeness guards ported from Python.** The three arms in `fp_readme_check_complete()`
  (`:126-142`) are ordered empty-first, and the comment is right about why: with `q$links`
  absent, `vapply(list(), …)` yields `character(0)` and `any(character(0) == "next")` is `FALSE`,
  so the paging arm alone would pass vacuously. Checking `n == 0L` first makes that unreachable.
  The count cross-check reads the **bucket's** `collection.json`, an independently written side —
  not a round-trip through the API the features came from.
- **`simplifyVector = FALSE`** in `fp_readme_bucket()` (`:112`) is genuinely load-bearing, as the
  docstring claims: with the default, `links` returns a data.frame and `vapply` would walk columns.
- **The `MISSING` version sentinel is gone** (`:84-93`) and replaced with a refusal plus a
  bucket-vs-API equality check. This is the right direction for a generator whose output is
  committed rather than printed.
- **`fp_req()`** (`:28-35`) closes the R-specific trap the Python original could not reach:
  `tibble(x = NULL)` drops the column, `map_dfr` back-fills `NA`, and `n_distinct(c(NA, NA))` is
  1 — so the ff04-agreement guard at `:168-175` would have agreed with itself. Guarding on
  `is.null || length != 1 || is.na` covers all three of NULL / zero-length / NA.
  `deprecated = isTRUE(p$deprecated)` is correctly exempted, and the comment says why.
- **`fp_readme_km2()`** (`:42-52`) replaces the two-branch `if_else` that would have routed an
  `ff02` item to its ff06 area. The `setdiff(ff, c(2,4,6))` refusal is absolute, not derived.
- **Artifact tracking.** `.gitignore` negates `data/*.rds` for `data/readme_items.rds`, with a
  comment naming the exact trap (`git add` on an ignored path exits 0 and tracks nothing).
  Verified: `git check-ignore` returns non-zero for all three of `data/readme_items.rds`,
  `fig/coverage.png`, `index.html`, and `git ls-files` shows all of them tracked, along with both
  QGIS screenshots the Rmd references. Nothing the README links is present-but-untracked.
- **`README_files/` and `index_files/`** added to `.gitignore` — correct for this repo, since
  every image the page references is routed through `fig/` and committed.
- **Caption honesty.** `fp_readme_caption()` naming the *fetch* date rather than "at render time"
  is the right call now that a cache exists; the cached `fetched_at` (2026-09-04) and `version`
  (1.1.0) match what `README.md` publishes.
- **`system2("sips", …)`** at `:435` passes `shQuote(path)` — the `system2()` arg-quoting trap in
  `code-check.md` does not apply here.
- **`scripts/README.md`** step 6 documents the render order and states the reason (the
  `github_document` pass refreshes the cache `index.html` then reads). That matches the `build`
  chunk in `README.Rmd:125-145`. The Prerequisites table lists every package the render needs.
- **Deleted `readme_coverage-table.py`** has no surviving references outside `planning/`.

## Noted, not flagged

`mapgl::add_fill_layer(source = w)` and `add_line_layer(source = w)` each embed the polygon
GeoJSON, so the watershed-group geometry appears **twice** in `index.html` (confirmed: the
`bulk_co_ff04` popup string occurs 2×). At 5.8 MB committed on every release render this roughly
doubles the page and the git-history growth. Not a correctness problem and the size was already
accepted — recorded only because `index.html` is re-committed on a schedule.
