# Findings — Publish floodplain.gpkg delineations (#8)

## Issue context

## Problem

Each item currently publishes the classified/transition rasters plus one vector asset
(`floodplain_landcover` -> `floodplain_landcover.gpkg`). The upstream `floodplain.gpkg` —
which holds the delineated floodplain polygons at all three run=TRUE flood-factor scenarios
(`*_ff02`, `*_ff04`, `*_ff06`) — is read at staging only to derive the item footprint
geometry (`01_stage.R:137`) and is then dropped. It is never copied to `data/stac/` or
registered, so the ff02/ff04/ff06 delineated areas are not downloadable from the catalog.

Two gaps follow:

- **Geometry / asset:** only the `ff04` footprint is represented (as the item geometry). The
  narrower (`ff02`) and wider (`ff06`) delineations can't be retrieved at all.
- **Properties:** the only area exposed is `floodplain_km2` (ff04; `01_stage.R:139/166` ->
  `05_stac_register.py:90`). An item can't be browsed, filtered, or compared on the ff02 /
  ff06 areas without downloading the gpkg.

## Proposed Solution

Publish the `floodplain.gpkg` delineations as a second vector asset **and** surface all three
areas as item properties. A schema break is acceptable here — this is a brand-new collection
with a single consumer, so no back-compat alias is warranted.

### Vector asset

- `01_stage.R` — also copy `floodplain.gpkg` into `data/stac/<wsg>/` (one file already
  carries all three ff layers; no per-scenario split needed).
- `05_stac_register.py` — add a vector asset keyed `floodplain` (no clash: the landcover
  asset is keyed `floodplain_landcover`), GeoPackage media type.
- `04_s3_upload.R` — no change (the sync already globs `*.gpkg`).

### Per-frequency area properties

- Rename `floodplain_km2` -> `floodplain_ff04_km2`; add `floodplain_ff02_km2` and
  `floodplain_ff06_km2`. No bare `floodplain_km2` alias — full symmetry, clean break.
- `01_stage.R` today reads only `area$primary_scenario` (`:137`) and computes one area
  (`:139`). Amend to read all three run=TRUE layers from the same `floodplain.gpkg` and
  compute each area, deriving the sibling layer names by swapping the flood-factor token
  (`*_ff04` -> `*_ff02` / `*_ff06`) rather than hard-coding — keeps it species-agnostic
  (`co_` / `ch_` / `bt_`). Write all three `floodplain_ff0{2,4,6}_km2` into `meta.json`
  (replacing the single key at `:166`); update the log line at `:177`. Keep the ff04 layer
  as the item footprint geometry (`:136-137`, unchanged).
- `05_stac_register.py` — swap the single `floodplain_km2` in the properties dict
  (`:84-90`) for the three `floodplain_ff0{2,4,6}_km2` keys; update the labelled-properties
  list in the module docstring (`:8`) and the collection description if it enumerates
  properties (`:165-168`).

### Guard, sweep, publish

- Fail loud (or write NA) in `01_stage.R` if any of the three ff layers is missing from a
  WSG's `floodplain.gpkg`. `flood_scenarios.csv` marks ff02/ff04/ff06 as run=TRUE, but a
  per-area config could skip one, and the 15 items must not end up with inconsistent
  property sets.
- Grep the repo (and any downstream rtj / QGIS references) for `floodplain_km2` and
  rename/remove every hit — the break is only clean if nothing dangles.
- `README.md` — item-model section: document the two vector assets, the three ff extent
  layers, and the three area properties.
- Re-publish all 15 items; reload pgstac from rtj to go live.

## Acceptance

- All 15 items carry `floodplain_ff02_km2` / `floodplain_ff04_km2` / `floodplain_ff06_km2`
  and the `floodplain` vector asset.
- Zero `floodplain_km2` references remain in the repo or downstream consumers.
- Collection reloaded on `images.a11s.one`; item count unchanged at 15.

## Note (non-blocker)

wsg tagging of the extent layers isn't covered by #5 (landcover-only). Each item is a single
WSG, so wsg is implicit in the item ID — it only matters for downstream cross-WSG merges,
which can derive it. Leave the extent gpkg as-is unless a merge consumer needs the column.

Relates to #5


## Exploration (2026-07-18)

- `floodplain_km2` refs (grep): 01_stage.R:139,166,177; 03_cog_tag.py:24 (COG tag FLOODPLAIN_KM2); 05_stac_register.py:8,90; README.md:80,97; test_pipeline.R:53,60.
- Three run=TRUE ff layers (ff02/04/06) confirmed in config/*/flood_scenarios.csv and present in every floodplain.gpkg; uniform `<sp>_ff0X` naming across co/ch/bt.
- Plan-agent review folded in 5 findings: atomic 01+03+05 property rename (05 KeyErrors); scripts/README.md is a second doc surface (prose, grep-invisible); root README mislabels landcover asset as `floodplain`; add positive presence check not just deletion; add `stopifnot(endsWith(scenario,'_ff04'))` guard.
- Verified non-issues: test_pipeline `length(cogs)==4` globs .tif (gpkg safe); 02_cog.R globs data/raw/**/*.tif (won't COG the gpkg); 03 globs *.tif (gpkg untagged, correct); 04 sync uploads both gpkgs; projection ext is item-level (asset template copy is safe).

## floodplains#23 (multi-species per area) — compatibility check

#23 lets two species coexist in shared `data/<area>/` gpkgs (e.g. MORR chinook + coho), so a
single `floodplain.gpkg` could hold `co_ff0{2,4,6}` AND `ch_ff0{2,4,6}`. #8 is forward-compatible:
it derives layers by token-swap from `area.yml`'s primary-species `scenario`, reading only that
species' three ff layers — a second species' layers are correctly ignored. Constraint preserved
in the plan: select by species prefix, never positionally. Publishing a second species as its own
STAC item (`morr_ch_ff04`) is a separate future issue, not #8. No blocking dependency either way.
