# Findings — Publish the transition layer as its own asset (#23)

## The near-miss

`05_stac_register.py:135` keys the transition COG as `f"transition_{span[0]}_{span[1]}"` =
`transition_2017_2023` — **exactly the stem** of the `transition_2017_2023.gpkg` filename the issue
proposed. Keying the new gpkg by its stem would have overwritten the COG entry in the `assets` dict.
The failure is invisible from every angle we have: item count stays 6, `item_validate.py`'s key-set
check passes because every item loses the same key uniformly, and the release probe picks the
largest asset (the bundle), never the raster. Confirmed against live JSON before choosing a name.

## Naming, and why it reaches the layer

Year-free at all three levels — asset key `transition_vector`, file `transition_vector.gpkg`, layer
`transition`. QGIS styles and `.qlr` bind to `path|layername=`, so any span in the name breaks
downstream symbology when the model is re-run (2017-2023 → 2017-2025 → 2010-2025 on satellite).

Generic layer naming is safe here specifically because this file is per-item and single-layer.
Upstream keeps `transition_<sp>_<scenario>_<span>` because two species share one gpkg; identity here
is carried by the item id and the layer's own `wsg`/`species`/`scenario` columns. Span stays
recoverable from `start_datetime`/`end_datetime`.

## Source layer selection

`01_stage.R:190-193` already builds the name:

    paste0("transition_", scenario, "_", TRANSITION_SPAN[1], "_", TRANSITION_SPAN[2])

Verified present in all 20 items. For MORR it picks `transition_co_ff04_2017_2023` for the coho item
and `transition_ch_ff06_2017_2023` for the chinook item **out of the same 79 MB shared file**.

MORR and BULK also carry `_fire` and `_disturbance` variants (BULK's `_fire` is schema-identical to
the base; `_disturbance` adds `in_harvest`/`harvest_start_year_calendar`). Extract the **base** only:
uniformity is what `item_validate.py` enforces, and #6 owns disturbance attribution.

`tree_transition_metrics()` at `:81-89` drops geometry, so it cannot be reused to write the layer —
the extraction needs its own read.

## Gotcha: ogrinfo layer names

`ogrinfo -so` appends the geometry type to most layer names but **not** to MORR's
`transition_co_ff04_2017_2023`, whose declared geometry is `Unknown (any)`. A suffix-assuming or
`$`-anchored regex silently misses exactly one layer in the catalogue. `sf::st_layers()$name`
returns clean names and is what `01_stage.R:163` already uses.

## The pin (floodplains#45)

    FP_GPKG_EPOCH <- "2000-01-01T00:00:00.000Z"
    Sys.setenv(OGR_CURRENT_DATE = FP_GPKG_EPOCH)

Process-wide env var, deliberately not per-call `st_write(config_options=)` — upstream's rationale is
that GDAL reads config from the environment so one call covers every write, whereas per-call args
"are silently incomplete the moment someone adds the 14th".

**Bound**: byte-reproducible writing into an **absent** file. Rewriting a layer into an existing gpkg
is not (SQLite free-page state; `VACUUM` does not close it). So `unlink()` before writing.

Upstream's check uses `Sys.sleep(1.2)` between rebuilds — the unpinned stamp has 1 ms resolution, so
two same-instant writes give a false PASS. Its cold path uses `Sys.unsetenv()` rather than merely not
setting, because a parent process may have exported the pin.

Upstream measured an 18-layer replay of the same MORR file. Corroborating but **not the same
operation** as a 1-layer extract — hence the Phase 0 probe.

## Sizes (measured on the staged tree)

| item | bundle | base transition geometry | layers |
|---|---:|---:|---:|
| morr_co_ff04 / morr_ch_ff06 | 79.0 MB (shared file) | 1.24 MB | 18 |
| bulk_co_ff04 | 41.7 MB | 4.05 MB | 6 |
| ufra_ch_ff04 | 19.1 MB | 3.10 MB | 4 |
| sloc_bt_ff04 | 6.3 MB | — | 4 |

The issue's "38.1 MB bundle vs 5.8 MB layer" is a stale single-item figure inherited from
`floodplains`; no currently staged item is 38.1 MB. The ratio holds.

## Downstream impact

`item_validate.py` — **no change**. It derives `expected_keys` from the longest observed key set, so
a 7th asset on all items passes. A partial rebuild fails, which is correct.

`03_cog_tag.py` — no change (`*.tif` glob only), which also means the new gpkg is byte-final the
moment it is written.

`catalogue_release.sh` — no change. The asset sync is subtractive (`--exclude '*.json'`), so a new
`.gpkg` ships automatically; the step-5 probe is data-driven and still selects the bundle as largest.
Note the probe samples one asset of one item, so it will never exercise the new asset.

`scripts/README.md:34-35` claims GeoPackages are "`file.copy()`d from upstream and never rewritten
here, so their bytes — and therefore their checksums — are exactly upstream's". **This change makes
that false**, and it is load-bearing for the checksum reasoning.

## For #19 (not this issue)

`stac_dem_bc` has the pattern: `DESCRIPTION` is `Type: Project` pinned at `0.0.0.9000` and
**deliberately not versioned** (it exists for GHA dependency resolution); the version lives in
`NEWS.md` + git tags, where "a tag means the catalogue is in this state" — not the scripts.
