# scripts

Publish pipeline for the `stac-floodplains-bc` collection. Reads the already-produced
floodplain outputs from `$FLOODPLAINS_DATA` (default `../floodplains/data`) — this repo does
no floodplain modelling.

Two commands, deliberately separate:

```bash
bash scripts/run_pipeline.sh        # rebuild locally — no network writes at all
bash scripts/catalogue_release.sh   # validate → sync → register → verify
```

Only the rebuild needs `$FLOODPLAINS_DATA` (~900 MB). A release needs AWS credentials and SSH to
the catalog host, so it can be cut from a machine that does not hold the source tree.

## Rebuild — `run_pipeline.sh`

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover rostered WSGs + their publish targets; for each item (`<wsg>_<scenario>`, one per declared `(species, scenario)`) copy the classified/transition rasters into `data/raw/<item_id>/` and both `floodplain_landcover.gpkg` + `floodplain.gpkg` (ff02/ff04/ff06 delineations) into `data/stac/<item_id>/`; derive per-flood-factor floodplain areas + tree metrics + footprint → `data/raw/<item_id>/meta.json` |
| COG | `02_cog.R` | Convert the staged rasters to Cloud-Optimized GeoTIFFs → `data/stac/<item_id>/` |
| Tag | `03_cog_tag.py` | Embed GDAL metadata tags from `meta.json` (WSG, species, scenario, region, floodplain area per flood factor ff02/ff04/ff06 km², gross loss/gain/net ha, per-asset year) |
| STAC | `05_stac_register.py` | Build the collection + one `<item_id>.json` per target into `data/stac/`; asset hrefs under `<item_id>/`. Build only — the name is a misnomer kept until the rename lands with the Version Extension work |
| Validate | `item_validate.py` | pystac-validate every document **on disk**, so what is checked is what ships. Requires exactly the staged item count, so a wrong `--base` fails instead of reporting `valid: 0` and exiting 0 |

## Release — `catalogue_release.sh`

| Step | What |
|----|----|
| 0 preflight | `PARTIAL_STAGE` absent; ≥1 item + `collection.json`; SSH reachable; and the build compared against the **live** collection — refuses if any live item is missing |
| 1 validate | the gate. Nothing below runs unless every document validates |
| 2 sync assets | `aws s3 sync` — no `--delete`, no `--size-only`, `--exclude '*.json'` |
| 3 sync JSON | after the assets, so no document references an object that has not landed |
| 4 register | collection first (pgstac items reference the collection row), then items |
| 5 verify | collection 200; live ids match the build **both ways**; one asset href probed for 200 |

Validation gates the **asset** sync, not just the JSON. Bucket versioning is Suspended, so there is
no rollback from pushing 700 MB of assets for a build that then fails.

Registration is an **upsert**, so nothing is deleted implicitly and the collection never serves
zero items mid-release. The cost is that an item dropped from the build stays live — step 0 and
step 5 both report those, and removal is an explicit `item_unregister.sh` call.

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

The tree-loss numbers (`gross_loss_ha`, `gross_gain_ha`, `net_ha`) are computed once, during
staging, from each WSG's `transition_<sp>_ff04_2017_2023` gpkg layer (`from_class == "Trees"` vs
`to_class == "Trees"`, summing `area_ha`) and written to `meta.json` — so the tag and register
steps publish identical figures that trace directly to the modelled transition patches. Metrics
are computed in R (step 01) because the publish Python env carries no vector reader.

## Smoke test

`test_pipeline.R` runs one watershed group end-to-end (`stage → COG → tag → build → validate`),
through the **same** `item_validate.py` gate a release uses. It cannot touch S3 — nothing it calls
makes network writes — and it leaves a `PARTIAL_STAGE` marker that `catalogue_release.sh` refuses
to publish past, so its one-group tree cannot be released by mistake either. It builds and
validates every item that group stages (a group may declare more than one
`(species, scenario)` target). It also asserts the attribute contract:
each `floodplain_landcover.gpkg` layer carries `wsg`/`species`/`scenario`, with `wsg` matching
the item. Use it after any change to the scripts, the floodplains data layout, or the STAC
schema, before a real full publish.

```
Rscript scripts/test_pipeline.R            # defaults to UFRA
WSG=necr Rscript scripts/test_pipeline.R   # any rostered WSG
WSG=morr Rscript scripts/test_pipeline.R   # multi-target group: stages 2 items
```

## Environment flags

| Flag | Effect | Risk |
|----|----|----|
| `WSG_ONLY=<wsg>` | Restricts `01_stage.R` to one group and drops a `PARTIAL_STAGE` marker. Used by the smoke test; `run_pipeline.sh` refuses to start if it is set | safe |
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
