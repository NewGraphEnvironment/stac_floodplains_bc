# #95 — the published `layer_styles` was unregistered, so GDAL stopped listing it

Every published `floodplain_landcover.gpkg` carried a correct `layer_styles` row per feature
layer — right QML, right renderer, `f_table_schema` `''`, `useAsDefault` 1 — and QGIS 4.2.1
drew a random single symbol on all of them. 108 styled layers across all 23 items. A full
`item_validate.py` over that tree exits 0, because every style check in the repo read the row
it had written.

**The mechanism is GDAL's, not QGIS's**, and establishing that changed the fix. The GPKG
driver's `LIST_ALL_TABLES=AUTO` default surfaces a table `gpkg_contents` does not register
*only while the file declares no aspatial content*; QGIS's style lookup goes through GDAL's
layer list. That bundle carries the producer's `patch_watercourse_*` and `composition_*`, so
GDAL stopped listing its style table. The other two bundles carry none, which is why they
escaped — and why the #46 measurement that "QGIS auto-styles fine without a `gpkg_contents`
row" was right about the file it was taken on and wrong about this one. Since
`LIST_ALL_TABLES` is a consumer-side open option, unreachable from the published bytes,
registering the table is the only in-file fix.

`04_gpkg_style.py` now registers it as `attributes` in all three bundles with `last_change`
pinned to `GPKG_EPOCH` — the pin is what answers the churn objection that kept the
registration out at #46. Three guards replace one: the row at the SQL level
(`item_validate.py`), GDAL still listing the table (`test_pipeline.R`, `sf::st_layers()`), and
what QGIS actually draws (`scripts/style_reach-check.py`, new, hand-run under the QGIS
bundle's own python). Listing is necessary and not sufficient — a listed, well-formed style
row whose `f_table_schema` is NULL still opens unstyled.

Closed by PR for #95 at `8fa99d4`. All 23 items republish as `v2.0.1`, which must be cut from
a full `run_pipeline.sh` and not from an in-place repair.

## Measurement

The mechanism, on the published `sloc_all_ff04` bytes, three GDALs agreeing — 3.8.5 (`sf`),
3.12.4 (QGIS 4.2.1's own) and 3.13.0 (homebrew): `layer_styles` hidden in
`floodplain_landcover.gpkg`, listed in the other two, and `-oo LIST_ALL_TABLES=YES` brings it
back. So a long-standing heuristic, not a 4.2.1 regression.

Through QGIS itself, same session, before and after — the probe that had never been pointed at
this bundle: the four landcover layers come back `singleSymbol`, the other five correct;
registered, all nine carry the expected renderer at 10 and 91 categories; a de-registered copy
falls back to `singleSymbol`.

`item_validate.py`'s new arm reports **69 of 69** problems on the published tree (23 x 3) and
nothing else, against **exit 0** for the same validator before the arm existed. Two
independent `WSG=sloc` builds give three byte-identical GeoPackages, so the registration does
not cost reproducibility.

Two measurements decided design questions rather than confirming them. `data_type` must be
`attributes` because with `features` QGIS loses the style in **all three** bundles — including
the two #95 never affected — which is a stronger reason than the spec. And `INSERT OR REPLACE`
moves the row's rowid (7 -> 8) and the file's sha256 with it, so the write is
`UPDATE`-or-`INSERT`; the determinism check does not pin that, and says so.

Four code-check rounds, 20 findings, all fixed. Twice the reported fix was measured **not to
work** — a conflict-arm setup that could not fail, and a full-tuple read-back that is
self-referential because the tuple is the writer's own intent. `progress.md` has the round
table and how the loop ended; `findings.md` has the mutation tables.

## Evidence

No committed logs: every measurement here is reproducible from the scripts the branch adds.

- `uv run python scripts/style_determinism-check.py`, and with `NO_PIN=1` — five arms
- `Rscript scripts/gpkg_determinism-check.R`, and with `NO_PIN=1` — three arms
- `WSG=sloc Rscript scripts/test_pipeline.R`, twice, diffing
  `shasum -a 256 data/stac/sloc_all_ff04/*.gpkg`
- `scripts/style_reach-check.py` under the recipe in its own docstring
- `Rscript scripts/prov_census-measure.R` for the floor and census recorded in `NEWS.md`

## Errors Encountered

In `findings.md`, under the two "Errors Encountered" tables. The one worth repeating here:
the conventions repo was checked out on **another task's in-flight feature branch**, and
`git checkout -b` inherited it, so a cross-repo PR opened with ten foreign commits and twenty
files — reading `MERGEABLE / CLEAN` the whole time. Check `git branch --show-current` before
branching in a repo the session did not start in; `git log -1` does not tell you which branch
you are on, and a clean mergeable PR is no evidence of a clean range.
