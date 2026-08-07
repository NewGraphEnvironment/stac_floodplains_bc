# Findings — Expose scenario (flood factor) as a queryable STAC item property (#9)

## The gap, and why it survived

`05_stac_register.py:96-98` builds item `properties` with `wsg`, `species`, `region` — and omits
`scenario`, even though `meta['scenario']` is used two lines above in the item title.

Three things made it invisible:

1. **`03_cog_tag.py:23`** — `SHARED_FIELDS` already includes `"scenario"`, so every COG carries a
   `SCENARIO` GDAL tag. A downloaded raster is self-describing; the STAC item is not.
2. **`test_pipeline.R` never inspects item-JSON `properties`.** It asserts on `meta.json` fields and
   on gpkg columns, so a property missing from the published item passes every existing check.
3. **Every group was `ff04` until #11.** The convention held by accident, so nothing surfaced.

## Upstream already documents this as a contract

`floodplains/README.md:39-42`:

> Every published layer carries the item key — `wsg`, `species`, `scenario` — mirroring the STAC
> item id (`morr_ch_ff06`). The same key is a STAC *property* (to select items) and a gpkg *column*
> (to separate rows once merged)

Both halves are asserted upstream. Only the gpkg-column half is enforced here (`test_pipeline.R`,
added in #5). This issue closes the other half.

## flood_factor is numeric, not a label

`flooded/R/fl_flood_surface.R:21-26` (Valley Confinement Algorithm):

```
bankfull_width = (upstream_area ^ 0.280) * 0.196 * (precip ^ 0.355)
bankfull_depth = bankfull_width ^ 0.607 * 0.145
flood_depth    = bankfull_depth * flood_factor
```

So ff02/ff04/ff06 are 2x/4x/6x bankfull depth — ordinal, and range queries ("at least ff04") are
meaningful. `ff04` = functional floodplain, `ff06` = valley bottom.

## Naming

Bare `scenario`, not `nge:scenario`. Its siblings (`wsg`, `species`, `region`) are all bare, and
introducing a namespace for one property while three unprefixed ones sit beside it is worse than
either convention applied consistently. soul#62 proposes namespaced domain metadata across the stac
family — that is a migration of its own, not something to start mid-dict.

## Backfill path

`data/raw/*/meta.json` already carries `scenario`, so only the JSON build changes. Fast path is
`05` → `item_validate.py` → `catalogue_release.sh` (~4 min total) rather than a full
`run_pipeline.sh` (~20 min of COG conversion producing byte-identical rasters).

Safe because `01_stage.R` is not re-run, so `data/stac/<item>/` assets are untouched — and the
release syncs them unchanged. Guarded by the Phase 0 md5 baseline and the Phase 4 JSON diff.
