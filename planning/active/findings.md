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

## Measured during implementation, 2026-09-01

### GDAL: three facts that decided the COG tag design

| probe | result |
|---|---|
| `update_tags(**{"NGE:LINK_RUN_UID": "abc"})` | round-trips as key `NGE`, value `LINK_RUN_UID=abc` |
| write `""` to a fresh key | key absent on read |
| write `""` over an existing key | key **deleted** |
| `update_tags()` called twice with different sets | **merges** — a stale key survives a rewrite |

The colon finding is decisive: eleven `nge:`-prefixed fields would have collapsed into one
`NGE` tag holding whichever was written last, uniformly and silently, on every COG. Keys are
`NGE_<FIELD>`.

The empty string is the only honest encoding of a null — `str(None)` writes the literal
`'None'`, and `'NA'`/`'null'` round-trip as ordinary strings a consumer cannot tell from a real
value. That it also *deletes* is what makes it the clearing mechanism, which matters because
`update_tags()` merges.

### The pre-existing skip-branch bug

`all(existing.get(k) == v for k, v in tags.items())` iterates only the keys being written, so a
key that must now be **absent** is never compared: `all()` over the smaller set is `True`, and
the stale tag survives. Reachable only when 03 is re-run without 01/02 — `01_stage.R` unlinks
`data/stac` and `02_cog.R` regenerates every COG unconditionally, so the normal pipeline always
tags fresh files. Fixed with a managed-key comparison anyway.

Note the naive fix does not work: with `""` in the write dict, `existing.get(k)` is `None` and
`v` is `""`, so the comparison never matches and every COG re-tags on every run forever. Both
sides must be normalised to what a read returns.

### The producer's real leaf paths

Read from `floodplains/scripts/floodplain_lcc/fp_provenance.R` and its three call sites, now
tracked rather than untracked:

| our field | upstream path |
|---|---|
| `link_run_uid` / `link_config_sha256` / `link_sha` | `network[k]$link_log$run_uid` / `$config_hash` / `$link_sha` |
| `link_version` | `network[k]$inputs$link$version` |
| `flooded_version` | `floodplain[scenario]$inputs$flooded$version` |
| `drift_version` | `landcover[scenario]$inputs$drift$version` |
| `produced_datetime` | `landcover[scenario]$run$datetime_utc` |
| `landcover_source` / `_collection` / `_stac_url` / `_key` | `landcover[scenario]$inputs$source` / `$collection` / `$stac_url` / `$item_hash` |

`link_log` is legitimately `NULL` when there is no log row for the area or the log is
unreadable — the producer records why in `link_log_note`. That is a modelled absence, not a
schema break, and the reader treats it as such.

### The network section is matched, not derived

Upstream keys it `paste0(species, min_order)`. Every `config/<wsg>/area.yml` on disk has
`min_order: 3`, so a derivation and a hardcoded `"3"` are indistinguishable and no test of it
could fail. The section records `inputs$species` itself, so it is matched on that instead — the
producer states the join rather than us re-deriving it.

### The MORR trap, restored and confirmed

MORR's `area.yml` declares `species: co` at the top level and then two targets, `co` and `ch`.
Reading the area-level value instead of the target's gives both items coho's network:

```
area$species : run_uids ['RUN-MORR-co', 'RUN-MORR-co']   <- chinook item silently wrong
tgt species  : run_uids ['RUN-MORR-co', 'RUN-MORR-ch']
```

Both are valid strings, so nothing would have errored.

### What the fixture does and does not prove

The fixture was generated by sourcing **the producer's own `fp_prov_set()`/`fp_prov_write()`**,
so the nesting, key sorting, null encoding and `schema_version` come from their code rather than
ours. That is materially better than hand-written JSON, and it is still **not** interop
validation: we supplied the section contents, so it cannot detect that upstream names a leaf
differently from what `FP_PROV_MAP` expects.

The guard for that is the leaf-rename hard stop, proven below — not the fixture.

| restored defect | result |
|---|---|
| `area$species` instead of the target's | both items get coho provenance (the trap) |
| `schema_version: 2` | stops, naming both versions |
| `item_hash` renamed to `item_digest` | stops: "schema break, not an absence" |
| a field dropped from `01_stage.R`'s list | `KeyError` in 05, naming the field |
| every value null | passes — the normal state under forward-only |
