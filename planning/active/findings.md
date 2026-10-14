# Findings — Stage each item's GeoPackages with only that item's layers (#80)

## Issue context

Split out of #75, which was the reader change only. The decision is already made and recorded in
#75's body under "Decided (2026-10-14)"; this issue is where it gets built.

## The problem is the data, not the bookkeeping

`01_stage.R:299-306` copies `floodplain.gpkg` and `floodplain_landcover.gpkg` **whole** into every
item directory. That was self-describing while a shared bundle held two species' layers. It stops
being self-describing the moment a group is whole-network, because the retired species layers stay
on disk until floodplains#131 prunes them.

Measured 2026-10-14 on `../floodplains/data/bulk/`, which `bulk_all_ff04` would publish today:

| file | the item's own layers | layers that are not the item's |
|---|---|---|
| `floodplain.gpkg` | `all_ff02/04/06`, `all_ff04_by_blue_line_key` | `co_ff02/04/06`, `co_ff04_by_blue_line_key` |
| `floodplain_landcover.gpkg` | `classified_all_ff04_2017..2023`, `transition_all_ff04_2017_2023`, `composition_all_ff04_2017_2023`, `patch_watercourse_all_ff04_2017_2023` | the same four families keyed `co_ff04` |

So `bulk_all_ff04` ships BULK's **coho** floodplain and coho transition inside the whole-network
item's own assets. A consumer opening one item finds two different floodplain models — built on
different networks and, after floodplains#117, different DEM grids — with nothing in the item to
say which is current. That is the thing #76 exists to prevent at the catalogue level, happening
inside a single item.

**Nothing catches it.** Verified by reading each gate:

- `test_pipeline.R` asserts only `wsg` per layer, and its comment says why: the bundles are copied
  whole, so `wsg` is the one item-invariant key under that copy.
- `04_gpkg_style.py` styles `floodplain.gpkg` whole-file and the landcover bundle by
  `classified`/`transition` prefix, so the extra layers are styled and valid.
- `item_validate.py` requires every feature layer to carry a style row — satisfied.

## What it costs — re-costed, because the first estimate was wrong

The first framing of this was "every one of the 23 live items has to be republished, on a bucket
with no rollback". That overstates it. A full release syncs the whole tree and re-registers every
item anyway, so the republish **is** the next release, not a cost this change adds. And a moved
`file:checksum` breaks nothing: `item_validate.py` re-hashes the same file, and a consumer
re-downloads. The determinism pin matters so that a churning checksum does not read as "checksums
are unreliable" — a legibility cost, not a data one.

The honest cost is small and mostly one measurement:

1. **A multi-layer deterministic writer.** `fp_gpkg.R`'s `gpkg_write_layer()` unlinks first, which
   is the only case its note calls byte-reproducible; layers 2..N append into a file that now
   exists. Whether a *fresh sequential* append is reproducible (as opposed to the *rewrite* the
   note is about) is an open empirical question — measure it before building on it, two writes of
   the same input compared with `cmp`.
2. **Aspatial tables.** `composition_<scen>_*` and `patch_watercourse_<scen>_*` are registered
   `data_type='attributes'`. They belong to the item and must still ship, but `sf::st_write` does
   not handle them the way it handles feature layers.
3. **A report for layers matching no item** — the decision is explicit that silently skipping is
   wrong, so a new upstream layer family surfaces as a decision rather than as an omission.
4. **Tighten `test_pipeline.R`** from "every layer carries `wsg`" to "every layer carries this
   item's `wsg`/`species`/`scenario`", which only becomes assertable once this lands.
5. One release to republish, and `gpkg_determinism-check.R` extended to the multi-layer case.

## What it buys

- An item whose GeoPackages describe the item. That is the deliverable, and it is worth having for
  one consumer as much as for a hundred — we are the ones who would open `bulk_all_ff04` and find
  a coho floodplain in it.
- Publishing stops waiting on floodplains#131's prune, which becomes disk hygiene.

## Done when

- A staged `floodplain.gpkg` and `floodplain_landcover.gpkg` hold only the item's own layers plus
  its scenario's aspatial tables.
- Two staging runs of the same input produce byte-identical GeoPackages, measured, or the
  determinism claim is withdrawn and the reason recorded.
- A layer matching no item is reported, not skipped.
- `test_pipeline.R` asserts the item key, not just `wsg`.

Relates: #65, #70, #75, #76, NewGraphEnvironment/floodplains#117,
NewGraphEnvironment/floodplains#131


## Upstream layer census, measured 2026-10-14

Enumerated over all 24 area dirs under `../floodplains/data/`, both GeoPackages, via
`gpkg_contents` + `PRAGMA table_info` + `SELECT DISTINCT` (stdlib `sqlite3`, no GDAL).

- **276 of 276** layers carry `wsg`, `species` and `scenario` (floodplains#30), each with
  **exactly one** distinct value. So selection by the layer's own item key is viable, and the
  "missing a key column" and "more than one value" arms are defensive rather than live.
- `data_type`: 246 `features`, 30 `attributes`.
- `sf::st_layers()` and `gpkg_contents` return identical counts on all 10 files spot-checked,
  so the selector walks the surveyed population.

Foreign layers (key matches no rostered item) exist in **3 of 24** groups, all whole-network:

| group | floodplain.gpkg | floodplain_landcover.gpkg | total |
|---|---|---|---|
| bulk | 4 (`co_ff02/04/06`, `co_ff04_by_blue_line_key`) | 10 (`classified_co_ff04_2017..2023`, `transition_`, `patch_watercourse_`, `composition_`) | 14 |
| kisp | 4 (`ch_*`) | 5 | 9 |
| morr | 9 (`co_*` incl. `co_ff04_by_gnis_name`, `ch_*`) | 16 (incl. six `classified_*_patches`) | 25 |

The other 21 rostered groups have none. 218 layers kept, 58 dropped.

### The key asymmetry is a property of the data

`floodplain.gpkg`'s ff02/ff06 delineations carry their **own** flood factor in `scenario`:
measured, layer `all_ff02` has `scenario = "all_ff02"`, `species = "all"`. The item publishes
all three flood factors (ff02/ff04/ff06), so the match there is on `(wsg, species)`.
Every own layer of `floodplain_landcover.gpkg` carries `scenario` == the item's scenario, so
the match there is on all three. Keying `floodplain.gpkg` on scenario would drop ff02 and ff06.

### neexdzii keeps zero layers, correctly

Its layers' `wsg` column reads `BULK` — it is a subset of BULK and
`config/regions/skeena.yml:29` excludes it from the roster, so it never stages. This is why
the zero-layer stop in Phase 2 is a real guard and not a defensive one.

## The writer: `vectortranslate`, one call, no append

Issue item 1 asked whether a **fresh sequential append** is byte-reproducible. The question is
moot: a single `sf::gdal_utils("vectortranslate", ...)` call takes the layer names as trailing
positional arguments and writes all N layers into an absent file in one pass.

Measured (UFRA `floodplain_landcover.gpkg`, 5 layers including one aspatial), two builds 1.3 s
apart:

| arm | result |
|---|---|
| `OGR_CURRENT_DATE` pinned, one call | **byte-identical** (md5 `048bd83e…`, 17,829,888 bytes) |
| pinned, looped `-append` per layer | also byte-identical (different bytes from the one-call form; each route is internally deterministic) |
| **pin unset** | **differ** — the `NO_PIN=1` cold arm can still fire |

Preserved by the copy, checked against the source: `data_type='attributes'` for
`patch_watercourse_*`, the layer schema (`ogrinfo -so` identical but for the file path),
`gpkg_extensions` (4 rows both sides), rtree index tables (16 both sides).

`sf::st_read(src, query = 'SELECT DISTINCT wsg, species, scenario FROM "<aspatial table>"')`
works and returns a plain `data.frame`, so one reader covers feature and attributes layers.

### `gdal_utils()` only WARNS on a layer the source does not hold

Given `options = c("bt_ff02", "nope_missing")` it emits
`GDAL Error 1: Couldn't fetch requested layer 'nope_missing'!` as an R **warning**, not an
error, and leaves a **65,536-byte** file that `sf::st_layers()` cannot open
(`Cannot open data source … Open failed.`). Same shape as `code-check-spatial.md`'s
"`sf::gdal_utils()` does not raise when GDAL cannot open the source". Hence two guards:
stop on any warning from the call, and assert `st_layers(dst)$name` is `setequal()` to the
requested set.

## Size effect, measured

| file | whole copy | item-scoped |
|---|---|---|
| morr `floodplain_landcover.gpkg` | 91.8 MB | 23.1 MB |
| morr `floodplain.gpkg` | 24.5 MB | 12.2 MB |
| kisp `floodplain_landcover.gpkg` | 38.4 MB | 23.9 MB |
| kisp `floodplain.gpkg` | 18.8 MB | 13.2 MB |
| ufra `floodplain_landcover.gpkg` (no foreign layers) | 19.1 MB | 17.8 MB (repack only) |

Every item's `file:checksum` for both assets moves, including the 21 groups with no foreign
layers, because the file is rewritten rather than copied. `catalogue_release.sh` syncs without
`--size-only`, so changed bytes re-upload; nothing refuses a moved checksum.

## Errors Encountered

| Error | Resolution |
|-------|------------|
