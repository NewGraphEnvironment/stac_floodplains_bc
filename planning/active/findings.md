# Findings — Publish multiple species items per WSG (#11)

## Issue context

## Problem

The pipeline publishes exactly **one STAC item per watershed group** — `01_stage.R` reads a
single `primary_scenario` from each WSG's `area.yml` and emits `<wsg>_<primary_scenario>`. A WSG
that has been modelled for a **second species** cannot publish both.

MORR is now the first such case. Its `data/morr/` outputs (produced under floodplains#23) carry
both species:

- coho: `rasters/co_ff04/`, `transition_co_ff04_2017_2023`, `co_ff02/04/06` floodplain layers
- chinook: `rasters/ch_ff06/`, `transition_ch_ff06_2017_2023`, `ch_ff02/04/06` floodplain layers

The chinook LULC was computed on the **ff06** extent (valley bottom), so the desired item is
`morr_ch_ff06` — a non-ff04 headline scenario. Two things block it today:

1. **One-item-per-WSG discovery** — `01_stage.R` only ever reads `primary_scenario`, so the
   chinook outputs are invisible to staging.
2. **The `endsWith(scenario, "_ff04")` guard + ff04-as-footprint** added in #8 assume every
   item's headline scenario is ff04. A `ch_ff06` item trips the guard.

## Why config-driven (not data-driven)

Discovery has to return a **set** of `(species, headline_scenario)` targets per WSG. It could be
inferred from disk (one item per `rasters/<scenario>/` dir with a matching `transition_<scenario>`
landcover layer) — MORR would auto-yield `co_ff04` + `ch_ff06`. That is rejected. The load-bearing
fact is not "there are two items" (disk shows that) but **which scenario is each species' headline**:
chinook has `ch_ff02/04/06` floodplain layers like coho, yet its LULC was run on **ff06**, not the
`ff04` default. That is a modelling/ecology decision and must be **declared**, for three reasons:

1. **The publish layer must not own ecology.** Inferring "chinook headline = ff06" would require a
   hardcoded `species → scenario` rule here — wrong for a repo that does no modelling, and it will
   not generalize to the next area.
2. **Intent, not incidental disk state.** `area.yml` is an allowlist — you publish what you mean to.
   Data-driven publishes whatever is on disk, including `_fire` prototype layers and aborted/
   experimental runs, forcing suppression rules onto the publish layer.
3. **floodplains#23 is actively reshaping `data/<area>/`.** Inferring the item set from disk couples
   this repo to a layout that is mid-migration; a declared list is stable regardless.

## Proposed Solution (config-driven)

Let each WSG declare **multiple publish targets** and emit one item per target.

### Upstream (floodplains) — prerequisite

Extend `area.yml` to declare a list of `(species, headline_scenario)` publish targets rather than a
single `primary_scenario` (MORR → `co_ff04` + `ch_ff06`). Backward compatible: a WSG with one target
behaves exactly as today. Coordinated with floodplains#23 (which produced the multi-species outputs).

### This repo (stac_floodplains_bc)

- `01_stage.R` — iterate the declared targets per WSG, staging one item each. `item_id`, `scenario`,
  rasters (`rasters/<scenario>/`), and the transition-metrics layer (`transition_<scenario>_2017_2023`)
  are already `<scenario>`-keyed, so they generalise directly.
- **Generalise the footprint** to the item's own headline-scenario layer (e.g. `ch_ff06`), and
  **relax the `_ff04` guard** from #8 to "the headline-scenario layer exists" + "the species' three
  `ff02/04/06` layers exist" (the three area properties stay the species' ff02/04/06).
- `05_stac_register.py` / `03_cog_tag.py` — already per-item; no model change expected beyond the
  footprint generalisation flowing through `meta.json`.
- Publish (15 → 16) and reload pgstac from rtj.

## Acceptance

- `morr_ch_ff06` and `morr_co_ff04` both present as distinct items; the other 15 unchanged.
- Item count 15 → 16; each item's footprint is its own headline-scenario extent; area properties are
  that item's species' `floodplain_ff02/04/06_km2`.
- Existing single-target WSGs stage identically to before.

## Not this issue

Disturbance attribution (per-patch `in_fire` / `GROSS_LOSS_FIRE_HA` etc.) is a **separate** schema
concern tracked in #6, gated on floodplains#19. It is orthogonal to the item-discovery model here and
should not be folded in.

Relates to #8, floodplains#23. Do not edit rtj#190 until the new item is published (its reload loads
the then-current collection.json).


## Exploration + Plan-agent review (2026-07-20)

- MORR chinook data complete: rasters/ch_ff06/{classified_2017,2020,2023,transition}.tif;
  transition_ch_ff06_2017_2023 landcover layer; ch_ff02/04/06 floodplain layers.
- All WSG->path keying must move to item-id: 01 dst dirs + meta.json path, 05 asset hrefs
  (meta['wsg_lower']). 02_cog.R + 03_cog_tag.py are dir-agnostic; 04 sync unchanged.
- Plan-agent folded 7 findings: (B1) S3 cleanup trailing-slash or it wipes new item keys;
  (O1) cleanup AFTER verified reload; (O2) 01+05 migrate atomically; (G1) test fully re-key;
  (G2) footprint from scenario layer, ff04 area read separately; (S1) shared gpkgs accepted;
  (A1) assert every href under <item_id>/. Verified non-issues: 02_cog rel-path strip,
  PARTIAL_STAGE single root marker, extent aggregation item-count-agnostic, fallback safe.
- Base: branched off main AFTER PR #7 (coho) + PR #10 (#8) merged, so 01/05 carry #8's
  three-area/footprint/guard code that #11 extends.

## Observation: MORR co and ch floodplain delineations are identical (upstream data)

WSG=morr smoke test: morr_co_ff04 and morr_ch_ff06 report IDENTICAL floodplain areas
(ff02 379 / ff04 411.13 / ff06 432.38) — confirmed by independent ogrinfo: co_ff0N == ch_ff0N
geometry in morr/floodplain.gpkg. Not a publish-layer bug (code reads species-specific layers by
prefix; they coincide in the source). Loss/gain/net DO differ (species-specific transition layers:
ch 482.4/730.6/248.2 vs co 433.8/684.5/250.7). Flag to the floodplains team: are MORR's chinook
floodplain polygons meant to be independently delineated from coho's? Out of scope for #11.

## Phases 3+4 — item-keyed multi-item staging (GREEN)
- 01_stage.R: nested target loop; item-id-keyed dirs; footprint from item's scenario layer; three
  areas via species-prefix token-swap (ff04 read separately); guard relaxed off ff04-only.
- 05_stac_register.py: asset hrefs meta['item_id']; docstring + collection description updated.
- 03_cog_tag.py / 02_cog.R / 04_s3_upload.R unchanged (dir-agnostic).
- WSG=bulk (1 item, fallback) + WSG=morr (2 items) pass; hrefs under <item_id>/; code-check Clean.
- floodplains area.yml targets tested via transient overlay + restore (user's #19 branch untouched).
