## Outcome

Built the five-step publish pipeline (`01_stage.R` → `05_stac_register.py` + `run_pipeline.sh`)
and published the `stac-floodplains-bc` STAC collection: 8 Fraser-region watershed groups (chinook
`ff04`), one item each, with classified-year + transition COGs and a floodplain GeoPackage. The
collection is **live on `images.a11s.one`** — all 8 items queryable with correct loss/gain/net.
Region totals (3,366 km² floodplain, 15,022 ha gross tree loss) reproduce the issue headline
exactly, confirming the published figures trace to the upstream `floodplains` transition layers.

Key decisions / learnings:
- **Metrics computed in R at staging, not Python at register.** The publish Python env carries no
  vector reader (fiona/geopandas), so `01_stage.R` (sf) derives floodplain area, footprint
  geometry, and tree loss/gain/net from the transition layer into a `data/raw/<wsg>/meta.json`
  sidecar that both Python steps consume — identical figures, no extra deps.
- **Migrated conda → uv** (pilots `stac_dem_bc#16`). The dem#16 blocker ("can uv install
  GDAL/rasterio wheels without conda-forge?") was cleared empirically: uv installs the full stack
  in ~2s from PyPI wheels and the pipeline runs on it, while conda was blocked on this machine by
  the Anaconda ToS gate on the `defaults` channel. Finding posted to dem#16.
- **Partial-publish guard.** A `WSG_ONLY` single-group stage drops a `PARTIAL_STAGE` marker that
  `05` refuses to upload past (unless `SKIP_S3_UPLOAD`), so a smoke-test / one-off run can never
  clobber the live multi-item collection.
- Catalog load is an `rtj` step (rtj#177, done by a parallel session) — this repo's boundary ends
  at S3 + validated collection JSON.

Closed by: commits d8f688f → 2793945 on branch `1-publish-fraser-ff04` (PR pending).
Related: `stac_dem_bc#16` (uv), `rtj#177` (geoserv registration), `rtj#172/#173` (bucket).
