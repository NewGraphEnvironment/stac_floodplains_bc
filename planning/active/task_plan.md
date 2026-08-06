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
