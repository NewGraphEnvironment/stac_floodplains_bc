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

- [ ] Snapshot the live collection + 17 live item JSONs to scratch (versioning **Suspended**)
- [ ] `md5` current `data/stac/*.json`; confirm 17 `data/raw/*/meta.json` so the fast path is
      provably operating on the tree that produced what is live

## Phase 1: Add the properties

- [ ] `05_stac_register.py` — add `scenario` + derived `flood_factor` to item `properties`; parse
      the factor from the scenario suffix and **fail loudly** on a non-matching suffix rather than
      emitting `None`
- [ ] `05_stac_register.py` — collection `summaries` with distinct scenario values, computed from
      the built items so it cannot drift

## Phase 2: Guard the contract

- [ ] `test_pipeline.R` — assert the built `<item_id>.json` carries `scenario` == `meta$scenario`
      and a consistent `flood_factor`. **New kind of assertion**: the test currently reads
      `meta.json` only and never inspects item-JSON `properties`, which is why this gap survived

## Phase 3: Docs

- [ ] `README.md` — add `scenario` + `flood_factor` to the published-properties list
- [ ] Add a scenario filter to the `rstac` example — the only place a reader learns what is queryable

## Phase 4: Republish + verify

- [ ] Run `05`, then **diff rebuilt JSON against the live item JSONs**: only differences may be the
      two added properties (+ collection `summaries`)
- [ ] `item_validate.py`, then `catalogue_release.sh`
- [ ] Verify live: all items carry `scenario`; `morr_ch_ff06` reports ff06 / factor 6, the other
      sixteen ff04 / 4; collection `summaries` lists the distinct values
- [ ] **`POST /search` filtered to `scenario = ch_ff06` returns exactly `morr_ch_ff06`** — the
      user-visible point of the issue

## Validation

- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
