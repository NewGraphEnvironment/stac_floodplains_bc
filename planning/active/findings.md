# Findings — Publish run provenance as STAC item properties (#17)

## Measured at plan time, 2026-09-01

### pystac preserves null properties end to end

The issue's central requirement — *"publish the null rather than omitting the key"* — is
achievable. Verified in the repo's own `uv` env:

```python
props = {"wsg": "UFRA", "nge:link_run_uid": None, "nge:link_version": None}
item = pystac.Item(id="probe", ..., properties=props)
d = item.to_dict()
```

```
nge:link_run_uid: present=True value=None
nge:link_version: present=True value=None
after from_dict: {'nge:link_run_uid': None, 'nge:link_version': None}
validate OK
```

Null survives `to_dict()`, a JSON round trip, `from_dict()`, and `validate()`. Had pystac stripped
nulls the whole approach would have needed rethinking, so this was checked before anything was
built on it.

### `NA_real_` serialises as the STRING `"NA"` under `01_stage.R`'s exact write args

The trap. `jsonlite::write_json(auto_unbox = TRUE, pretty = TRUE, digits = 10)` — the current call
at `01_stage.R:259-260`, with no `na =` argument:

```
{ "x": null, "chr": null, "num": "NA", "int": null }
   NA        NA_character_   NA_real_   NA_integer_
```

A numeric provenance field left `NA_real_` would publish as the **string** `"NA"` — which is not
null, reads as a real value to any consumer, and passes every schema check. Adding `na = "null"`
fixes all four types:

```
{ "x": null, "chr": null, "num": null, "int": null }
```

Also measured: `na = "null"` is **byte-inert** on the existing field shapes (`bbox_wgs84`, `years`,
the areas, the metrics) — output identical with and without it. So the change is safe as well as
necessary.

Related dead ends, both rejected: a `NULL` list element is dropped by `jsonlite` and emitted as
`{}`; `list()` is emitted as `[]`. Neither is a JSON null. Bare `NA` plus `na = "null"` is the
idiom.

### The producer's contract, read from its working tree rather than guessed

`floodplains#33` is in flight (`33-record-run-provenance-per-area`, PWF baseline 2026-09-01 14:00).
Its `task_plan.md` decides:

- one merged `data/<area>/provenance.json` **per area** — but this repo publishes one item per
  `(wsg, species, scenario)`, so MORR's two targets share one upstream file. The adapter must
  *select* subsections, not just rename keys.
- sections keyed `network[<species><min_order>]` and `floodplain[<scenario_id>]`, with `inputs` and
  `run` disjoint
- **forward-only**, no backfill: "stac#17 treats the block as optional". Every already-modelled
  area publishes nulls until re-run, so all-null is the normal state and the untraceable count is a
  live number rather than a formality.

This is a working tree mid-flight, so it is **provisional**. It is read as the best available
evidence, not as a contract — which is why the adapter lands last and in one place.

### `nge:landcover_key` is specified wrong in #17's body

`floodplains#33` measured that `drift`'s `stac_cache_key()` (`drift/R/dft_stac_fetch.R:210-227`)
hashes AOI WKB plus request parameters — `res`, `crs`, `dt`, `aggregation`, `resampling`,
`stac_url`, `collection`, `asset` — and **nothing about the items returned**. So if Planetary
Computer re-ingests `io-lulc-annual-v02`, the key is unchanged.

That is precisely the failure #17 exists to catch, so the property as specified could not detect
it. The fingerprint must be a hash over the resolved STAC item ids
(`attr(result, "stac_items")`, present since drift's first commit). #17's body needs correcting.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| Read a stale branch state and reported `floodplains#33` as "not started" | `git fetch` had run minutes before the branch was cut. Re-checked `git worktree list`, which showed `33-record-run-provenance-per-area` checked out. A measurement carries the time it was taken. |
