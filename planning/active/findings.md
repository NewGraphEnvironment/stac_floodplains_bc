# Findings — Publish v2.1.0 (#98)

## Why the box was still open

`data/stac` on disk was written 2026-10-19 **02:35**; `d77fd36` landed **02:41** and edited
`scripts/item_create.py` (asset + collection description prose: the composition range
2.9–11.1% replacing "3-10%", the `in_floodplain = 1` filter, the footprint sum 10,611.35)
and one comment in `scripts/01_stage.R`. So the staged item JSON was stale against the
publish code — nothing that writes published raster or GeoPackage bytes changed, but the
documents the release would upsert did.

Chose the full `run_pipeline.sh` over a JSON-only refresh (airvine, 2026-10-19): it is the
documented path, and the floor/census/metric-scope literals have to come from the tree the
release is actually cut from.

## Pre-flight state, measured 2026-10-19 ~08:30 PDT

| fact | value |
|---|---|
| main | clean at `2f3e0f5` |
| live collection version | `2.0.1`, licence `CC-BY-4.0` |
| AWS | `arn:aws:iam::414155577829:user/airvine`, bucket lists |
| geoserv | `root@geopro` answers; `uv run pypgstac` resolves under `/opt/geoserv/scripts` |
| upstream `../floodplains/data` | unmoved since 2026-10-18 22:00; floodplains HEAD `2fe7a74` |
| `NEWS.md` top entry | `## v2.1.0 (unreleased)`, complete |
| `RETIRED_ITEMS` | empty — no retraction in this release |

A bare `ssh root@geopro 'command -v pypgstac'` reports `PYPGSTAC_MISSING`: it is reached
through `PATH=/root/.local/bin` and `cd /opt/geoserv/scripts`, as `item_register.sh` does.
`uv run pypgstac version` from a probe fails with `psycopg_pool.PoolTimeout` because the
probe sources no `/opt/geoserv/.env` — that is the probe, not the stack.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `ls -ldT` → exit 2 | GNU coreutils is ahead of `/usr/bin` here; `ls -l --time-style=long-iso` |

## The rebuild, 2026-10-19 08:37–08:52 PDT (15 min, exit 0)

`run_pipeline.sh` over all 23 rostered groups. 108 staged rasters, 108 COGs, 0 failed.
Styles: 223 rows over 23 items, `layer_styles` registered and pinned in **69 of 69**
GeoPackages (#95's fix, all three bundles). Year sets: the annual span on 4 items
(BULK, KOTL, LNTH, NECR — the ones showing 13 style rows), 2017/2020/2023 on 19.

The three literals this release asserts, taken from the build's own printed lines, and
each already equal to what the code holds — so **no literal edit was needed**:

| literal | build | code |
|---|---|---|
| `PROVENANCE_FLOOR` | 23 of 23 carry provenance | 23 |
| `PROV_CENSUS` | `link_run_uid` 18, other eleven 23 | same |
| `METRIC_SCOPE_CENSUS` | straddle 23 of 23 on all five | same |

The 5 items without `link_run_uid`: `dunc`, `kotl`, `larl`, `mcgr`, `sloc` — modelled
upstream, a block whose schema predates link#262.

## `test_pipeline.R` was not run, deliberately

It restages into the real `data/` (`WSG_ONLY`) and leaves `data/raw/PARTIAL_STAGE` behind,
which `catalogue_release.sh` refuses to publish past. Running it between the build and the
tag would destroy the tree the release is cut from. The full `run_pipeline.sh` is the
strictly stronger run: the same stage -> tag -> COG -> style -> build -> validate chain over
all 23 groups rather than one, through the same gate.

## The release ran, and the agent could not run it

`catalogue_release.sh` was refused to the agent by auto mode's classifier
(*Production Deploy*), and the two `git push`es afterwards by the same classifier
(*Excess Sensitive Detail*). Approval given in chat does not reach it, so each was handed
over as a bare command rather than retried — `agent-operations.md` §4.

The release itself then ran, and v2.1.0 is live. Verified 2026-10-22 **on the bytes a
consumer downloads**, not on the script's own `RELEASE COMPLETE`:

| probe | result |
|---|---|
| API `collection.json` version | `2.1.0` |
| bucket `collection.json` | `2.1.0`, 23 `rel: item`, agrees with the API |
| `bulk_all_ff04/floodplain_landcover.gpkg` from the bucket | sha256 `f2505c25…1b4a5`, **equal** to the local build's |
| that file under `ogrinfo -so` | opens; GDAL lists the `composition_*` and `patch_watercourse_*` aspatial tables |
| `sloc_all_ff04` from the API | all twelve figures; `in_wsg` below footprint on the five; `gain - loss = net` in both scopes (83.5 − 119.7 = −36.2, 83.9 − 123 = −39.1) |

The bucket-and-API agreement is the one that matters beyond this release: rtj's
reload-from-S3 is harmless only while the two agree.
