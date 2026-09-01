# Task: Publish run provenance as STAC item properties (#17)

Published items carry modelled figures — `gross_loss_ha`, `gross_gain_ha`, `net_ha`, the three
`floodplain_ff0*_km2` areas — with **no way to trace them to the inputs that produced them**. An
`rstac` consumer cannot tell whether two items were produced by the same model config, the same
package versions, or the same landcover raster.

That last one is the sharp edge: `drift`'s landcover comes from `io-lulc-annual-v02` on Planetary
Computer, a remote collection that can be reprocessed upstream. If it is re-derived, our published
figures change meaning with no signal in the catalog.

This repo does no modelling — it ferries what it is handed. The producer side is
`NewGraphEnvironment/floodplains#33`, in flight on branch `33-record-run-provenance-per-area`.

## What the producer decided at plan time (read from their `planning/active/`, 2026-09-01)

| decision | consequence here |
|---|---|
| one merged `data/<area>/provenance.json` per area | file location and shape fixed; **per-WSG, not per-target** |
| **forward-only**, no backfill — "stac#17 treats the block as optional" | all-null is the *normal* state, not an edge case |
| sections `network[<species><min_order>]`, `floodplain[<scenario_id>]`, `landcover`; `inputs`/`run` disjoint | the adapter must *select* subsections per item, not just rename keys |
| landcover fingerprint = resolved **STAC item ids**, not `stac_cache_key()` | #17's body is wrong as written |

Their plan is a working tree, mid-flight, and therefore **provisional**. Hence the sequencing:
everything that cannot churn lands first; the one thing that can is isolated to a single adapter
that lands last.

## Phase 1: Property contract, published as nulls

- [x] Verify empirically that a JSON `null` survives `jsonlite::write_json` → `json.loads` →
      `pystac.Item` → `to_dict()` → `validate()`. Record command + output in `findings.md`.
- [x] `scripts/01_stage.R` — add the `nge_*` key set to the `meta` list, NA-filled; add
      `na = "null"` to the `write_json()` call
- [x] `scripts/05_stac_register.py` — emit them as `nge:`-namespaced item properties
- [x] Register summary counts items with untraceable provenance

## Phase 2: Guards that can see a uniform defect

- [x] `scripts/item_validate.py` — **absolute** assertion naming the required `nge:` keys, not a
      cross-item comparison (the existing asset check is uniformity-based and structurally blind)
- [x] `scripts/test_pipeline.R` — extend the item-property contract to the `nge:` set
- [x] Prove each new assertion can fail: drop a key, watch it go red
- [x] Harden the null encoding: `null = "null"` as well as `na = "null"` (an R NULL emits `{}`,
      which passes Python's `is not None` — the exact shape the Phase 4 reader will produce)

## Phase 3: COG tag mirroring

- [ ] Decide + document the GDAL representation of a null provenance value (metadata is
      string-only, so `None` has no native form)
- [ ] Add mirrored keys to `SHARED_FIELDS`; confirm the skip-when-matching branch still re-tags
      when a value transitions null → real

## Phase 4: The adapter (churn-exposed, lands last)

- [ ] `scripts/01_stage.R` — read `$FLOODPLAINS_DATA/<wsg>/provenance.json` when present; absent
      is normal and must not warn loudly
- [ ] **Selection, not just mapping**: resolve `network[<species><min_order>]` /
      `floodplain[<scenario_id>]` per item. MORR has two targets sharing one WSG file; a target
      with no matching subsection publishes nulls, not another target's values
- [ ] `nge:landcover_key` = hash over resolved STAC item ids, **not** `stac_cache_key()`
- [ ] Never recompute `nge:link_config_sha256` — read link's stored `config_hash`

## Phase 5: Reconcile the issue

- [ ] Edit #17's body: correct `nge:landcover_key`, record that all-null is expected under
      forward-only

## Validation

- [ ] Smoke test green on `ufra` (one target) and `morr` (two targets, one WSG file)
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
