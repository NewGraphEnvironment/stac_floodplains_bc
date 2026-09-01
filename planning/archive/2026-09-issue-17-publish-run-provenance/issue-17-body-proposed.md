## Problem

Published items carry modelled figures — `gross_loss_ha`, `gross_gain_ha`, `net_ha`, the three `floodplain_ff0*_km2` areas — with **no way to trace them to the inputs that produced them**. An `rstac` consumer cannot tell whether two items were produced by the same model config, the same package versions, or the same landcover raster.

That last one is the sharp edge: `drift`'s landcover comes from `io-lulc-annual-v02` on Planetary Computer, a remote collection that can be reprocessed upstream. If it is re-derived, our published figures change meaning with no signal in the catalog.

## Proposed solution

Carry the provenance block produced by NewGraphEnvironment/floodplains#33 through `meta.json` and publish it as namespaced STAC item properties, following the `nge:` convention established in NewGraphEnvironment/stac_uav_bc#16:

- `nge:link_config_sha256`, `nge:link_sha`, `nge:link_version`
- `nge:flooded_version`, `nge:drift_version`
- `nge:produced_datetime` (UTC — the model run, **not** the publish time)
- `nge:landcover_source`, `nge:landcover_collection`, `nge:landcover_stac_url`
- `nge:landcover_key` (a hash over the **resolved STAC item ids** — see the correction below;
  this originally read "drift's `stac_cache_key()` fingerprint", which cannot detect the failure
  this issue exists to catch)

Work here is small and mechanical: `01_stage.R` copies the values into `meta.json`, `05_stac_register.py` emits them as item properties, and `03_cog_tag.py` optionally mirrors the key ones as GDAL tags so a downloaded COG is self-describing. **No modelling** — this repo only ferries what it is handed, per its core principle.

Worth publishing rather than leaving upstream: provenance that lives only in the producer's working tree is invisible to anyone consuming the catalog, which is precisely the audience that needs it.

## Blocked on

NewGraphEnvironment/floodplains#33 — this repo cannot publish what does not reach `meta.json`.

## Notes

- Distinct from the deferred STAC **Version Extension** work (#14 item 3). A version says which catalog release an item belongs to; provenance says which inputs produced it. Two items can share a version and differ in provenance if the landcover drifted between runs — so both belong, at different granularities.
- `test_pipeline.R` should assert the properties are present and non-empty once they land, so a regression upstream fails the smoke test rather than publishing silently-unprovenanced items. The `wsg` attribute contract added in #5 is the precedent.
- Adding item properties is backward-compatible: existing `rstac` queries are unaffected.


---

## Addition, 2026-09-01: `nge:link_run_uid`

link#262 (link@v0.49.0) added **`run_uid`** to `<schema>.log` — one value per
dispatch, shared by every host and every WSG in it. It did not exist when this
issue was written.

It is the field that ties a published item to a **specific link run** rather than
to a config. `nge:link_config_sha256` answers *which config*; `run_uid` answers
*which run*, which is what lets a consumer pull the rest of that row —
`fwapg_sha`, `bcfp_model_version`, `bcfp_pin_source`, `wsg_upstream`,
`link_dirty`, `date_end`.

Suggested addition to the property list above:

- `nge:link_run_uid`

**It belongs here rather than in the gpkg.** NewGraphEnvironment/floodplains#52
establishes the split by measurement — input-derived values keep a rebuild
byte-identical, run-event values do not. `run_uid` is a run-event field, so by
that rule the STAC properties are its correct home.

### Expect it to be null at first, and publish it as null

`fresh_default` — the link schema floodplains GRABs its network from — predates
link#262: 26 columns, no `run_uid`, 4 WSGs, newest 2026-08-27. So the first items
carrying this property will carry it as `null` until that schema is next rebuilt.
No migration is needed; `.lnk_log_create_tables()` adds the column idempotently.

Publish the null rather than omitting the key. An absent property reads as "not
implemented"; a null one reads as "we looked and there was not one", and only the
second is true.

Worth counting in the register summary: a published floodplain whose network
cannot be traced should be a number on screen, not a silence.

### One correction to the blocker's premise

NewGraphEnvironment/floodplains#33 proposes deriving `nge:link_config_sha256` as
a *"SHA-256 of the resolved `config.yaml`"*. link's stored `config_hash` is a hash
over **17 files** plus the config name and species list — so a self-computed hash
of `config.yaml` alone would match nothing in link's own log, and the published
property could not be joined back. #33 has been updated; noting it here because
this issue names the property.

### Dependency chain, since these are being worked in parallel

link#264 (git SHAs are currently `NA` — unread from DESCRIPTION, not absent)
-> NewGraphEnvironment/floodplains#33 -> this issue.


---

## Landed, 2026-09-01 — and one correction to the property list above

Implemented in `17-publish-run-provenance-as-stac-item-prop`. Two things in the
original text were wrong or incomplete; both are corrected inline above and
explained here rather than silently rewritten.

### `nge:landcover_key` was specified as a fingerprint that cannot detect the failure

The list above originally named drift's `stac_cache_key()`. NewGraphEnvironment/floodplains#33
measured that it hashes AOI WKB plus the request parameters — `res`, `crs`, `dt`,
`aggregation`, `resampling`, `stac_url`, `collection`, `asset` — and **nothing about the
items returned**. So if Planetary Computer re-ingests `io-lulc-annual-v02`, the key is
unchanged.

That is precisely the drift this issue was opened to make visible, so the property as
originally specified would have published a value that could never move. It is now a hash
over the resolved STAC item ids, which the producer already computes as
`landcover[<scenario>].inputs.item_hash`.

### `nge:link_sha` added to the list

`config_hash` alone is not resolvable. floodplains#33 verified end to end that `link_sha`
**plus** `config_hash` are what recover the exact 17 files a network was built from, so
publishing the hash without the SHA would publish a value nothing could join against.

### Expect every item to publish nulls at first, and do not read that as a defect

floodplains#33 is **forward-only** — no backfill. Every area modelled before it lands
carries no provenance until it is re-run, so `0 of N staged item(s) carry run provenance`
is the correct reading today, not a broken reader. The count is printed by `01_stage.R`
and again by `05_stac_register.py`, and it is the progress signal as areas are re-modelled.

Absence is published as an explicit JSON `null` on every key, never by omitting the key.

### Still unverified: whether a null property survives pgstac

Null survival was measured through `jsonlite` -> `json.loads` -> `pystac` -> `to_dict()` ->
a JSON round trip -> `from_dict()` -> `validate()`. It was **not** measured through
`pypgstac load` and back out of the API, because that needs a write to the live catalog.
If pgstac strips null properties on dehydrate/hydrate, "publish the null" is not
achievable through the API and this issue needs a sentinel-value decision instead. Worth
closing before anyone relies on reading these properties from `images.a11s.one`.
