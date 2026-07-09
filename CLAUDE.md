# stac_floodplains_bc

Publish layer for the floodplain land-cover-change collection `stac-floodplains-bc`. Takes the
per-watershed-group outputs produced by the [`floodplains`](https://github.com/NewGraphEnvironment/floodplains)
driver, converts rasters to COGs, uploads to `s3://stac-floodplains-bc` (us-west-2), and
registers a STAC collection served by the shared `geoserv` pgstac/titiler stack at
`images.a11s.one`.

## Core principle

**No modelling here.** All floodplain + LULC + transition computation lives upstream in
`floodplains` (which uses the `link` / `flooded` / `drift` packages). This repo only stages,
COG-converts, tags, uploads, and registers. If a number needs recomputing, fix it in
`floodplains`, re-run there, and re-publish.

## Layout

- `scripts/01_stage.R` … `05_stac_register.py` — the five publish steps (see `scripts/README.md`).
  `run_pipeline.sh` chains them. Source data comes from `$FLOODPLAINS_DATA` (default
  `../floodplains/data`).
- `environment.yml` — conda env `stac-floodplains-bc` (pystac / rasterio) for steps 03 + 05.
- `data/` — gitignored (`raw/` staged inputs, `stac/` COG + item outputs).

## Collection model

Shared `stac` DB → `images.a11s.one` (NOT a dedicated subdomain; only `ortho` has its own DB).
One item per watershed group: `<wsg>_<sp>_ff04`. Raster assets = 3 classified years +
transition COG; vector asset = `floodplain_landcover.gpkg`. Loss/gain/net properties are
computed from the transition layer at register time so published figures trace to the model.

## Catalog registration (rtj)

The bucket and the geoserv server are managed in [`rtj`](https://github.com/NewGraphEnvironment/rtj).
Item load runs there: `scripts/geoserv/stac_register-pypgstac.sh stac-floodplains-bc <s3-base>`
(and the collection is listed in `stac_register-all.sh`).

## Visibility

Private for now (`.claude/visibility` = internal). Flip to public when the collection is
published and the underlying data is cleared for release — see the New Graph publication-flip
convention.

<!-- BEGIN NGE SOUL CONVENTIONS (managed by /claude-md-init) -->
<!-- Run /claude-md-init to sync New Graph soul conventions below this marker. -->
<!-- END NGE SOUL CONVENTIONS -->
