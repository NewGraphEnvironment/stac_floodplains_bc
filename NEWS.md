# stac_floodplains_bc

Versions describe the **published catalogue** — the state of `s3://stac-floodplains-bc` and
the collection served at <https://images.a11s.one/collections/stac-floodplains-bc>. They do not
track the scripts independently: a tag means "the catalogue is in this state". Same convention
as [`stac_uav_bc`](https://github.com/NewGraphEnvironment/stac_uav_bc) and
[`stac_dem_bc`](https://github.com/NewGraphEnvironment/stac_dem_bc).

The version is stamped onto the collection by the release, not the build, from the tag the
release is cut at (`scripts/catalogue_release.sh`; recipe under "Cut a release" in
`scripts/README.md`). There is no `DESCRIPTION`; releases live here and in git tags.

**`v2.0.0` is reserved for the release in which every published area carries corrected
geometry.** `mcgr_ch_ff04` and `pine_bt_ff04` cannot be re-run until floodplains#76 is
resolved, so until then a correction release is a minor bump, however much data it moves.
Recorded here because it is a decision (airvine, 2026-09-03) that previously existed only
in conversation — it was in neither #26, #19, any archived planning file, nor the project
memory, and had to be recalled rather than read.

## Unreleased

**The classified year set is now a property of the item, read from the producer's record —
not a three-year constant in this repo** (#61). `floodplains#79` is re-running areas onto an
annual span, so the collection will carry two populations; the code no longer has an opinion
about which. This release changes **code, not data**: no published item moves, and the
republish of the annual areas is #59.

- `01_stage.R` no longer declares `YEARS`. Each item's span is discovered from the
  `classified_<yyyy>.tif` actually staged, and the producer's `landcover.<scenario>.inputs.years`
  is what checks it — that direction, not the reverse. Sourcing both from the record would
  reduce `landcover_key`'s fold to one file's `years` agreeing with the same file's
  `classified_content_sha256`, written by one upstream step moments apart.
- Three absolutes replace the refusal the constant used to give: both ends of the published
  transition span must be classified, the record's own `change_interval` must match it, and a
  year set must be distinct and at least two long. The last one is a latent crash rather than
  a refusal — `jsonlite`'s `auto_unbox` writes a length-1 vector as `{"years": 2017}` and
  `item_create.py`'s `for yr in meta["years"]` then raises `TypeError` three steps downstream.
- `item_validate.py` splits its cross-item asset-key check in two, with the partition written
  down beside it: the non-classified keys are still compared across items, and the
  `classified_*` keys are checked per item against `ALLOWED_YEAR_SETS` — a literal a human
  sets, the same shape as `DEPRECATED_ITEMS` and `PROVENANCE_FLOOR`, because an expectation
  derived from the items cannot fire when the loss is uniform across all of them (#23). Both
  directions: an unsanctioned span is refused, and a sanctioned span no item uses is reported
  as a literal nobody updated. That second arm is the one `--partial` drops, because it asks
  about items a subset legitimately does not contain (#26).
- A new arm compares each item's published `classified_*` assets against the COGs actually in
  its directory. `aws s3 sync` uploads the directory, not the asset list, so a stray COG
  reaching the public bucket described by nothing was caught by no guard in this repo.
- `scripts/stage_years-check.R` and `scripts/year_sets-check.py` are new, and
  `scripts/fp_provenance-check.R` grew 25 cases. Each restores a defect and greps for **that
  guard's own message**: a suite with N guards has N ways to exit 1, and only one of them is
  the evidence. Three arms at the staging call site (a raster the record names and disk
  lacks; a raster on disk the record does not name — the direction that had no guard at all
  before this change; and a record naming a year nobody built), five at the validator.
- `test_pipeline.R` now passes `--partial`, for the reason `catalogue_release.sh --only` does
  (#26). Measured on `main` as well as here: without it the smoke test has been unable to
  validate **any** watershed group except the two named in `EXPECTED_DEPRECATED` since #26
  landed, because the deprecation check's last arm asks about ids absent from a one-group
  tree. Its two hardcoded asset counts are now per item.
- `run_pipeline.sh` warns about `ALLOW_DRIFT_SKEW` the way it already warned about
  `ALLOW_SKIPPED`: same persistence-in-an-exported-shell hazard, worse consequence.

Measured, not restated: `ufra_ch_ff04` restages `meta.json` byte-identical to its pre-change
build (`sha256:22c2460f…`), and that comparison is now a standing assertion rather than a
one-off — pinned, and gated on `ufra`'s own `produced_datetime` so a `floodplains#79` re-run
reads as "re-take the pin" rather than "the code moved the data". `lnth_ch_ff04`, the first
seven-year item, round-trips stage → tag → COG → style → build → validate with 14 assets and
13 embedded style rows, and both determinism checks pass on it — the styles needed no change
at all, because `04_gpkg_style.py` maps by layer prefix rather than by year.

## v1.1.0 (2026-09-03)

**The published floodplain geometry was wrong, and this release replaces every item it can.** Every
item in v1.0.0 was built with the `flooded` bankfull units defect (#26): `fl_flood_surface()`
fed hectares and millimetres into Hall et al. (2007) coefficients that take km² and cm/yr, so
bankfull depth was **3.5926x** too large. A `ff04` item was not the functional floodplain its
id claims — it was a waterline at roughly 14x bankfull depth, against Hall's field-validated 3.

Areas cannot be scaled, so the items were rebuilt upstream on `flooded` >= 0.5.0. Every
corrected extent is a strict subset of what was published. **Twelve items shrink materially,
by 1.5% to 33.5%**, and a thirteenth (`necr_ch_ff04`) moves 0.01 km² — measured 2026-09-03 as
each item's own `floodplain_ff0*_km2` on the live API against the same property in this build,
compared exactly:

| item | published km² | corrected km² | retained |
|---|---:|---:|---:|
| `tabr_ch_ff04` | 232.69 | 154.63 | 66.5% |
| `mork_ch_ff04` | 625.74 | 416.87 | 66.6% |
| `lchl_ch_ff04` | 324.87 | 232.56 | 71.6% |
| `lsal_ch_ff04` | 256.06 | 185.89 | 72.6% |
| `will_ch_ff04` | 304.93 | 236.09 | 77.4% |
| `ufra_ch_ff04` | 188.18 | 146.93 | 78.1% |
| `bowr_ch_ff04` | 298.16 | 235.75 | 79.1% |
| `fran_ch_ff04` | 883.09 | 782.02 | 88.6% |
| `sloc_bt_ff04` | 129.57 | 117.49 | 90.7% |
| `larl_bt_ff04` | 306.88 | 286.16 | 93.2% |
| `kotl_bt_ff04` | 707.80 | 676.09 | 95.5% |
| `pcea_bt_ff04` | 1067.59 | 1051.96 | 98.5% |
| `necr_ch_ff04` | 396.52 | 396.51 | 100.0% |

Seven items are unchanged — five were already corrected in v1.0.0, and the two marked below
could not be re-run. Any figure a consumer holds for one of the thirteen is now wrong.

**Do not use `file:checksum` to tell which items changed.** Measured: every asset on *every*
item has a new checksum in this release, including items whose geometry is identical, because
the RAT and COG rewrites (#33/#34/#35) touch every byte. The checksum answers "are my bytes
current", which is what it is for — it cannot answer "did the geometry change". Compare the
item's own `floodplain_ff0*_km2` against the table above, or read `nge:flooded_version`:
`0.5.0` means corrected, absent means not.

The catalogue goes from 20 items to **23** — three new Thompson groups in the Fraser region
(`thom_ch_ff04`, `lnth_ch_ff04`, `unth_ch_ff04`). No item is dropped.

- **Two items publish `deprecated: true`** — `mcgr_ch_ff04` and `pine_bt_ff04`, which could
  not be re-run (floodplains#76: MCGR is absent from `fresh`; PINE diverges 10.8% from the
  bcfp reference). They remain over-mapped. Holding the release for them would have blocked 18
  corrections indefinitely, so they ship marked rather than withheld or left looking current.
  Both also carry null on all twelve `nge:` properties while every rebuilt group carries
  `nge:flooded_version = "0.5.0"` — but the API omits nulls, so absence alone is not a
  statement and the marker is the positive one. `item_validate.py` refuses a build where the
  marker has spread, been dropped, or been left on an item that has since been rebuilt, and
  equally one where an item **not** built on `flooded` >= 0.5.0 publishes *unmarked*.
- `PROVENANCE_FLOOR` is **21**: the two marked items have no upstream `provenance.json`.

Also in this release, as merged code with no release between (#46, #47, #40, #32):

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
