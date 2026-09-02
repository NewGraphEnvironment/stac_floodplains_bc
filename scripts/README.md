# scripts

Publish pipeline for the `stac-floodplains-bc` collection. Reads the already-produced
floodplain outputs from `$FLOODPLAINS_DATA` (default `../floodplains/data`) — this repo does
no floodplain modelling.

Two commands, deliberately separate:

```bash
bash scripts/run_pipeline.sh                        # rebuild locally — no network writes at all
bash scripts/catalogue_release.sh                   # validate → sync → register → verify
bash scripts/catalogue_release.sh --only <item_id>  # republish ONE item; never collection.json
```

Only the rebuild needs `$FLOODPLAINS_DATA` (~900 MB). A release needs AWS credentials and SSH to
the catalog host, so it can be cut from a machine that does not hold the source tree.

## Rebuild — `run_pipeline.sh`

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover rostered WSGs + their publish targets; for each item (`<wsg>_<scenario>`, one per declared `(species, scenario)`) copy the classified/transition rasters into `data/raw/<item_id>/` and `floodplain_landcover.gpkg` + `floodplain.gpkg` (ff02/ff04/ff06 delineations) into `data/stac/<item_id>/`, extract the transition layer to `transition_vector.gpkg` (layer `transition`); derive per-flood-factor floodplain areas + tree metrics + footprint → `data/raw/<item_id>/meta.json` |
| Tag | `02_raster_tag.py` | Embed GDAL metadata tags from `meta.json` onto the **staged** rasters (WSG, species, scenario, region, floodplain area per flood factor ff02/ff04/ff06 km², gross loss/gain/net ha, run provenance, per-asset year). Before the COG conversion, not after — tagging a finished COG in place moves its main IFD to the end of the file (#33). Also authors the class-label RAT as a PAM `.aux.xml` beside each staged raster, which `03` absorbs into the COG (#34/#35) |
| COG | `03_cog.py` | Convert the tagged rasters to Cloud-Optimized GeoTIFFs → `data/stac/<item_id>/` via `rasterio.shutil.copy` (a GDAL `CreateCopy`), which carries the tags, colour table, band description **and the class-label RAT** through. This is the last step to touch a published byte. Python rather than terra since #34: only a RAT can put labels inside a `.tif`, and RAT-in-`GDAL_METADATA` needs GDAL 3.12+ while terra links 3.8.5 |
| STAC | `item_create.py` | Build the collection + one `<item_id>.json` per target into `data/stac/`; asset hrefs under `<item_id>/`. Also hashes every asset into `file:checksum` + `file:size`. Build only — no validation, no network; the collection carries no `version` until `catalogue_release.sh` stamps it |
| Extract | `fp_gpkg.R` | Sourced by `01_stage.R`: pins `OGR_CURRENT_DATE` and writes single-layer GeoPackages into a fresh file (the only case the pin makes byte-reproducible) |
| Validate | `item_validate.py` | pystac-validate every document **on disk**, so what is checked is what ships. Requires exactly the staged item count, so a wrong `--base` fails instead of reporting `valid: 0` and exiting 0. Also re-hashes every asset and asserts the published `file:checksum`/`file:size` match the bytes |

### The step order is load-bearing for checksums

`02` tags the **staged** rasters and writes their class-label sidecars, `03` writes the COGs from
them, and `item_create.py` hashes what `03` produced. Hashing is correct only because it runs last.
**Anything that touches an asset after `item_create.py` publishes a checksum that silently does not match the
object** — so a new step that rewrites bytes belongs before `item_create.py`, not after.

The order also decides whether the labels ship at all. `03`'s `CreateCopy` is what folds `02`'s PAM
sidecar into the COG's own `GDAL_METADATA` tag; run in the other order the labels would sit in a
file the S3 sync excludes and geoserv's titiler could not fetch.

Two of the three GeoPackages are `file.copy()`d from upstream and never rewritten here, so their
bytes — and therefore their checksums — are exactly upstream's. **`transition_vector.gpkg` is
written here** (#23), which is why `01_stage.R` pins `OGR_CURRENT_DATE` via `fp_gpkg.R`: GDAL
otherwise stamps wall-clock time into `gpkg_contents.last_change`, and that one asset's checksum
would churn on every rebuild while every other asset's stayed stable — reading as "checksums are
unreliable" when the cause is a single unpinned writer. `gpkg_determinism-check.R` proves the pin
holds, and its `NO_PIN=1` cold path proves the check can fail.

`file:checksum` is a multihash (`1220` + sha256), not a bare digest. The STAC schema only checks the
string is hex, so it accepts a bare digest and cannot catch a checksum of the wrong bytes; both are
asserted in `item_validate.py` instead. Verifying re-reads every asset (~670 MB) — that is the cost
of the guard actually guarding something.

## Release — `catalogue_release.sh`

| Step | What |
|----|----|
| 0 preflight | `PARTIAL_STAGE` absent; ≥1 item + `collection.json`; SSH reachable; the build compared against the **live** collection — refuses if any live item is missing; then the **version gate** — HEAD exactly at a `vX.Y.Z` tag, tracked tree clean, `NEWS.md` top entry naming that version — and `collection_version.py` stamps `collection.json` (STAC Version Extension) before anything is validated or published |
| 1 validate | the gate. Nothing below runs unless every document validates; on a full release the validator is also given `PROVENANCE_FLOOR` — a literal in the script, set by a human, naming how many items must carry a non-null `nge:` value (#32) |
| 2 sync assets | `aws s3 sync` — no `--delete`, no `--size-only`, `--exclude '*.json'` |
| 3 sync JSON | after the assets, so no document references an object that has not landed |
| 4 register | collection first (pgstac items reference the collection row), then items |
| 5 verify | collection 200; live ids match the build **both ways**; the largest asset of one item probed for size and its published `file:checksum` re-verified against the bytes on S3; the live collection's `version` equals the tag just released (under `--only`: unchanged) |

Validation gates the **asset** sync, not just the JSON. Bucket versioning is Suspended, so there is
no rollback from pushing 700 MB of assets for a build that then fails.

Registration is an **upsert**, so nothing is deleted implicitly and the collection never serves
zero items mid-release. The cost is that an item dropped from the build stays live — step 0 and
step 5 both report those, and removal is an explicit `item_unregister.sh` call.

### Cut a release

A version means "the published catalogue is in this state" — the `NEWS.md` convention shared with
`stac_uav_bc` and `stac_dem_bc`. Scripts are not versioned separately: a tag says the live
catalogue (bucket + API) matches what that commit describes, which is why the release, not the
build, writes the stamp — the rebuild precedes the tag in every real flow.

```bash
# 1. rebuild — the build carries no version, so this can happen before the tag exists
bash scripts/run_pipeline.sh
# 2. describe the release at the top of NEWS.md: `## vX.Y.Z (YYYY-MM-DD)`, commit it
# 3. tag that commit — locally; the tag is pushed only once the release has succeeded
git tag vX.Y.Z
# 4. release — refuses unless HEAD is exactly at the tag, the tree is clean and the tag's
#    NEWS.md agrees; stamps collection.json, publishes, fails unless API + bucket serve it back
bash scripts/catalogue_release.sh
curl -s https://images.a11s.one/collections/stac-floodplains-bc | jq .version
# 5. only now publish the tag: a pushed tag says the catalogue IS in this state, and a release
#    that failed would otherwise leave a public tag for a state that never went live
git push origin vX.Y.Z
# 6. regenerate README.md's coverage table from what the API now serves, and commit it. This
#    commit is past the tag by design (the tag marks the catalogue's state, not the README);
#    the generated caption names the version the table describes.
python3 scripts/readme_coverage-table.py --write
```

`--only` republishes one item and never the collection, so it needs no tag and moves no version.
`--allow-retract` is a full release and stamps like any other. Between the tag and the release,
touch nothing tracked: the gate wants HEAD exactly at the tag (one tag on that commit) and a clean
tree, so tick the planning boxes afterwards. On a release-only machine, `git fetch --tags` first.
Never register `collection.json` by hand (`collection_register.sh` outside the release): a rebuilt
collection carries no version, and registering it would silently un-version the API.

## Retraction

Removing a published item is registry-driven, not ad hoc:

```bash
# 1. drop the target upstream (region roster / area.yml in the floodplains repo)
# 2. rebuild — the item is no longer produced
bash scripts/run_pipeline.sh
# 3. delete it from the API
scripts/item_unregister.sh <item-id>
# 4. delete its assets (S3 has no versioning — this is irreversible)
aws s3 rm s3://stac-floodplains-bc/<item-id>/ --recursive
aws s3 rm s3://stac-floodplains-bc/<item-id>.json
# 5. publish the smaller collection
bash scripts/catalogue_release.sh --allow-retract
```

`--allow-retract` is required at step 5 because a build with fewer items than the live collection
is otherwise refused — that refusal is the guard against an accidental partial publish.

## Pilot — `catalogue_release.sh --only <item_id>`

Republish **one existing item** — its assets, its JSON and its pgstac row — so a change can be
piloted on one group and inspected live before a full release against a bucket with no rollback:

```bash
WSG=bulk Rscript scripts/test_pipeline.R                  # one-group tree, PARTIAL_STAGE written
bash scripts/catalogue_release.sh --only bulk_co_ff04     # that item only
```

What `--only` changes, step by step:

| Step | Under `--only` |
|----|----|
| 0 preflight | `PARTIAL_STAGE` interlock and the live-vs-build comparison are **skipped, out loud** — both guard `collection.json`, which is never published here. Instead: the item's JSON and asset dir must exist, and the item must **already be live** (a new item needs a full release, which updates the collection's extent/summaries/links) |
| 1 validate | unchanged — the whole tree on disk, so with a full build present this re-hashes ~670 MB |
| 2 sync assets | `aws s3 sync data/stac/<id> s3://…/<id>`, same excludes, no `--delete` |
| 3 sync JSON | `aws s3 cp data/stac/<id>.json s3://…/<id>.json` — **one explicit object**. The full path's `--include '*.json' --exclude '*/*'` sweep would carry `collection.json` with it, and a one-group tree's `collection.json` describes one group |
| 4 register | `item_register.sh` for that file; `collection_register.sh` is never run |
| 5 verify | item endpoint 200; collection **membership byte-identical** to the preflight read; size + checksum probes on that item; the live item read back from the API and its `assets` + `properties` compared to the build **wholesale** — the only proof the pgstac row changed, and checksums alone would miss a labels- or provenance-only republish |

`--only` refuses to combine with `--allow-retract` (retraction is a collection-level operation) and
composes with `--skip-sync`.

The property that makes this safe — no route under `--only` reaches `collection.json` — is
pinned by `catalogue_release-check.sh`, which runs the real release script against `aws`/`ssh`/
`uv`/`curl` shims and reads their argv logs. Its positive control is a full release on the same
fixture, which **must** be seen to sweep `collection.json` by the same greps; without that, the
`--only` zeros would be a search that has never matched anything.

```bash
bash scripts/catalogue_release-check.sh      # no network, no credentials; exit = failed assertions
```

The tree-loss numbers (`gross_loss_ha`, `gross_gain_ha`, `net_ha`) are computed once, during
staging, from each WSG's `transition_<sp>_ff04_2017_2023` gpkg layer (`from_class == "Trees"` vs
`to_class == "Trees"`, summing `area_ha`) and written to `meta.json` — so the tag and register
steps publish identical figures that trace directly to the modelled transition patches. Metrics
are computed in R (step 01) because the publish Python env carries no vector reader.

## Smoke test

`test_pipeline.R` runs one watershed group end-to-end (`stage → tag → COG → build → validate`),
through the **same** `item_validate.py` gate a release uses. It cannot touch S3 — nothing it calls
makes network writes — and it leaves a `PARTIAL_STAGE` marker that `catalogue_release.sh` refuses
to publish past as a collection; the one-group tree it leaves is exactly what
`catalogue_release.sh --only <item_id>` republishes, one item at a time and never `collection.json`. It builds and
validates every item that group stages (a group may declare more than one
`(species, scenario)` target). It also asserts the attribute contract:
every layer of all three published GeoPackages carries a `wsg` column matching the item. Only
`wsg` is asserted, not `species`/`scenario` — the whole-WSG bundles are copied into each item dir,
so a multi-target group ships the other species' layers too and `wsg` is the one key invariant
under that copy. Use it after any change to the scripts, the floodplains data layout, or the STAC
schema, before a real full publish.

```
Rscript scripts/test_pipeline.R            # defaults to UFRA
WSG=necr Rscript scripts/test_pipeline.R   # any rostered WSG
WSG=morr Rscript scripts/test_pipeline.R   # multi-target group: stages 2 items
```

## Determinism check

`gpkg_determinism-check.R` proves the GeoPackage timestamp pin is doing its job — extract the same
layer twice and assert byte-identical output.

```
Rscript scripts/gpkg_determinism-check.R              # warm path: rebuilds must MATCH
NO_PIN=1 Rscript scripts/gpkg_determinism-check.R     # cold path: rebuilds must DIFFER
ITEM=bulk_co_ff04 Rscript scripts/gpkg_determinism-check.R
```

The cold path is the point. A guard nobody has seen fail is decoration, so `NO_PIN=1` asserts the
rebuilds **differ** and errors if they match — if it passes, the warm run was measuring nothing.
Measured on `sloc_bt_ff04`: unpinned `5429357d…` vs `c2bfa94b…`; pinned, both `ea0ac66f…`.

## Environment flags

| Flag | Effect | Risk |
|----|----|----|
| `WSG_ONLY=<wsg>` | Restricts `01_stage.R` to one group and drops a `PARTIAL_STAGE` marker. Used by the smoke test; `run_pipeline.sh` refuses to start if it is set, and `catalogue_release.sh` publishes the result only under `--only` | safe |
| `NO_PIN=1` | Disables the GeoPackage timestamp pin in `gpkg_determinism-check.R` only — the cold path that proves the check can fail | safe (check only) |
| `ITEM=<item_id>` | Which staged item `gpkg_determinism-check.R` exercises (default `sloc_bt_ff04`, the smallest) | safe |
| `GEOSERV_HOST` | Overrides the catalog host (default `root@geopro`, the tailnet node name) | safe |
| `ALLOW_SKIPPED=1` | Suppresses the `PARTIAL_STAGE` marker when a rostered group was skipped (not modelled yet) | **disables an interlock** |

The last one exists for deliberate one-off cases and **persists for the whole shell if exported**,
so `run_pipeline.sh` prints a loud banner when it is set. Publishing fewer items overwrites the
live `collection.json`, and bucket versioning is Suspended — there is no undo. The equivalent for
a release is the explicit `--allow-retract` flag rather than an env var, for the same reason.

Catalog registration is owned by this repo (`item_register.sh`, `collection_register.sh`,
`item_unregister.sh`). `rtj` still manages the server itself, and its `stac_register-all.sh` can
reload this collection **from S3** — harmless, because step 3 syncs the JSON before step 4
registers it, so the bucket and the API always agree.
