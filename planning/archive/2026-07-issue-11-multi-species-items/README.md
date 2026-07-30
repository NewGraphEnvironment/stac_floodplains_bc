## Outcome

Generalised the publish layer from **one item per watershed group** to **one item per modelled
`(species, scenario)` target**, and migrated all asset paths from WSG-keyed (`<wsg>/`) to
**item-keyed** (`<item_id>/`). MORR now publishes both `morr_co_ff04` (coho) and `morr_ch_ff06`
(chinook, headline extent ff06) — 15 → **16 items**, live on `images.a11s.one`.

Delivered in 6 phases: (1) upstream `targets` list in `floodplains/config/morr/area.yml`
(floodplains PR #25) — discovery is **config-driven**, since which extent is a species' headline
(ch→ff06, not the ff04 default) is a modelling decision the publish layer must not infer;
(2) smoke test re-keyed to iterate item dirs and assert staged-count == declared targets;
(3+4, one commit) `01_stage.R` nested target loop + item-keyed staging, footprint from the item's
own scenario layer (areas still read the three species-prefixed ff layers independently), #8's
ff04-only guard relaxed, and `05_stac_register.py` hrefs switched to `meta['item_id']`;
(5) docs; (6) publish + reload.

Key decisions and learnings:
- **Item-keyed paths were forced by the model**, not chosen for tidiness: two MORR items would
  otherwise both resolve to `s3://…/morr/classified_2017.tif` with different content.
- **01 + 05 had to migrate atomically** — splitting them would leave `collection.json` pointing at
  `<wsg>/` while assets uploaded to `<item_id>/` (dead hrefs).
- **Cleanup ordering**: old flat prefixes could only be deleted *after* the pgstac reload, since the
  then-live 15 items still referenced them. And deletion must use a **trailing slash**
  (`s3://…/<wsg>/`) — every old WSG name is a string-prefix of its new item id, so `s3://…/bulk`
  would have matched `bulk_co_ff04/` and destroyed the new assets. Dry-run confirmed 90 objects,
  zero item-keyed matches.
- A Plan-agent review before implementation caught 7 issues (the cleanup prefix hazard as a
  blocker, the cleanup/reload ordering, the atomic 01+05 requirement, the fully-wsg-keyed test, the
  footprint-vs-ff04-area split, shared-gpkg scope, and the positive href assertion).
- **Upstream observation (not a publish bug):** MORR's chinook floodplain polygons are area-identical
  to coho's (co_ff0N == ch_ff0N); tree-change figures do differ. Worth confirming with the
  floodplains team whether chinook was independently delineated.

Verified: full local 16-item dry-run + published S3 build both pass the positive check (three nested
ff areas, both gpkg assets, no `floodplain_km2`, every href under `<item_id>/`); live API returns 16
with all items item-keyed; code-check clean.

Closed by: commits 5fe1ad8 → edc96b5 on branch `11-publish-multiple-species-items-per-water`.
Related: floodplains#25 (targets), floodplains#23 (multi-species outputs), rtj#198 (pgstac reload,
run), #8 (the schema this builds on).

**Outstanding:** the 90 orphaned objects (0.4 GB) at the old flat `s3://stac-floodplains-bc/<wsg>/`
prefixes are still present — deletion is verified-safe (dry-run: 90 objects, no item-keyed matches)
but awaits explicit authorization. Nothing references them.
