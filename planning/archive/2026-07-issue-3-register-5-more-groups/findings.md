# Findings — Register 5 more groups (#3)

## The 5 new groups (data-ready, verified 2026-07-12)
| Group | Scenario | Region | Species | rasters | floodplain layer | transition layer |
|-------|----------|--------|---------|---------|------------------|------------------|
| BOWR | ch_ff04 | Fraser | ch | 4/4 | ch_ff04 | transition_ch_ff04_2017_2023 |
| MCGR | ch_ff04 | Fraser | ch | 4/4 | ch_ff04 | transition_ch_ff04_2017_2023 |
| PCEA | bt_ff04 | Peace | bt | 4/4 | bt_ff04 | transition_bt_ff04_2017_2023 |
| PARS | bt_ff04 | Peace | bt | 4/4 | bt_ff04 | transition_bt_ff04_2017_2023 |
| PINE | bt_ff04 | Peace | bt | 4/4 | bt_ff04 | transition_bt_ff04_2017_2023 |

Published already (8): fran, lchl, lsal, mork, necr, tabr, ufra, will (all ch_ff04). 8 + 5 = 13.

## Region config membership (the crux)
- `config/regions/peace.yml`: region=peace, species=[bt], watershed_groups=[PCEA, PARS, PINE]. ✓ lists Peace three.
- `config/regions/fraser.yml`: region=fraser, species=[ch, bt], watershed_groups=[LCHL, LSAL, WILL,
  TABR, UFRA, NECR, MORK, FRAN] — **does NOT list BOWR/MCGR** (they have area.yml + data but no
  roster entry). `area.yml` has **no `region` field** → the region roster is the only group→region link.
- Coho morr/neexdzii (species=co, co_ff04) are in NO region config → naturally excluded by
  region-driven staging.
- Decision (Option A): add BOWR, MCGR to fraser.yml upstream so the roster stays the source of truth.

## Why only `01_stage.R` changes
- Layer naming is `<scenario>`-driven; item id = `<wsg>_<scenario>`; `05` globs `data/raw/*/meta.json`.
- `03_cog_tag.py` YEAR regex matches generic staged basenames (`classified_2017.tif`,
  `transition_2017_2023.tif`) — scenario isn't in the filename.
- `05` collection title/description already BC-wide; proj read from a ref COG. No ch/bt assumption.
- `01_stage.R` hardcodes `REGION <- "fraser"` and reads a single region yml — the only change point.

## Downstream (out of this repo)
- After republish, the geoserv pypgstac load must re-run to register the 5 new items (rtj, as rtj#177).
