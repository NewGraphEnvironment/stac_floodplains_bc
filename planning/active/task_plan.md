# Task: Expose scenario (flood factor) as a queryable STAC item property (#9)

The published flood factor is captured as a GDAL tag and used in the item title, but it is **not** in
the STAC item `properties` — `05_stac_register.py:96-98` sets `wsg`, `species`, `region` and omits
`scenario`. So an item's flood factor is not STAC-queryable.

This is a **documented contract we are not honouring**. The `floodplains` README states that
`wsg`/`species`/`scenario` are each "a STAC **property** (to select items) and a gpkg **column**".
The gpkg-column half is enforced here by `test_pipeline.R` (added in #5); the STAC-property half
silently isn't. Second asymmetry: `03_cog_tag.py:23` already tags `SCENARIO` on every COG, so a
**downloaded GeoTIFF knows its flood factor while the STAC item pointing at it does not**.

No longer latent — `morr_ch_ff06` is live alongside sixteen `ff04` items, and ff04 (functional
floodplain) vs ff06 (valley bottom) are genuinely different extents.

## Approved decisions

| Decision | Choice |
|---|---|
| `flood_factor` | **Yes** — numeric 2/4/6 alongside the `scenario` string |
| Collection `summaries` | **Yes** — scenario values (collection has none today) |
| Naming | **Bare `scenario`**, not `nge:scenario` — consistent with its `wsg`/`species`/`region` siblings |

`flood_factor` is genuinely numeric: `flooded/R/fl_flood_surface.R:26` defines
`flood_depth = bankfull_depth * flood_factor`, so ff02/ff04/ff06 are 2×/4×/6× bankfull depth.

## Backfill is the fast path, not a rebuild

Staging inputs do not change, so `01`–`03` need not re-run:
`05` (3.9s) → `item_validate.py` (~1.5 min) → `catalogue_release.sh` (~2 min).
A full `run_pipeline.sh` would be ~20 min of COG conversion for identical rasters.

## Phase 0: Baseline

- [x] Snapshotted the live collection + 17 live item JSONs to scratch.
- [x] Fast path proven safe: all 17 local item JSONs are **byte-identical to what is live**, and
      `data/raw` holds 17 `meta.json` — so the rebuild operates on exactly the tree that produced
      production.

## Phase 1: Add the properties

- [x] `05_stac_register.py` — `scenario` + derived `flood_factor` added; `flood_factor()` raises on
      a non-matching suffix (verified: `ch_ff` / `nonsense` / `ff04_ch` all rejected, exit 1).
- [x] `05_stac_register.py` — collection `summaries` for scenario/species/region/flood_factor,
      computed from the built items.
- [x] **Review caught two real defects, both fixed:**
      1. `flood_factor` was published as a **Range Object** `{minimum:4, maximum:6}` — a continuous
         interval over a discrete set, so it advertised `flood_factor = 5` as available. A client
         building a filter list from the summary would offer 5 and get nothing. Now a Set of Values,
         `[4, 6]`.
      2. Items are written to disk one at a time, so a `flood_factor()` failure partway would leave
         a **mixture** of fresh and stale item JSONs beside a stale `collection.json` — and that
         mixture passes every release guard (collection present, count right, all valid, no
         orphans), so it would publish. Added a preflight over every scenario before the first
         write. Verified: with a corrupted scenario, no item JSON is rewritten and `05` exits 1.

## Phase 2: Guard the contract

- [x] `test_pipeline.R` asserts the built `<item_id>.json` carries `wsg`/`species`/`scenario`/
      `region` matching `meta.json`, plus a `flood_factor` consistent with the scenario.
- [x] Proven against all 17 real items, and every negative caught: property missing, `flood_factor`
      missing, `flood_factor` wrong, `scenario` mismatched.
- [x] `WSG=morr Rscript scripts/test_pipeline.R` PASS — the ideal case, since MORR stages both an
      `ff04` and an `ff06` item, so the derived factor is exercised on both values.

## Phase 3: Docs

- [x] `README.md` — properties list gains `scenario` + `flood_factor`, with the item-key explanation
      and a warning that the collection mixes flood factors so aggregates must filter.
- [x] `rstac` examples gain a server-side filter and a summaries lookup. **Review fix:** the filter
      originally used `scenario == "ch_ff06"`, which is species-pinned and would silently miss a
      future `co_ff06`/`bt_ff06`; now `flood_factor == 6`.

## Phase 4: Republish + verify

- [x] Structural diff vs live: across all 17 items the ONLY change is the two added properties —
      nothing removed, no value changed, `geometry`/`bbox`/`assets`/`links`/`id`/`title` identical.
      Collection: `summaries` is the only added key.
- [x] `item_validate.py` clean, then `catalogue_release.sh` — published in 2m9s, assets correctly
      unchanged, asset probe matched.
- [x] Live: 17/17 carry both properties — `ch_ff04` x11, `bt_ff04` x3, `co_ff04` x2, `ch_ff06` x1;
      collection `summaries` serves scenario/species/region/flood_factor.
- [x] **Server-side queries work**: `flood_factor eq 6` -> exactly `morr_ch_ff06`; `eq 4` -> the
      other 16; `scenario eq co_ff04` -> `bulk_co_ff04` + `morr_co_ff04`; and the range query
      `flood_factor gte 6` -> `morr_ch_ff06`, which is the reason for making it numeric.

## Validation

- [x] `/code-check` clean (2 real defects found and fixed)
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
