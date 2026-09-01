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

- [x] Decide + document the GDAL representation of a null provenance value (metadata is
      string-only, so `None` has no native form) — the empty string, which GDAL treats as
      absence in both directions and which therefore also clears a stale tag
- [x] Add mirrored `NGE_<FIELD>` keys (never `NGE:` — a colon collapses all eleven into one
      tag); fix the skip branch to compare over a managed key set

## Phase 4: The adapter (churn-exposed, lands last)

- [x] `scripts/fp_provenance.R` — the only file that knows the producer's shape; sourced by
      `01_stage.R` alongside `fp_gpkg.R`. Absent is normal and silent.
- [x] **Selection, not just mapping**: the network section is matched on its own recorded
      `inputs$species` rather than by rebuilding `paste0(species, min_order)` — the producer
      already states the join, and every `area.yml` on disk has `min_order: 3`, so a derivation
      and a hardcoded "3" would be indistinguishable
- [x] Pin `schema_version`; hard-stop on a present section with a missing declared leaf, so an
      upstream rename is a refusal rather than an invisible null
- [x] `nge:landcover_key` = `inputs$item_hash`, a hash over resolved STAC item ids
- [x] Never recompute `nge:link_config_sha256` — read link's stored `config_hash`

## Phase 5: Reconcile the issue

- [x] Draft the corrected #17 body — `planning/active/issue-17-body-proposed.md`
- [ ] **BLOCKED — needs the user to run it.** `gh issue edit` was refused by a safety
      classifier in this session. Apply with:
      `gh issue edit 17 --body-file planning/active/issue-17-body-proposed.md`

## Validation

- [x] Smoke test green on `ufra` (one target) and `morr` (two targets, one WSG file)
- [x] Guards proven against both answers rather than reasoned about
- [x] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion

## Carried forward — not done here

- **pgstac null survival is unverified.** Nulls were measured through jsonlite → json.loads
  → pystac → to_dict() → JSON round trip → from_dict() → validate(). They were NOT measured
  through `pypgstac load` and back out of the API, which needs a write to the live catalog.
  If pgstac strips nulls on dehydrate/hydrate, "publish the null" is unachievable through the
  API and the issue needs a sentinel-value decision. Close this before anyone relies on
  reading these properties from `images.a11s.one`.
- **The adapter is unverified against real upstream bytes.** The fixture was built with the
  producer's own writer, but we supplied the section contents — so it cannot detect an
  upstream leaf rename. The `schema_version` pin and the leaf-rename hard stop are the guards
  that cover it; they are proven, the mapping is not.
- **Flip the traceability floor** once floodplains#33 lands and areas are re-modelled, so a
  reader that silently finds nothing fails the release rather than publishing all-null.
