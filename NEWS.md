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

**Four areas now publish land cover for every year from 2017 to 2023** (#59), on top of the
code change that made that expressible (#61). The collection carries two populations from here
on: `bulk_co_ff04`, `necr_ch_ff04`, `lnth_ch_ff04` and `kotl_bt_ff04` serve seven
`classified_<year>` assets; the other nineteen still serve three. Read the item's own asset
list rather than assuming a count.

Why: `drift`'s `dft_rast_break_class()` needs the whole series, not the endpoints and
midpoint — a single-year 2017-vs-2023 difference cannot tell a sustained change from a
one-year excursion. The measurement that motivated it belongs to `drift` and is not restated
here; these four areas are what lets it be checked beyond one group (drift#62).

Each item goes from **10 assets to 14** — `classified_2018`, `_2019`, `_2021` and `_2022` are
new — and **`floodplain_landcover.gpkg` grows by 27% to 105%**, because it now carries a
polygon layer per year instead of three. It is the largest file in the bundle, so
plan the download. The spread is not proportional to the layer count and nothing here predicts
it: a GeoPackage rewritten layer-by-layer is not byte-stable (floodplains#45), and how much a
year's polygons cost depends on how fragmented that year's land cover is.

| item | `floodplain_landcover.gpkg` | classified layers |
|---|---|---|
| `bulk_co_ff04` | 41.7 MB → 53.0 MB (+27%) | 3 → 7 |
| `necr_ch_ff04` | 30.8 MB → 49.6 MB (+61%) | 3 → 7 |
| `lnth_ch_ff04` | 11.4 MB → 23.3 MB (+105%) | 3 → 7 |
| `kotl_bt_ff04` | 21.3 MB → 42.5 MB (+100%) | 3 → 7 |

No *modelled value* about the four changed, and that is measured rather than assumed: the
three floodplain extents, the tree-change figures, the temporal window, the `bbox` and the
geometry are unchanged, and the `floodplain`, `transition_vector` and three `style_*` assets
are unchanged on both checksum and size. Every COG's bytes did move, for the tag reason below,
and `necr` and `kotl` also picked up stray upstream metadata — both are their own bullets. Exactly four properties move — `nge:landcover_key`,
`nge:landcover_item_hash`, `nge:drift_version` (now `0.13.0`) and `nge:produced_datetime`.

**The other nineteen items did not move at all.** The four were published one at a time with
`catalogue_release.sh --only`, which writes only the named item's prefix and its own JSON — so
the bucket carries 210 objects outside those four with unchanged ETags, none added and none
removed, and `collection.json` was never written.

**The served collection version is still `1.1.0`, and this entry is why.** `--only` never
publishes `collection.json`, so it cannot stamp a version. The next full release folds this in,
as `bulk_co_ff04`'s `--only` pilot (#36) was folded into v1.0.0.

That precedent is weaker than it looks and the difference is worth naming: the #36 pilot ran
*before* v1.0.0, when the collection carried **no version at all**, so nothing could be
contradicted by it. **This is the first time published items have moved ahead of a stamped
version.** A consumer reading `1.1.0` off the API is holding a string that predates four items'
current contents. `nge:produced_datetime` happens to separate them today — the four read
`2026-09-05T19:14Z` … `19:52Z`, every other item `2026-09-03T20:16Z` or earlier — but do not
lean on that as a rule. It is the landcover step's *upstream* run time, not a publish
time — so it says when the land cover was produced, never when this repo last wrote the
object, and a republish of an item upstream had not re-run would leave it untouched. The two
`deprecated: true` items serve no `nge:` properties whatsoever. Until the next full release, this entry is the record.

- **`nge:landcover_key` moved on all four, and it does not mean the land cover changed.** It is
  a fold over the producer's per-year content digests, so covering seven years instead of three
  gives a different scalar over identical inputs. Measured, and this is the load-bearing check
  in the whole release: folding **only** 2017/2020/2023 out of today's producer file reproduces
  the value each item was serving *before* the re-run, exactly, for all four. That is
  independent confirmation from this repo that the three original years' content is untouched.
  `nge:landcover_item_hash` moved for the reason its name implies — seven resolved STAC item
  ids where there were three.
- **Do not expect the `transition_2017_2023` checksum to prove the transition is unchanged.** It
  moved on every item, and it always would have: `02_raster_tag.py` stamps the item's whole
  provenance block into *every* COG's TIFF tags, so the four properties above move the bytes of
  files whose pixels nobody touched. This is v1.1.0's warning arriving one release later — a
  checksum answers *are my bytes current*, not *did the values change*, and here it could not
  answer the second question even in principle. What does answer it, and holds for all four:
  **`transition_vector.gpkg` is byte-identical** on all four — measured, checksum and size.
  Unlike the COGs it carries no per-item provenance stamp for the year set to move, its layer
  and file names are deliberately year-free, and both of its writers pin their timestamps
  (`OGR_CURRENT_DATE` for the OGR write in `01_stage.R`, `GPKG_EPOCH` for the `sqlite3` style
  write in `04_gpkg_style.py`) — so there is nothing in it that a widened span *could* move
  except the transition patches themselves. `gross_loss_ha` / `gross_gain_ha` / `net_ha` are aggregated from that same
  layer and are unchanged too. Separately, the four COGs per item that **already existed**
  (`transition_2017_2023` and `classified_2017/2020/2023`) were compared against the bytes S3
  was serving, before publishing: decoded pixels, CRS, transform, shape, dtype, nodata, block
  shape, overviews, compression and the embedded RAT all identical. The four *new* years per item had no prior
  bytes to compare against, so they were checked by reading them back over `/vsicurl/` after
  publish: **all 16** return `Byte`, nodata 255, five overview levels, DEFLATE and the 9-row
  class-label RAT.
- **`necr` and `kotl` now ship 30 stray gdalcubes/NetCDF metadata tags per classified COG**
  (floodplains#83). They arrived with the upstream re-run, are absent from `bulk` and `lnth`
  and from every transition raster, and two of them contradict the file they sit on:
  `data#type = 'float64'` and `data#_FillValue = 'nan'` on a raster whose header says `uint8`
  / nodata `255`. The pixels, geometry and RAT are correct — this is metadata describing the
  NetCDF cube the raster was cut from. Published rather than held, because it is recoverable:
  the tags go away on the next republish once #83 lands. Filed upstream rather than stripped
  here.
- `PROVENANCE_FLOOR` is unchanged at **21**. All four already carried provenance, so a full
  release still counts 21 of 23, and `--only` skips `--expect-provenance` entirely.

`floodplains#79` closed 2026-09-05 having re-run step 3 only, so floodplain geometry and
sub-basins were never touched. PINE and MCGR are not here: both are blocked by floodplains#76
and remain `deprecated: true`.

The code change this rests on (#61) moved no data on its own:

- `01_stage.R` no longer declares `YEARS`. Each item's span is discovered from the
  `classified_<yyyy>.tif` actually staged, and the producer's `landcover.<scenario>.inputs.years`
  is what checks it — that direction, not the reverse. Sourcing both from the record would
  reduce `landcover_key`'s fold to one file's `years` agreeing with the same file's
  `classified_content_sha256`, written by one upstream step moments apart.
- Three absolutes replace the refusal the constant used to give, and they hold for **every**
  item, record or no record: a year set must have no duplicates, must be at least two long,
  and must cover both ends of the published transition span. The length floor is a latent
  crash rather than a refusal — `jsonlite`'s `auto_unbox` writes a length-1 vector as
  `{"years": 2017}` and `item_create.py`'s `for yr in meta["years"]` then raises `TypeError`
  three steps downstream. A fourth check, that the record's own `change_interval` matches the
  span this repo publishes, is **record-dependent** by construction: the two forward-only
  items (`mcgr_ch_ff04`, `pine_bt_ff04`, both published `deprecated: true`) have no
  `provenance.json` at all — measured, not merely no landcover section — so it does not run
  for them.
- `item_validate.py` splits its cross-item asset-key check in two, with the partition written
  down beside it: the non-classified keys are still compared across items, and the
  `classified_*` keys are checked per item against `ALLOWED_YEAR_SETS` — a literal a human
  sets, the same shape as `DEPRECATED_ITEMS` and `PROVENANCE_FLOOR`, because an expectation
  derived from the items cannot fire when the loss is uniform across all of them (#23). Both
  directions: an unsanctioned span is refused, and a sanctioned span no item uses is reported
  as a literal nobody updated. That second arm is the one `--partial` drops, because it asks
  about items a subset legitimately does not contain (#26).
- A new arm compares each item's **whole directory** against its published assets, minus what
  the release's own syncs exclude — `.*`, `*/.*`, `*.json`, `*.aux.xml`, **read from
  `catalogue_release.sh`** rather than restated, so the guard cannot drift from the sync it
  describes. Those exclusions are not hypothetical: macOS drops `.DS_Store` into item
  directories and GDAL writes PAM sidecars when a read triggers statistics, and reporting
  either would refuse a release for a file that provably cannot ship. (A sidecar beside a
  published COG is still refused — by `check_cog_rat`, which names the real defect: the RAT is
  not embedded.) The release
  syncs the directory, not the asset list, so any file sitting beside the assets reaches the
  public bucket with nothing pointing at it — and no other guard in this repo enumerates an
  item directory. Deliberately not scoped to the classified COGs: a guard covering one file
  kind reads, to the next person, as "the directory is guarded".
- `scripts/stage_years-check.R` and `scripts/year_sets-check.py` are new, and
  `scripts/fp_provenance-check.R` grew 23 assertions, to 72. Each restores a defect and greps for **that
  guard's own message**: a suite with N guards has N ways to exit 1, and only one of them is
  the evidence. Three arms at the staging call site (a raster the record names and disk
  lacks; a raster on disk the record does not name — the direction that had no guard at all
  before this change; and a record naming a year nobody built), five at the validator.
- `test_pipeline.R` now passes `--partial`, for the reason `catalogue_release.sh --only` does
  (#26). Measured on `main` as well as here: since #26 landed the smoke test has been unable
  to validate **any watershed group at all**. The deprecation check's last arm asks about ids
  absent from the tree, `EXPECTED_DEPRECATED` names two items, and a one-group tree is always
  missing at least one of them — including the two groups that *are* in the literal, since
  each is missing the other. Its two hardcoded asset counts are now per item, and the first
  compares the asset **set**, because a count passes for the right number of wrong names.
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
