# scripts

Publish pipeline for the `stac-floodplains-bc` collection. Reads the already-produced
floodplain outputs from `$FLOODPLAINS_DATA` (default `../floodplains/data`) — this repo does
no floodplain modelling.

Run end-to-end: `bash scripts/run_pipeline.sh`

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover rostered WSGs + their publish targets; for each item (`<wsg>_<scenario>`, one per declared `(species, scenario)`) copy the classified/transition rasters into `data/raw/<item_id>/` and both `floodplain_landcover.gpkg` + `floodplain.gpkg` (ff02/ff04/ff06 delineations) into `data/stac/<item_id>/`; derive per-flood-factor floodplain areas + tree metrics + footprint → `data/raw/<item_id>/meta.json` |
| COG | `02_cog.R` | Convert the staged rasters to Cloud-Optimized GeoTIFFs → `data/stac/<item_id>/` |
| Tag | `03_cog_tag.py` | Embed GDAL metadata tags from `meta.json` (WSG, species, scenario, region, floodplain area per flood factor ff02/ff04/ff06 km², gross loss/gain/net ha, per-asset year) |
| Gate | `05_stac_register.py` | Run first with `SKIP_S3_UPLOAD=1`: build + pystac-validate every item and the collection, locally. Hard-fails before anything reaches S3 |
| S3 | `04_s3_upload.R` | `aws s3 sync data/stac s3://stac-floodplains-bc` (COGs + gpkgs; JSON handled by 05) |
| STAC | `05_stac_register.py` | Re-run without the flag: same build, then upload `<item_id>.json` + `collection.json` to S3; asset hrefs under `<item_id>/` |

`05` runs twice on purpose. Validation lives inside it, so gating the **asset** sync means building
and validating before `04`. Bucket versioning is Suspended — there is no rollback from pushing
700 MB of assets for a build that then fails validation. The second run uploads the JSON only after
the assets it references have landed.

The tree-loss numbers (`gross_loss_ha`, `gross_gain_ha`, `net_ha`) are computed once, during
staging, from each WSG's `transition_<sp>_ff04_2017_2023` gpkg layer (`from_class == "Trees"` vs
`to_class == "Trees"`, summing `area_ha`) and written to `meta.json` — so the tag and register
steps publish identical figures that trace directly to the modelled transition patches. Metrics
are computed in R (step 01) because the publish Python env carries no vector reader.

## Smoke test

`test_pipeline.R` runs one watershed group end-to-end (`stage → COG → tag → STAC`)
**without touching S3** — it builds and validates every item that group stages (a group may
declare more than one `(species, scenario)` target). It also asserts the attribute contract:
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
| `WSG_ONLY=<wsg>` | Restricts `01_stage.R` to one group and drops a `PARTIAL_STAGE` marker. Used by the smoke test. `run_pipeline.sh` refuses to start if it is set | safe |
| `SKIP_S3_UPLOAD=1` | `05_stac_register.py` builds + validates locally without uploading | safe |
| `ALLOW_SKIPPED=1` | Suppresses the `PARTIAL_STAGE` marker when a rostered group was skipped (not modelled yet) | **disables an interlock** |
| `ALLOW_RETRACT=1` | Allows the sync to proceed when the build has fewer items than the live collection | **disables an interlock** |

The last two exist for deliberate one-off cases and **persist for the whole shell if exported**.
`run_pipeline.sh` prints a loud banner when `ALLOW_SKIPPED` is set. Publishing fewer items
overwrites the live `collection.json`, and bucket versioning is Suspended — there is no undo.

Together these mean a single-group test run can never clobber the live 17-item collection.

Catalog load runs on the geoserv server via `stac_register-pypgstac.sh` (in `rtj`), not here.
