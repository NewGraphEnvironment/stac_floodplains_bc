# Findings — Carry wsg into published gpkg assets (#5)

## Issue context

## Problem

The published `floodplain_landcover.gpkg` assets carry no reliable watershed-group identifier, so a
consumer merging several items into one GeoPackage (rtj QGIS projects; any cross-area analysis)
cannot separate areas by attribute. Classified layers have `class_name` only; transition layers have
`name_basin`, whose values are inconsistent across areas (`"Morice"` for MORR vs `"pars"` for PARS).

**The fix is upstream.** These GeoPackages are produced by the `floodplains` driver and copied whole
by `01_stage.R` — this repo does no modelling, so the `wsg` column must be written at generation
time: **NewGraphEnvironment/floodplains#30**.

## Scope of this issue (publish side only)

Gated on floodplains#30 landing:

- **Republish** all items so the assets carry the new column (no code change expected — `01_stage.R`
  copies the gpkg whole; the 16 items regenerate from the same pipeline).
- **Verify** the column is present and correctly valued in the published assets; consider adding an
  assertion to `scripts/test_pipeline.R` (R side — the Python env carries no vector reader).
- **Reload** pgstac from `rtj` so the refreshed assets are served.

## Acceptance

- Every published `floodplain_landcover.gpkg` layer (classified + transition) carries `wsg`.
- All 16 items republished and reloaded; item/asset structure otherwise unchanged.

## Notes

Since #11, MORR publishes two items sharing one gpkg (`morr_co_ff04` + `morr_ch_ff06`). Species and
scenario stay separable via the existing generic layer names (`classified_ch_ff06_2017`), so `wsg`
alone is sufficient — no per-species column needed.

Blocked by NewGraphEnvironment/floodplains#30. Prior reload precedent: rtj#198.


## Exploration + Plan-agent review (2026-08-05)

- Upstream floodplains#30 merged AND data regenerated: every floodplain_landcover.gpkg layer
  carries wsg+species+scenario (MORR 18 layers, BULK 6, others 4). Values = uppercase WSG code.
- floodplain.gpkg layers are geometry-only (zero attributes) -> assertion must be scoped to
  floodplain_landcover.gpkg or it fails on all items.
- Bucket versioning is Suspended; 01_stage.R wipes gitignored data/ -> snapshot before publish.
- 04_s3_upload.R has no --size-only (load-bearing): LCHL floodplain.gpkg is byte-identical in
  size to S3, so a --size-only optimization would silently skip the refresh.
- KISP (Kispiox chinook) newly rostered upstream in config/regions/skeena_ch.yml, data-complete;
  region: skeena (same label as skeena.yml, no roster conflict); no targets -> kisp_ch_ff04.
  ff02 210.86 / ff04 246.74 / ff06 274.74 km2; loss 267.9 / gain 937.2 / net +669.3.
- Loss/gain recomputed from regenerated source match the current README for all 16 ->
  upstream changed SCHEMA ONLY.
- Gotcha: ogrinfo -so appends '(Multi Polygon)' on only some layers; a $-anchored layer-name
  regex produced a FALSE 'missing column' result during exploration. Never anchor that way.
