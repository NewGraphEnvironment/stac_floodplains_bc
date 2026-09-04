# #53 — README rebuilt from README.Rmd into a landing page and a Pages site

Closed by PR #54 (merge `6446994`), with PR #56 (`5893057`) adding per-asset download links,
a fullscreen control, and the "Read this before you use the numbers" section.

`README.md` went from **307 lines / 2,592 words to 150 / 1,892**, gained three figures it never
had, and is now generated from `README.Rmd` alongside `index.html`, served at
<https://www.newgraphenvironment.com/stac_floodplains_bc/>. One guarded `rstac` call feeds both
the coverage figure and the coverage table, retiring `readme_coverage-table.py` (#41).

## Measurement

- Item geometry is **1,448,930 vertices / 45 MB**, and `st_simplify` at 222 m still yields
  **11 MB** of GeoJSON. That is what decided the interactive map's content: watershed-group
  polygons with per-item popups, while the static PNG carries the floodplain ribbons at full
  detail. Not an aesthetic call.
- 7,273 km² of floodplain over a ~950,000 km² province is ~1.2 km/px on a 1000 px-wide map, so a
  500 m ribbon is sub-pixel — which is why the figure needs a watershed-group layer at all.
- The ported R table reproduces the retired Python generator row for row against the live API:
  **7,273 km² / 17,008 ha lost / 13,775 ha gained / −3,233 ha net**.
- **230 of 230** published asset links verified 200; **230 of 230** popup links verified to belong
  to their own item.
- Both render targets are **byte-identical** across runs from an unchanged cache.

## Five defects, none found by reading code

| defect | how it would have shipped |
|---|---|
| 22 of 23 popups carried another group's area | correct item name beside a plausible wrong number |
| a missing property rendered the total as the string `"NANA"` | `n_distinct(c(NA,NA))` is 1, so the guard agreed with itself |
| an `ff02` item shown its `ff06` area | 251.21 where 218.36 was right |
| the DT table printed literal `**Total**`, sorted `1,052` between `101` and `117` | under a caption telling readers to click those sort arrows |
| the column headed **Scenario** carried flood-factor values | the page's own `ext_query(scenario == "ff06")` example returns nothing |

Two came in with the Python→R port and are unreachable in the original; two were introduced while
fixing other findings. All were caught by inspecting rendered artifacts — a widget's JSON payload,
a popup, a table cell — never by reading source.

## Wrong turns worth keeping

- **Three broken probes, each of which briefly looked like a real defect.** A constructed
  `style_classified.qml` URL 403'd on every item and read as missing objects (the file is
  `classified.qml`); two substring checks reported the safety section and the `floodplains` link
  absent, defeated by hard-wrapped HTML. The tell each time was an implausible failure in
  something just watched working.
- **`opt_tm_text(halo = TRUE)`** draws the string again at each offset rather than blurring it, so
  22 labels rendered as 110 smeared copies. A white `shadow` is the working form.
- **The attribution drift check shipped, in its first version, with the defect it exists to
  catch** — its constant arms asked whether a literal appeared *anywhere* in `item_create.py` and
  stayed silent through a `v02` → `v03` mutation, because a comment still named `v02`.

## Facts corrected by checking rather than copying

`bcfishpass` is not flatly Apache 2.0 — three-part `LICENSE`, and the **ODbL** database section
*is* share-alike, which sat a few lines from `ATTRIBUTION.md`'s "none is share-alike". The USDA
VCA Toolbox URL is dead **while returning 200**, redirecting to a generic station page.

## Evidence

`planning/archive/2026-09-issue-53-readme-rmd-landing-page-and-site/review-*.md` — one plan review
and two code-check rounds, each with disposition recorded per finding.
