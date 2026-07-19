## Outcome

Added the upstream `floodplain.gpkg` delineations as a second STAC vector asset (`floodplain`)
on every item, and replaced the single `floodplain_km2` property with symmetric per-flood-factor
areas `floodplain_ff02_km2` / `floodplain_ff04_km2` / `floodplain_ff06_km2` — a clean schema
break (brand-new collection, single consumer, no back-compat alias). ff04 stays the item
footprint; item count unchanged at 15.

Delivered in 5 atomic phases: (1) encode the new contract in `test_pipeline.R` (red→green);
(2) `01_stage.R` copies `floodplain.gpkg` and computes all three areas by species-prefix
token-swap (guarded: primary must be `_ff04`, all three ff layers must exist); (3) `03_cog_tag.py`
+ `05_stac_register.py` follow the rename (bundled with 2 because `05` hard-indexed the old key)
and `05` adds the `floodplain` asset + a guard entry; (4) both READMEs updated and the repo swept
to zero `floodplain_km2` (except the intentional `is.null()` test assertion); (5) all 15 items
re-published to S3 with the new schema and validated.

Verified: `WSG=bulk` smoke test green; ff areas recompute exactly from the source gpkg
(ff02 428.29 / ff04 490.47 / ff06 540.03, correctly nested); all 15 S3 item JSONs carry the three
area props + `floodplain` asset (spot-checked `bulk` + older `fran`); Plan-agent review + code-check
round 1 clean. A Plan-agent review before implementation caught 5 issues folded into the plan
(atomic 01+03+05 rename, `scripts/README.md` as a second doc surface, the root-README `floodplain`
mislabel, positive-presence check, and the `endsWith(scenario,"_ff04")` guard).

Forward-compatible with floodplains#23 (multi-species per area): areas are selected by the
primary-species prefix, never positionally, so a second species' layers in the same
`floodplain.gpkg` are ignored.

Closed by: commits ff8e55d → 5e77ec4 on branch `8-publish-floodplain-gpkg-delineations-ff0`
(PR pending). Live step out-of-repo: the geoserv pgstac reload (rtj#190, updated to subsume both
the coho load and this schema migration) — once it runs, `images.a11s.one` serves 15 items with
the new asset + properties.
Related: #8, rtj#190, floodplains#23 (multi-species data), #5 (wsg tagging, out of scope here).
