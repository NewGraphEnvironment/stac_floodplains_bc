# Findings — Publish Fraser ff04 floodplain collection (#1)

## Endpoint model (2026-07-09)
The `geoserv` droplet serves all collections in the shared `stac` DB through one STAC API,
`images.a11s.one`, distinguished by `collections=`. `stac_register-all.sh` (in rtj) lists
`stac-dem-bc`, `stac-airphoto-bc`, `imagery-uav-bc-prod` there. One other collection has its
own DB + subdomain (see the private `rtj` geoserv notes) — isolation for a large dataset.
`stac-floodplains-bc` (8 items) belongs in the shared `stac` DB — **no `floodplains.a11s.one`
subdomain, no DNS/Caddy change.** The bucket (rtj#172) was the whole infra footprint.

## Bucket
`s3://stac-floodplains-bc`, region **us-west-2** → base URL
`https://stac-floodplains-bc.s3.us-west-2.amazonaws.com` (same shape as airphoto). Live + empty.

## Source data (floodplains driver)
Per WSG under `floodplains/data/<wsg>/`:
- `rasters/<sp>_ff04/{classified_2017,classified_2020,classified_2023,transition}.tif`
- `floodplain_landcover.gpkg` — layers include `transition_<sp>_ff04_2017_2023` with fields
  `transition`, `from_class`, `to_class`, `area_ha` (confirmed on UFRA: 8,119 features).
- `floodplain.gpkg` — layer `<sp>_ff04` (the floodplain polygon → footprint + km²).
- `config/<wsg>/area.yml` — `species`, `primary_scenario` (`<sp>_ff04`).

Loss/gain/net at register time: from the transition layer, `sum(area_ha)` where
`from_class == "Trees" & to_class != "Trees"` (gross loss), `to_class == "Trees" &
from_class != "Trees"` (gross gain), net = gain − loss.

## Pipeline precedent
Mirrors `stac_airphoto_bc` steps 03–05 (COG via terra; tags via rasterio `update_tags`;
register via pystac). We skip its 01/02 (fetch/georef) — floodplains already emits georeferenced
rasters. Catalog load: `stac_register-pypgstac.sh <collection> <s3-base>` on geoserv.
