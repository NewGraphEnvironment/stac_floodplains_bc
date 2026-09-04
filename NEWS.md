# stac_floodplains_bc

Versions describe the **published catalogue** — the state of `s3://stac-floodplains-bc` and
the collection served at <https://images.a11s.one/collections/stac-floodplains-bc>. They do not
track the scripts independently: a tag means "the catalogue is in this state". Same convention
as [`stac_uav_bc`](https://github.com/NewGraphEnvironment/stac_uav_bc) and
[`stac_dem_bc`](https://github.com/NewGraphEnvironment/stac_dem_bc).

The version is stamped onto the collection by the release, not the build, from the tag the
release is cut at (`scripts/catalogue_release.sh`; recipe under "Cut a release" in
`scripts/README.md`). There is no `DESCRIPTION`; releases live here and in git tags.

## Unreleased

The next full release publishes **23 items** — the 20 live today plus `lnth_ch_ff04`,
`thom_ch_ff04` and `unth_ch_ff04` — with `PROVENANCE_FLOOR=21`, the exact count this build
carries. No item is dropped, so no `--allow-retract`.

- The collection now states its licence and credits its sources (#47). It publishes
  `license: CC-BY-4.0` in place of `proprietary`, a `rel: license` link, six `providers`,
  a `rel: derived_from` link to the source collection, and `sci:citation`. The products are a
  derivative of Impact Observatory's `io-lulc-annual-v02` (CC BY 4.0, via Planetary Computer),
  delineated off MRDEM-30 (OGL-Canada-2.0) and the BC Freshwater Atlas (OGL-BC) — all
  attribution-only, none share-alike, so CC BY 4.0 outbound is permitted. CC BY also obliges a
  statement that the input was **modified**, which now ships in the collection description
  along with the one-sentence caution that every year is read from one release and so cannot
  manufacture change. `proprietary` was wrong in both directions: it claimed a restriction we
  do not hold and withheld credit the source licence obliges.
- The repo carries an MIT `LICENSE` for the scripts, matching `stac_dem_bc` and `stac_uav_bc`,
  with a README **Attribution** section stating the split and the reasoning behind the outbound
  licence. `pyproject.toml` names the same MIT.
- `item_validate.py` gates all of it absolutely — `check_collection_metadata` (licence,
  providers as whole records, both links, `sci:citation` verbatim, and the extension declared
  iff the field is present) and `check_citation_premise`, which refuses a build whose items name
  a landcover collection — or a STAC URL — the published citation does not attribute; the id and
  the host move independently, and a host move alone would change the licensor. pystac covers one of the
  four ways this can go wrong — it refuses the extension declared with no field — and none of
  the other three: a field published without its extension is invisible to it, and
  `sci:citation` is only `type: string`, so no schema can tell the right attribution from
  the wrong one.
  Step 5 of the release then reads the licence back from the API **and** the bucket, because
  publishing a field is not serving it.

- `nge:landcover_key` now publishes a fingerprint of the landcover produced: the producer's
  per-year content digests (floodplains#64), folded to one `sha256:` value over the lines
  `<year>=<digest>`, years ascending, newline-joined. It previously carried a hash over the
  resolved STAC item ids, which an in-place upstream re-derivation cannot move; that value ships
  under its own name as the twelfth property, `nge:landcover_item_hash` (#40).
- The provenance reader accepts the producer's `schema_version` 2 and refuses a stage whose
  landcover rasters are newer than the record describing them.
- A full release now passes an operator-set provenance floor to the validator (#32): the exact
  number of items carrying a non-null `nge:` value, recorded as a literal beside each release.
  `--only` refuses to replace a live item's provenance with nulls.

- The three GeoPackages now open in QGIS already styled (#46). A `layer_styles` row per feature
  layer carries a renderer generated from the same `data/raw/classes.json` that feeds the raster
  attribute table and `classification:classes`, so the vector and raster views of one item cannot
  colour the same ground differently. The styles ship as STAC assets too — `style_floodplain`,
  `style_classified`, `style_transition`, `roles: ["style"]` — for merged multi-item GeoPackages
  and for consumers who disable default styles. Transition patches are coloured by destination
  class; the eight `Trees -> *` loss categories ship switched on and the other 64, gain included,
  ship off. All vector symbols at 50% opacity. Adds ~208 KB per `transition_vector.gpkg` (+5.5%).

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
