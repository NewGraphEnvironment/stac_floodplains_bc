## Outcome

`scenario` and a derived numeric `flood_factor` are now queryable STAC item properties, and the
collection carries `summaries` (it had none). Server-side filtering works: `flood_factor eq 6`
returns exactly `morr_ch_ff06`, `eq 4` the other sixteen, and the range form `gte 6` works — which
is the reason for publishing a number rather than only the `ch_ff06` string.

This closed a contract that upstream already documented but only half-enforced. `floodplains`'
README states `wsg`/`species`/`scenario` are each **both** a STAC property and a gpkg column; the
gpkg half was guarded here by `test_pipeline.R` since #5, the STAC half silently was not. A second
asymmetry made it easy to miss: `03_cog_tag.py` already tagged `SCENARIO`, so a **downloaded GeoTIFF
knew its flood factor while the STAC item pointing at it did not**.

**The blind spot was in the test suite's shape, not in anyone's attention.** Every existing
assertion worked off `meta.json` or the GeoPackages — nothing ever read the built item JSON's
`properties`. A property missing from the published item therefore passed green for the entire life
of the collection. The fix adds that missing kind of assertion, not just the missing property.

Two review findings worth carrying forward. First, the `flood_factor` summary was initially a STAC
**Range Object** `{minimum: 4, maximum: 6}` — a continuous interval over a discrete set, advertising
`flood_factor = 5` as available. Since summaries are sold as the way to discover values without
downloading 3–9 MB items, a client building a filter list from it would offer 5 and get nothing;
now a Set of Values. Second, and more serious: items are written to disk one at a time, so a parse
failure partway would leave a **mixture** of fresh and stale item JSONs beside a stale
`collection.json` — a mixture that passes *every* release guard (collection present, count correct,
all valid, no orphans) and would publish to a bucket with versioning Suspended. A preflight over
every scenario now runs before the first write.

Method note: the backfill took the **fast path** — `05` → `item_validate.py` →
`catalogue_release.sh`, ~4 minutes, instead of a ~20-minute `run_pipeline.sh` that would have
re-converted byte-identical COGs. That was only safe because Phase 0 proved all 17 local item JSONs
were byte-identical to what was live, so the rebuild demonstrably operated on the tree that produced
production. A structural diff then confirmed the change was purely additive across all 17 items.
Cheap to verify, and it is what made the shortcut defensible rather than merely convenient.

Closed by: PR #20.
