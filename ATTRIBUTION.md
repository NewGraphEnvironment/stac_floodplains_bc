# Attribution and licensing

Two licences, over two different things.

- **The scripts in this repository** are [MIT](LICENSE), as in `stac_dem_bc` and `stac_uav_bc`.
- **The published catalogue metadata and derived products** — everything under
  `s3://stac-floodplains-bc` and the collection served at `images.a11s.one` — are
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## What the collection publishes

The collection carries `license: CC-BY-4.0`, six `providers`, a `rel: license` link, a
`rel: derived_from` link, and this sentence as `sci:citation`:

> New Graph Environment Ltd. (2026). Floodplain Land-Cover Change in British Columbia
> [data set]. Derived from Impact Observatory, 10m Annual Land Use Land Cover (9-class) V2
> (`io-lulc-annual-v02`), licensed under CC BY 4.0
> (<https://creativecommons.org/licenses/by/4.0/>), accessed via Microsoft Planetary
> Computer; modified by clipping to modelled floodplain extents and cross-tabulating 2017
> against 2023 into land-cover transitions. Floodplain delineation contains information
> licensed under the Open Government Licence – Canada (MRDEM-30, Natural Resources Canada)
> and the Open Government Licence – British Columbia (Freshwater Atlas stream network,
> Province of British Columbia). Stream network built with the `link` package, reproducing
> the `bcfishpass` modelling approach.

Items carry no `license` of their own, deliberately: STAC inherits it from the collection, and
the per-item source attribution is the `nge:landcover_*` provenance block, which the release's
provenance floor (#32) is what keeps non-null.

## Why CC BY 4.0 outbound

Read from each producer's own record on 2026-09-03, not inferred:

| input | licence | what it obliges |
|---|---|---|
| [`io-lulc-annual-v02`](https://planetarycomputer.microsoft.com/api/stac/v1/collections/io-lulc-annual-v02) — Impact Observatory 10 m annual LULC | `CC-BY-4.0` | credit, a licence link, and a statement that the material was **modified** |
| [`mrdem-30`](https://datacube.services.geo.ca/stac/api/collections/mrdem-30) — NRCan DTM, the terrain the floodplains are delineated off | `OGL-Canada-2.0` | "Contains information licensed under the Open Government Licence – Canada" |
| BC Freshwater Atlas stream network, via `link` / `fresh` | Open Government Licence – British Columbia | the equivalent BC sentence |

None is share-alike, so the derived products may carry our own licence and CC BY 4.0 is the
natural match. `bcfishpass` is a **method** citation rather than a licence obligation:
nothing published here redistributes its override data — the published geometry is
FWA-derived — so it is credited as the modelling approach the network reproduces. That
distinction is load-bearing rather than decorative: `bcfishpass`'s `LICENSE` is three-part —
Apache 2.0 for the software, **ODbL for the database** and DbCL for its contents — and ODbL
*is* share-alike, so redistributing that database would land under a different obligation than
the three inputs above. GitHub reports the repository as `NOASSERTION` for this reason.

That chain of reasoning is the one thing no guard can check, which is why it is written
down. What *is* checked, absolutely and on every build, is in `scripts/item_validate.py`
(`check_collection_metadata`, `check_citation_premise`) and read back from the live API by
step 5 of `scripts/catalogue_release.sh`.

## Method and software credit

A separate debt from the data obligations above, and paid nowhere else in this repository.

| whose | what | licence |
|---|---|---|
| [Devin Cairns — BlueGeo](https://github.com/bluegeo/bluegeo) | the Valley Confinement Algorithm that `flooded` adapts | MIT |
| [USDA Rocky Mountain Research Station](https://research.fs.usda.gov/rmrs) | the original valley-confinement method — the VCA Toolbox | — |
| [Simon Norris — `bcfishpass`](https://github.com/smnorris/bcfishpass) | lateral habitat assembly, and the modelling approach `link` reproduces | Apache 2.0 (software); ODbL database, DbCL contents |

The old VCA Toolbox URL (`fs.usda.gov/rm/boise/AWAE/projects/valley_confinement.shtml`, still
cited by `flooded`'s own README) now **302s to the generic station landing page and returns
200** — a dead link that passes a status-code check, which is why it is not used here.
