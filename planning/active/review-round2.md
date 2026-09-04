# Code check — round 2 (#53 README rebuild) — render + publish side

Scope: `README.Rmd`, the two render targets and their interaction, `scripts/README.md`'s release
recipe, `ATTRIBUTION.md` / `README.md` factual claims, `.gitignore`. The R data-processing
functions were reviewed in parallel; round 1's two findings are re-verified below.

Everything here was measured against the artifacts on disk, not read off the source.

## Findings

### 1. **[bug]** `scripts/readme_functions.R:181-198` + `README.Rmd:137-139` — the `DT` table on `index.html` prints markdown bold markers literally and sorts every numeric column as text. The page's own note tells the reader to click those sort arrows.

`fp_readme_table()` builds one frame for both targets. Its total row is bolded with **markdown**
(`paste0("**", …, "**")`) and every numeric column is pre-formatted to a **string**
(`fp_readme_int()` → `"1,052"`, `"+1,620"`). `knitr::kable()` renders that correctly in
`README.md`. `DT::datatable()` does not: it renders stored values, and `escape = TRUE` (the
default, and `my_dt_table()` does not override it) only escapes HTML — `**` is not HTML.

Measured from the committed page (the widget's own JSON payload):

```bash
python3 - <<'PY'
import re,json
s=open('index.html',encoding='utf-8',errors='replace').read()
for b in re.findall(r'data-for="htmlwidget-[0-9a-f]+">(.*?)</script>', s, re.S):
    x=json.loads(b).get('x',{})
    if len(x.get('data',[]))==8:
        print([type(v).__name__ for v in x['data'][4][:3]], x['data'][4][-1], x['data'][0][-1])
PY
#> ['str', 'str', 'str'] **7,273** **Total**
```

Three consequences on `index.html` only (`README.md` is correct throughout):

- The last row displays as `**Total**` / `**7,273**` / `**17,008**` / `**13,775**` / `**-3,233**`
  — asterisks visible on the published landing page.
- All four numeric columns are `character`, so DataTables sorts them **lexicographically**.
  Sorting `Floodplain (km²)` ascending gives `101, 1,052, 117, 147, 152, 155, …` — `PCEA`'s
  1,052 km² lands second. `Net (ha)` sorts `+1,620` before `+53`. The caption emitted by
  `my_tab_caption_rmd()` says *"please click on one of the sort arrows within column headers"*,
  so the page actively directs readers into the broken behaviour.
- `filter = 'top'` gives text search boxes rather than numeric range sliders for the same reason,
  and the `**Total**` row participates in sorting and filtering — sort by any column and the
  total moves into the body of the table.

This is the round-1 mechanism repeating one axis over: one derived fact, two consumers, only one
of which is correct (`code-check.md`, "One fact derived twice"). Round 1 caught it in the popup
values; the table is the other consumer.

**Fix shape**: keep the raw numerics in the frame and format per target — `kable()` can take a
formatted copy while `my_dt_table()` gets the numeric one with `DT::formatCurrency`/`formatRound`
for the separators — or at minimum pass `escape = FALSE` and `<b>` instead of `**`, and drop the
total row out of the DT (a `container` footer, or just omit it and state the totals in prose).
Whatever is chosen, assert it: `stopifnot(is.numeric(dt_input[["Floodplain (km²)"]]))` before the
`my_dt_table()` call is one line and closes the class.

### 2. **[fragile]** `scripts/readme_functions.R:301-313` + `README.Rmd:132-135` — the `index.html` target cannot be rendered from any caller that passes a fresh `envir`. Reproduced, not inferred.

`my_tab_caption_rmd(caption_text = my_caption)` resolves its default argument in the *function's*
enclosure. `source("scripts/readme_functions.R")` puts that function in `globalenv()`, but
`my_caption <- …` is assigned in the knit environment. Under the documented recipe
(`Rscript -e 'rmarkdown::render(…)'`) `render()`'s default `envir = parent.frame()` **is**
`globalenv()`, so the two coincide and it works. Under anything that supplies its own
environment — RStudio's Knit button, `render()` called from inside a function or a wrapper
script — they do not:

```
$ Rscript -e 'rmarkdown::render("README.Rmd","html_document",output_file="e.html",
    output_dir=..., params=list(rmd_on=TRUE, update_query=FALSE), envir=new.env())'
 1. └─global my_tab_caption_rmd()
 2.   └─base::cat(...)
Quitting from README.Rmd:141-144 [tab-cap]
Execution halted
```

It fails **loudly**, so it cannot publish a wrong page — but the traceback points at `cat()`
rather than at the missing binding, and the `github_document` target is unaffected (the chunk is
`eval`-gated off), so the symptom is "Knit produces README.md fine but never index.html". One
line fixes it: `my_tab_caption_rmd(fp_readme_caption(props, version, fetched_at))`, passing the
value instead of relying on a global of that name.

### 3. **[fragile]** `ATTRIBUTION.md:15-24, 36` and `README.md:126, 130` — four licence-obligation literals are now published in prose with no assertion tying them to `item_create.py`.

`CLAUDE.md` records that the licence literals are duplicated verbatim into `item_validate.py` and
a third time as `EXPECT_LICENSE` in `catalogue_release.sh`, *"never shared"*, and that the
duplication is only safe **because the assertions are full equality**. `ATTRIBUTION.md` and
`README.md` are now a fourth and fifth copy with no assertion at all:

| literal | published in | guarded by |
|---|---|---|
| the whole `sci:citation` sentence | `ATTRIBUTION.md:15-24` (blockquote) | nothing |
| `io-lulc-annual-v02` + its Planetary Computer URL | `ATTRIBUTION.md:36`, `README.md:126` | nothing |
| "six `providers`" | `README.md:130` | nothing (`PROVIDERS` has 6 today — verified) |
| `CC BY 4.0` / `MIT` split | both | `EXPECT_LICENSE`, for the collection only |

I diffed the blockquote against `item_create.py`'s `CITATION` word-by-word: the only differences
are markdown decoration (`` `io-lulc-annual-v02` ``, `<https://…>`, `` `link` ``, `` `bcfishpass` ``).
It is faithful **today**. The risk is the one `check_citation_premise` exists for: an upstream
move to `v03` turns `item_validate.py` and release step 5 red, and leaves the two human-facing
documents silently asserting the old attribution — which is the surface a licensor actually
reads. A ~5-line check that strips markdown from the blockquote and compares to `CITATION` would
put these copies under the same rule as the other three.

### 4. **[fragile]** `scripts/readme_functions.R:161` — the published table's column is headed **Scenario** but carries `flood_factor` values, while the same page names `scenario` as a queryable STAC property with different values.

`Scenario = paste0("ff0", flood_factor)` → `ff04` / `ff06`. The items' actual `scenario` property
is species-pinned:

```r
unique(readRDS("data/readme_items.rds")$props$scenario)
#> "ch_ff04" "bt_ff04" "co_ff04" "ch_ff06"
```

So a reader who takes `ff06` from the column headed *Scenario* and writes
`rstac::ext_query(scenario == "ff06")` — using the query example three sections down, which names
`scenario` explicitly — gets zero items. The page carries its own antidote (*"Filter on
flood_factor, not scenario"*) but the heading contradicts it. Naming the column **Flood factor**
removes the contradiction and costs nothing; the surrounding prose already talks about flood
factors rather than scenarios.

### 5. **[fragile]** `scripts/readme_functions.R:449-454` — the `sips` DPI fix-up is macOS-only, inside a step `scripts/README.md:99-101` explicitly says can be run on a different machine.

```r
if (nzchar(Sys.which("sips"))) { system2("sips", c("-s","dpiWidth",dpi, …)) }
```

The committed `fig/coverage.png` carries `pHYs 7874 7874` (= 200 dpi, measured). The same render
on Linux — or on a Mac where `sips` is shadowed — silently skips the call and writes tmap's 72
dpi header instead. Two effects, both quiet: a re-render on another machine produces a
byte-different committed binary for identical data (the same churn class the new `set.seed(42)` /
`setWidgetIdSeed(42)` was added to close), and the code comment's stated reason ("macOS/Safari
size the image from that header") does not hold on either target anyway, since both emit
`width="100%"` on the `<img>`. Either drop the call, or make it a hard requirement of the render
step and say so in the Prerequisites table.

### 6. **[fragile]** `.gitignore:24-25` — `index_files/` and `README_files/` are ignored, and nothing asserts the html target actually self-contained.

Verified today: `index.html` embeds everything (67 `data:` URIs, zero `fig/` references, no
`index_files/` directory produced). The `.gitignore` comment names the *figure* version of this
trap. It does not cover the one the ignore line itself creates: if `self_contained` is ever
flipped, or a future pandoc/rmarkdown emits a non-self-contained page, `index.html` will reference
`index_files/` — which is excluded from the commit, so every widget (the map and the table) is
blank for every visitor while the author's local copy works. That is exactly the rule in
`code-check.md`, *"A link to a repo-hosted artifact must be tracked, not merely present"*, and
nothing in the recipe would catch it. One grep after the render closes it:

```bash
grep -q 'index_files/' index.html && { echo "index.html is not self-contained"; exit 1; }
```

### 7. **[fragile, low]** `README.Rmd:143-166` — the deprecated-item list is emitted in API response order, so `README.md` churns on an ordering the search does not pin.

`d <- props$id[props$deprecated]` inherits the search's order (there is no `sortby` — the popup
code says so and sorts for exactly this reason). `README.md:72` currently reads
`` (`pine_bt_ff04`, `mcgr_ch_ff04`) `` — not alphabetical. A re-render against unchanged data can
therefore rewrite that line. `sort()` on `d` is the whole fix.

### 8. **[note]** `README.md:35` — the `file:checksum` sentence is one shape away from a claim this project has already measured to be false.

> "Every asset publishes `file:checksum` and `file:size`, so you can confirm a download arrived
> intact and tell which version of a moving product a figure came from."

The first half is true. The second reads as a discriminator, and `CLAUDE.md`'s own memory index
records the v1.1.0 measurement — 140 assets across 20 items, **zero unchanged** — behind the rule
*"file:checksum does NOT tell which items changed"*, because a re-encode moves every byte. As
written it is defensible (a checksum does tell you whether the bytes you hold are the published
ones), but a reader will hear the stronger claim. Suggest: *"…so you can confirm a download
arrived intact, and tell whether the copy you hold is the one currently published."* Not flagged
as a bug — flagged because `code-check.md` names this exact sentence shape and this exact repo as
where it last cost something.

## Answers to the four questions

**1. Does step 6's order work, literally?** Yes. Both commands are copy-pasteable (single-quoted
`-e`, no apostrophes, no backticks) and both run. I executed each with `output_dir` redirected to
scratch so nothing in the tree was touched:

- `github_document` … `update_query = FALSE` → **byte-identical** to the committed `README.md`.
- `html_document` … `update_query = FALSE` → **byte-identical** to the committed `index.html`.

So the render is reproducible and the committed artifacts are current with `README.Rmd` (the
seeding added in `README.Rmd:33-34` is doing its job). The documented order is correct and the
stated reason holds: only the `github_document` pass has `update_query = TRUE`, so it is the only
one that refreshes `data/readme_items.rds` and `fig/coverage.png`.

- **Reversed** — as `scripts/README.md:108-110` says, `index.html` is built from the previous
  cache and then the cache moves. The site ships the previous release's numbers, and nothing
  detects it.
- **First only** — `README.md` + figure + cache advance, `index.html` stays behind. Same
  divergence, and the more likely one, because the second command is a separate line that can be
  forgotten or fail. Mitigated by the caption: `index.html` self-labels with its own
  `fetched_at` and catalogue version, so a stale page is at least *dated*. A stronger guard is
  cheap — after both renders, assert the version string appears in both files.
- **Second only** — harmless no-op (verified: byte-identical output).

**2. Fresh clone?** Yes for the html target, no network needed: `data/readme_items.rds` is
tracked (`git check-ignore` exits non-zero; `git ls-files` lists it, along with `fig/*.png`,
`index.html` and `.nojekyll`) and the render reads it. Every package in the Prerequisites row is
installed and sufficient here (R 4.5.2, rmarkdown 2.31, tmap 4.4.1, mapgl 0.4.6, DT 0.34.0).

- **Cache absent** → the render *stops*: `README.Rmd:69-71` checks `file.exists(CACHE)` and
  errors. Correct direction, and it is checked *after* the optional fetch so it cannot fire on
  the refresh path.
- **Cache present but stale** → both targets render happily from it. There is no guard, but the
  caption names the fetch date and the catalogue version, so the staleness is disclosed on the
  page rather than hidden. The `update_query = TRUE` path writes `saveRDS()` *after*
  `fp_readme_fig()`, so a failed figure cannot strand a newer cache — the right order
  (`code-check.md`, "A cache written before the work succeeds").

**3. Claims in `README.md` / `ATTRIBUTION.md` that are neither generated nor checkable in-repo.**
Generated at render time: item count (badge + caption), watershed-group count, region count and
list, catalogue version, the whole coverage table, the deprecated-items sentence. Everything else
is a hand-written literal:

| claim | where | status |
|---|---|---|
| "Each item carries **ten** assets" | `README.md:24` | checkable in-repo — `item_create.py` builds 3 + 1 + 3 + 3 = 10 today; unguarded literal |
| "six `providers`" | `README.md:130` | checkable — `PROVIDERS` has 6; unguarded |
| the `sci:citation` blockquote | `ATTRIBUTION.md:15-24` | checkable — verified word-identical to `CITATION`; unguarded (finding 3) |
| "Most groups publish one; MORR publishes two" | `README.md:24` | contradictable by the generated table; consistent today |
| "MORR's two items share one physical floodplain" | `README.md:70` | **guarded** — `fp_readme_table()`'s ff04-agreement `stop()` |
| "Every GeoPackage layer carries `wsg`, `species` and `scenario`" | `README.md:35` | *not* checkable here — `test_pipeline.R` deliberately asserts only `wsg` (`scripts/README.md` says so) |
| `io-lulc-annual-v02` / `mrdem-30` licence values, "Read from each producer's own record on 2026-09-03" | `ATTRIBUTION.md:32-38` | uncheckable, dated, and honestly labelled as such by the file itself |
| "GitHub reports the repository as `NOASSERTION`" | `ATTRIBUTION.md:47` | uncheckable third-party UI state |
| "The old VCA Toolbox URL now 302s … and returns 200" | `ATTRIBUTION.md:64-66` | uncheckable and time-sensitive |
| "QGIS 3.42+ speaks STAC natively"; "The dialog below is shown against a sister collection … it works identically here" | `README.md:96, 100` | uncheckable, and the second is explicitly disclosed |
| the interactive-version URL | `README.md:18` | tracked artifact, site not yet enabled (accepted, post-merge) |

Nothing in either file is *wrong* today. The set worth putting under a guard is the first three,
because they are the ones a change elsewhere in this repo can falsify silently (finding 3).

**4. Target divergence that produces a wrong page rather than a broken one.** Findings 1 and 4
are the substantive ones — both land on `index.html` and both look fine at a glance. Two more,
smaller:

- `code_folding: hide` (`README.Rmd:8`) applies only to `html_document`. The `query-demo` chunk
  is the page's only `echo = TRUE` block, so on `index.html` the "Query it" example ships
  **collapsed behind a Show button** while `README.md` shows it inline. Confirmed present in the
  page (`code-folding-btn` JS, and the `Code` dropdown in the header). Recoverable by clicking,
  but it hides the one thing the section exists to teach; `code_folding: show` would fix it.
- `README.md`'s relative links (`ATTRIBUTION.md`, `scripts/README.md`, `LICENSE`) carry through
  verbatim into `index.html` — the only local references left in the page. On github.com they
  render; on the Pages site with `.nojekyll` they are served raw, so `ATTRIBUTION.md` is a
  plain-text dump and `LICENSE` (no extension) will most likely prompt a download. Not broken;
  worth knowing before the Pages switch is flipped. (`.nojekyll` is nonetheless the right call —
  without it Jekyll would rewrite `ATTRIBUTION.md` to `.html` and those links would 404.)

## Checked and clean

- **Round 1 finding 1 (popup km²) is fixed and the artifact is corrected.** `fp_readme_map()` now
  mutates before the arrange. I re-extracted all 23 popups from the committed page and they match
  the table exactly (`bulk_co_ff04` 387, `pcea_bt_ff04` 1,052, `kotl_bt_ff04` 676 …). The
  `index.html` on disk *is* the re-render — verified byte-identical to a fresh render from the
  cache.
- **Round 1 finding 2 (REGION_COLS) is fixed**, and the guard is called from both consumers
  (`fp_readme_fig:383`, `fp_readme_map:466`) rather than one.
- **The two targets agree.** The `DT` payload in `index.html` and the `kable` table in
  `README.md` carry identical values for all 23 rows and the total.
- **Nothing referenced is untracked.** `index.html` has zero local `src`/`href` other than the
  three doc links above; all three exist and are tracked. `fig/*.png` and
  `data/readme_items.rds` are tracked and not ignored (checked with `git check-ignore` per path,
  not with `-v`, whose exit status is not a per-file verdict).
- **`.gitignore` additions are correct for what exists today** — `*.knit.md` / `*.utf8.md` cover
  the intermediates the render actually leaves (confirmed: `git status` clean after two renders),
  and the `!data/readme_items.rds` negation follows `data/*.rds`, which is the order that works.
- **The empty/missing-cache path fails toward abort**, not toward an empty page
  (`README.Rmd:68-71`).
- **`scripts/readme_coverage-table.py` has no surviving references** outside `planning/`.
- **`html_preview: false`** means the `github_document` pass never writes `README.html`, so the
  `.gitignore` entry for it is belt-and-braces rather than load-bearing.
- **Both `Rscript -e` commands survive copy-paste** — single-quoted, no apostrophes, no
  backticks, so neither the heredoc nor the command-substitution traps in `code-check-shell.md`
  apply.
