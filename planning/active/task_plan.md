# Task: README: rebuild from README.Rmd into a landing page and a Pages site — plain language, a figure, a table, and credit where it is owed (#53)

`README.md` is **307 lines / 2,592 words**, hand-maintained, and does not answer the first
question a visitor has: *what is in this catalogue and what can I do with it?* It opens with
mechanism (`PARTIAL_STAGE`, `--allow-retract`, `OGR_CURRENT_DATE`) rather than product; ~90 lines
are developer-internal and already covered by `scripts/README.md`; the upstream packages the whole
thing rests on (`floodplains`, `link`, `flooded`, `drift`) are never linked; and the *method* debt —
BlueGeo's Valley Confinement Algorithm, the USDA VCA Toolbox, `bcfishpass` — is credited nowhere.
GitHub Pages is not enabled (404 on the API).

Adopt the sibling `stac_dem_bc` pattern: one `README.Rmd`, two render targets, **one `rstac` call**
feeding both a figure and the coverage table. That retires `scripts/readme_coverage-table.py` (#41),
whose completeness guard and version-naming caption must move into the chunk or the change is a
regression.

## Design decisions (measured during planning — see findings.md)

- **The interactive map is watershed-group level, not floodplain level.** Item geometry is
  1,448,930 vertices / 45 MB, and `st_simplify` at 222 m still yields 11 MB of GeoJSON, so it is
  neither cacheable nor embeddable. The static PNG carries the ribbons at full detail.
- **Cache is properties-only** — `data/readme_items.rds` holds geometry-stripped item properties,
  the collection version, and the simplified WSG polygons. The 45 MB response is consumed
  in-process to draw the PNG and never committed.
- **WSG polygons from `bcdata`, provincial outline from `bcmaps`** — no `fwapgr` dependency
  (airvine, 2026-09-04).

| render | figure | table |
|---|---|---|
| `README.md` (`rmd_on = FALSE`) | `fig/coverage.png` | `knitr::kable` markdown table |
| `index.html` (`rmd_on = TRUE`) | interactive `mapgl` map | `DT` datatable, wider |

## Phase 1: Render harness

- [ ] `README.Rmd` scaffold: YAML params (`rmd_on`, `update_query`), `setup` chunk, `build` chunk
      (`eval = FALSE`) with both `rmarkdown::render()` calls, generated-from banner
- [ ] `scripts/readme_functions.R` — sourced by the Rmd; holds `my_dt_table` / `my_tab_caption_rmd`
      (ported from `stac_dem_bc/scripts/staticimports.R` + `functions.R`)
- [ ] `.gitignore`: negate the cache (`!data/readme_items.rds`) — `data/*.rds` is currently ignored,
      and `git add` on an ignored path exits 0 while tracking nothing
- [ ] Verify with `git check-ignore -v data/readme_items.rds` (expect no output)

## Phase 2: The one call, its guards, and the cache

- [ ] `fp_readme_fetch()` in `scripts/readme_functions.R`: one `rstac` POST search (`limit = 1000`),
      returning items + collection version
- [ ] Port every guard from `scripts/readme_coverage-table.py` — behaviour, not text:
      - [ ] refuse if any link has `rel == "next"` (paged)
      - [ ] refuse if zero features, **before** the cross-check (0 == 0 would otherwise pass)
      - [ ] cross-check the feature count against the **bucket** `collection.json`'s `rel: item`
            link count — the API rewrites served links, so the bucket copy is the independent side
      - [ ] assert items within a WSG agree on `floodplain_ff04_km2`, so the once-per-group km²
            total does not depend on response order
- [ ] Keep the caption's content: item count, group count, regions, **catalogue version**
- [ ] Burn `data/readme_items.rds` (properties + version + simplified WSG polygons)
- [ ] **Restore-the-bug proof** for each guard: force a `next` link, an empty feature list, and a
      bucket-count mismatch, and confirm each refuses. Grep the output for the *message* — four
      guards means four ways to exit non-zero and only one is the evidence

## Phase 3: Figure and map

- [ ] `fig/coverage.png`: `bcmaps::bc_bound()` outline, WSG polygons filled by region, item
      floodplain geometry stroked over them, WSG labels. Committed.
- [ ] `mapgl` map for `index.html` from the cached WSG polygons, coloured by region, popups carrying
      each item's species / scenario / floodplain km² / loss / gain / net
- [ ] Confirm `index.html` size stays sane (`self_contained: true` embeds everything)

## Phase 4: Prose

- [ ] Badges (status, item count, endpoint); one plain-language paragraph, no unexpanded acronym
- [ ] Asset table — three GeoPackages, four COGs, three styles — one line each, replacing the
      75-line `## Item model`
- [ ] Coverage table + caption from the chunk; note the two `deprecated: true` items (#26)
- [ ] Query section trimmed to the two `rstac` calls that matter + the QGIS `/vsicurl/` one-liner
- [ ] Pipeline chain, every link live: `fresh` → `link` → `flooded` → `drift` → `floodplains` →
      **this repo (publish only)**, stating plainly that no modelling happens here
- [ ] Credits, two distinct debts: *method/software* (Devin Cairns / BlueGeo — VCA, MIT; USDA VCA
      Toolbox; Simon Norris / `bcfishpass`, Apache 2.0) and *data* (Impact Observatory, NRCan,
      Province of BC — shortened from the current #47 text)
- [ ] Licence in two sentences; the "Why CC BY 4.0 outbound" table **kept in the repo** but moved
      off the first screen
- [ ] Sister collections on the same endpoint

## Phase 5: Move the internals out, retire the generator

- [ ] Add a **Prerequisites** section to `scripts/README.md` (uv, R, AWS credentials,
      `$FLOODPLAINS_DATA`) — the one part of the moved content it does not already cover
- [ ] Delete `## Pipeline`, `### Guards`, `## Prerequisites` from the README; link
      `scripts/README.md` in one line
- [ ] `git rm scripts/readme_coverage-table.py`
- [ ] Rewrite `scripts/README.md` step 6 of "Cut a release": name the Rmd render, and say the table
      can be regenerated from a **different machine** than the one that cut the release — it is past
      the tag, a repo-content commit, not part of publishing
- [ ] Re-grep for the retired script; expect hits only under `planning/archive/`

## Phase 6: Render, publish, verify

- [ ] Render both targets; commit `README.md`, `index.html`, `fig/coverage.png`,
      `data/readme_items.rds`
- [ ] Add `.nojekyll`
- [ ] Enable Pages: `gh api -X POST repos/NewGraphEnvironment/stac_floodplains_bc/pages` with
      `source.branch=main`, `source.path=/` (matching `stac_dem_bc`)
- [ ] Verify every changed claim against the artifact, not against the old README (#26's
      release-note lesson: derive each number from what it describes)

## Validation

- [ ] `README.md` comfortably under 150 lines and opens with what the catalogue *is*
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
