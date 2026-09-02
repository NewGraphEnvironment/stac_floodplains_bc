# stac_floodplains_bc

Versions describe the **published catalogue** — the state of `s3://stac-floodplains-bc` and
the collection served at <https://images.a11s.one/collections/stac-floodplains-bc>. They do not
track the scripts independently: a tag means "the catalogue is in this state". Same convention
as [`stac_uav_bc`](https://github.com/NewGraphEnvironment/stac_uav_bc) and
[`stac_dem_bc`](https://github.com/NewGraphEnvironment/stac_dem_bc).

The version is stamped onto the collection by the release, not the build, from the tag the
release is cut at (`scripts/catalogue_release.sh`; recipe under "Cut a release" in
`scripts/README.md`). There is no `DESCRIPTION`; releases live here and in git tags.

## v1.0.0 (2026-09-02)

First versioned release of the catalogue — **20 items** across 19 watershed groups in four
regions (Columbia, Fraser, Peace, Skeena), every one rebuilt from the current `floodplains`
outputs and republished together. `bulk_co_ff04` had been republished alone as the `--only`
pilot (#36, 2026-09-02); for the other 19 this release is the first publication carrying the
COG-layout, class-label and checksum changes below. It is the first state the live catalogue
can name.

- One item per `(watershed group, species, scenario)` target, id `<wsg>_<sp>_ff0N` (#11): 19
  chinook / bull trout / coho `ff04` functional-floodplain items, and `morr_ch_ff06`, the one
  valley-bottom scenario, beside `morr_co_ff04`. `scenario` and `flood_factor` are queryable
  item properties and collection summaries (#9), so cross-group aggregates can filter on them.
- Seven assets per item: `classified_2017` / `_2020` / `_2023` and `transition_2017_2023`
  Cloud-Optimized GeoTIFFs, plus `floodplain_landcover.gpkg`, `floodplain.gpkg` (ff02/ff04/ff06
  delineations, #8) and `transition_vector.gpkg` (the transition patches alone, #23). Every
  layer carries `wsg` / `species` / `scenario` (#5).
- Rasters are valid COGs (#33), carry the class-label RAT inside the `.tif` and declare
  `classification:classes` from the same `classes.json` (#34/#35), and every asset publishes
  `file:checksum` + `file:size` (#22).
- Every item carries 11 `nge:` run-provenance properties (#17). A published null is stored by
  pgstac but omitted by the API, so from the API those read as absent.
- The release system (#14, #36, #19): rebuild is `run_pipeline.sh` and makes no network
  writes; publish is `catalogue_release.sh` (validate → sync → register → verify), with
  `--only <item_id>` republishing one live item and never the collection. From this release
  a full release is a tag: the release refuses unless HEAD is exactly at a `vX.Y.Z` tag that
  this file's top entry names, stamps that version onto the collection (STAC Version
  Extension), and fails unless the API and the bucket serve it back.
