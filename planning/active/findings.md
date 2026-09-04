# Findings — README rebuild from README.Rmd (#53)

## Measurements taken during planning (2026-09-04)

- Live API: **23 items**, 22 watershed groups, 4 regions (Columbia, Fraser, Peace, Skeena),
  collection version **1.1.0**, `license: CC-BY-4.0`. `pine_bt_ff04` and `mcgr_ch_ff04` publish
  `deprecated: true` (#26).
- Search with `limit: 1000` returns all 23 with **no `next` link** — the completeness guard ports
  directly. The API's served collection links are
  `['items','parent','root','self','license','derived_from','...queryables']` — no `rel: item`,
  which is why the count cross-check reads the **bucket** copy of `collection.json`.
- Item geometry is real floodplain ribbons: **1,448,930 vertices**, a **45 MB** response.
  Simplification barely helps — the mass is thousands of small parts, not vertex density along a
  few rings:

  | `st_simplify` dTolerance | in-memory | as GeoJSON |
  |---|---|---|
  | none | 45 MB | — |
  | 56 m | 27.2 MB | 13.9 MB |
  | 111 m | 26.0 MB | 11.9 MB |
  | 222 m | 25.6 MB | 11.0 MB |

  **This is what decides the interactive map's content.** Item geometry is neither cacheable
  (gitignored `data/*.rds`, and 25 MB is not a repo artifact) nor embeddable in a
  `self_contained: true` HTML. So the `mapgl` map is watershed-group level with per-item popups,
  and the static PNG carries the ribbons at full detail — where they are legible anyway.
- Legibility, the reason a WSG layer is needed at all: 7,273 km² of floodplain over a ~950,000 km²
  province. At a 1000 px-wide BC map that is ~1.2 km/px, so a 500 m-wide ribbon is sub-pixel.
- `bcdata::bcdc_query_geodata("freshwater-atlas-watershed-groups")` returns
  `WATERSHED_GROUP_CODE`, which matches the items' `wsg`. 2 groups = 530 KB unsimplified, so 22
  groups ≈ 6 MB before simplification. `bcmaps::bc_bound()` is installed and works offline.
- Render dependencies all present: `rstac` 1.0.1, `sf` 1.1.2, `bcdata` 0.5.3, `bcmaps` 2.3.0,
  `mapgl` 0.4.6, `DT` 0.34.0, `rmarkdown` 2.31, `ggplot2` 4.0.3, `knitr` 1.51.
- Only two **tracked** files reference `readme_coverage-table.py`: `README.md:27` and
  `scripts/README.md:95`. `CLAUDE.md` does not. Archived planning files keep their references —
  they are history, not documentation.
- `stac_dem_bc` Pages: `source.branch=main`, `source.path=/`, `build_type=legacy`, served at
  `https://www.newgraphenvironment.com/stac_dem_bc/`. It carries **no** `.nojekyll` and renders
  fine, because `self_contained: true` produces no `_files/` directory.
- `stac_dem_bc` tracks `index.html`, `README.html`, `fig/*` and `data/stac_result.rds`. This repo's
  `.gitignore` ignores `data/*.rds` and `README.html`, so the cache needs an explicit negation.

## Decisions

| decision | who / when | why |
|---|---|---|
| `rstac`, not the Python generator | airvine, in #53 | the figure needs the geometries anyway; two fetches in two languages is "one fact derived twice" |
| WSG polygons from `bcdata`, outline from `bcmaps` | airvine, 2026-09-04 | avoids an `fwapgr` dependency |
| interactive map on the site, static PNG on the landing page | airvine, 2026-09-04 | `params$rmd_on` already switches the two targets |
| cache properties only; never the 45 MB geometry | airvine, 2026-09-04 | measured above |

## Errors Encountered

| Error | Resolution |
|-------|------------|

## Issue context

## Problem

`README.md` is **307 lines / 2,592 words**, hand-maintained, and does not answer the first
question a visitor has: *what is in this catalogue and what can I do with it?*

Measured against the sibling this repo should look like — `stac_dem_bc` (serving
`stac-elevation-bc`) at 201 lines:

| | `stac_floodplains_bc` | `stac_dem_bc` |
|---|---|---|
| source of truth | `README.md`, edited by hand | `README.Rmd` |
| GitHub Pages | **not enabled** (404 on the API) | `index.html` rendered from the same source |
| figure | **none** | `fig/` |
| generated table | yes, by `scripts/readme_coverage-table.py` (#41) | yes, from an `rstac` chunk |

What is wrong with the content, specifically:

- **It opens with mechanism, not product.** A reader meets `PARTIAL_STAGE`, `--allow-retract`
  and `OGR_CURRENT_DATE` before they learn the collection covers floodplain land-cover change
  for BC watershed groups.
- **~90 lines are developer-internal** — `## Pipeline`, `### Guards` and `## Prerequisites`
  describe how *we* rebuild it. That belongs in `scripts/README.md`, which already covers it.
- **The foundations are invisible.** Nothing links `floodplains`, `link`, `flooded` or `drift`,
  so a reader cannot find where the modelling actually lives — and this repo's whole premise is
  that it does no modelling.
- **The people whose work this rests on are not credited anywhere.** The licence attribution
  added in #47 covers the *data* obligations (Impact Observatory, NRCan, the Province). It does
  not credit the *method* work, which is a different debt and is currently paid nowhere in this
  repo.

## What it should be

Plain language, tight, professional. A visitor should understand in thirty seconds what the
catalogue holds, see it on a map, see the coverage table, and know how to query it. Everything
else moves out or gets a link.

## Design — `README.Rmd` as the single source, two render targets

Adopt the `stac_dem_bc` pattern verbatim, since it is already proven on a sibling collection
served from the same endpoint:

```r
# README.Rmd, chunk `build`, eval = FALSE
rmarkdown::render("README.Rmd", output_format = "github_document",
                  params = list(rmd_on = FALSE))          # -> README.md, the GitHub landing page
rmarkdown::render("README.Rmd", output_format = "html_document",
                  output_file = "index.html",
                  params = list(rmd_on = TRUE))           # -> index.html, served on Pages
```

- `params$rmd_on` switches the bits that differ between the two (code folding, wider tables).
- `<!-- README.md is generated from README.Rmd. Please edit that file -->` at the top.
- Enable GitHub Pages on the repo (currently 404) and add `.nojekyll`.

## Elements

**1. Badges** — status, item count, API endpoint. Three, as on `stac-elevation-bc`.

**2. One paragraph, plain language.** What the collection is, who it is for, where the endpoint
is. No acronym unexpanded on first use.

**3. A figure** — a coverage map of the 23 items over BC, coloured by region, **built in R**
from the item geometries the same `rstac` call returns (`cartography` skill for the styling).
This is the element the README has never had and the one that answers "what have we got"
fastest. Rendered into `fig/` and committed, so the GitHub landing page shows it without a
render.

**4. What is in an item** — a short asset table (the three GeoPackages, four COGs, three
styles), one line each in plain language. Not the current 75-line `## Item model`.

**5. The coverage table** — an `rstac` chunk in the Rmd, sharing the single API call that
feeds the figure, with an `update_query` param that burns the result locally so `index.html`
rebuilds instantly (the `stac_dem_bc` pattern). Because the data is in memory at render time,
`index.html` can present it wider than `README.md` does.

This **retires `scripts/readme_coverage-table.py`** (#41). Two things must move with it, or the
change is a regression:

- Its **completeness guard** — it checks the fetched page against the bucket's
  `collection.json`, so a truncated page cannot quietly read as a smaller collection. Port it
  into the chunk; do not drop it.
- Its **caption**, which names the version the table describes.

**6. Query it** — the `rstac` snippet trimmed to the two calls that matter, plus the QGIS
one-liner. The current four annotated blocks are reference material, not a landing page.

**7. How it is built, and where** — one short paragraph and the pipeline chain, each link live:

> `fresh` (network) → `link` (habitat interpretation) → `flooded` (floodplains) →
> `drift` (land-cover change) → `floodplains` (driver) → **this repo** (publish only)

Stating plainly that **no modelling happens here** — this repo stages, converts to COG, tags,
uploads and registers.

**8. Credits.** Two different debts, kept distinct:

*Method and software this work is built on*

| whose | what | licence |
|---|---|---|
| [Devin Cairns](https://github.com/bluegeo/bluegeo) — BlueGeo | Valley Confinement Algorithm, which `flooded` adapts | MIT |
| [USDA VCA Toolbox](https://www.fs.usda.gov/rm/boise/AWAE/projects/valley_confinement.shtml) | the original valley-confinement method | — |
| [Simon Norris](https://github.com/smnorris/bcfishpass) — `bcfishpass` | lateral habitat assembly, and the reference `link` reproduces | Apache 2.0 |

*Data the published products derive from* — Impact Observatory / Esri / Microsoft, NRCan,
Province of BC. Already correct in the current README (#47); it just needs shortening, with the
full licence reasoning kept but moved below or linked.

**9. Licence** — two sentences: MIT for the scripts, CC BY 4.0 for the published catalogue.
The "Why CC BY 4.0 outbound" table stays in the repo (it is the record no guard can check) but
moves out of the landing page's first screen.

**10. Sister collections** on the same endpoint, as `stac_dem_bc` does.

## Moving out, not deleted

`## Pipeline`, `### Guards`, `## Prerequisites` → `scripts/README.md`, which is where the
release recipe and the guard inventory already live. The README links to it in one line.

## Decided — `rstac`, not the Python generator

Both the figure and the table come from **one `rstac` call in the Rmd** (airvine, 2026-09-04).

The figure is what settles it. A coverage map built in R needs the item geometries anyway, so
`rstac` is already in the render path — and keeping the Python generator alongside it means
fetching the same API response twice, in two languages, with two chances to disagree about what
the collection contains. That is the "one fact derived twice" shape this repo has already been
bitten by more than once.

What the decision costs, stated rather than discovered later:

- **Updating the table now needs R + `rstac`**, where `readme_coverage-table.py` was stdlib-only
  and ran anywhere `python3` did.
- That does **not** touch the release's portability, and the distinction matters: a release
  deliberately needs only AWS credentials and SSH, not the source tree, so it can be cut from a
  machine that does not hold it. Regenerating the coverage table is **step 6, past the tag** — a
  repo-content commit, not part of publishing — so it can happen on a different machine later
  without blocking or delaying a release. `scripts/README.md`'s "Cut a release" recipe needs
  step 6 rewritten to say so.

## Acceptance

- `README.md` and `index.html` both render from `README.Rmd`; the md carries the
  generated-from banner.
- `README.md` is comfortably under 150 lines and opens with what the catalogue *is*.
- A figure and the coverage table are both present.
- `floodplains`, `link`, `flooded`, `drift` are all linked, and it says plainly that no
  modelling happens in this repo.
- Devin Cairns / BlueGeo, the USDA VCA Toolbox, and Simon Norris / `bcfishpass` are credited by
  name with their licences.
- GitHub Pages serves `index.html`.
- The coverage table and the figure come from **one** `rstac` call; `readme_coverage-table.py`
  is removed and its completeness guard lives in the chunk.
- `scripts/README.md`'s release recipe step 6 no longer names the retired script, and says the
  table can be regenerated from a different machine than the one that cut the release.
- No fact in the README that is not either generated from the live API or checkable in the repo.


