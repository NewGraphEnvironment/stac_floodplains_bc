# Findings — Move the nge: item fields to standard or descriptive names (#74)

## Measured 2026-10-13

### The live per-field provenance census (API, nulls dropped)

```
link_run_uid           18
link_config_sha256     21
link_sha               21
link_version           21
flooded_version        21
drift_version          21
produced_datetime      21
landcover_source       21
landcover_collection   21
landcover_stac_url     21
landcover_key          21
landcover_item_hash    21
```

`kotl_bt_ff04`, `larl_bt_ff04`, `sloc_bt_ff04` are missing **only** `link_run_uid`;
`mcgr_ch_ff04` and `pine_bt_ff04` carry none of the twelve. So the catalogue has **three**
populations, not two — which is why the plan's original "per-section all-or-nothing presence"
arm was dropped: it would have refused three live items on its first run. The hole is modelled
upstream (`item_create.py:536-537`: `link_run_uid` is legitimately null on a fresh block whose
schema predates link#262), and `link_sha` / `link_version` come from two different leaves of
the same section (`fp_provenance.R:65-66`), so one-sided nullity is reachable by construction.

### The processing extension v1.2.0 schema (fetched 2026-10-13)

- Every typed field is `string`; **no field admits `null`**.
- `processing:software` is an `object` with `patternProperties {".{1,}": {"type": "string"}}` —
  so `{}` is valid, and entry values must be strings.
- The Item branch is `allOf[require_any_field, fields]`, and `require_any_field` is an `anyOf`
  of seven single-field `required` objects. **Declaring the extension on an item with no
  `processing:` field fails validation.** This is what forces the conditional declaration.
- `processing:datetime` carries `"format": "date-time"` **and** `"pattern": "(\\+00:00|Z)$"`.
  All 21 live `produced_datetime` values end in `Z`; the value is passed through verbatim from
  upstream `landcover$run$datetime_utc`, which this repo does not shape-check, so the pattern
  is a new constraint on an unguarded input.
- `fields` has `additionalProperties: false` with `patternProperties {"^(?!processing:)": {}}`,
  so pystac refuses an **unknown** `processing:` key once the extension is declared, and
  ignores every other prefix.

## The sibling precedents

`stac_airphoto_bc#47` (published 2026-10-11, v1.0.0) is the template:

- `scripts/airphoto_props.py` holds the field map, the named required set, and a prefix table
  `FIELD_PREFIXES = {"proj": …, "file": …, "processing": …, "airphoto": None}` — the `None`
  being the "this catalogue alone writes it, so no schema" case.
- `nge:fly_version` + `nge:fly_sha` became **one** `processing:software` entry,
  `{"fly": "<version>+<sha>"}` (semver build metadata), and `scripts/stac_validate.py`'s
  `tags_disagree()` reassembles `FLY_VERSION + "+" + FLY_SHA` to compare it. That reassembly is
  what let two fields become one without touching a raster.
- COG tag names kept; item JSON only; no schema vendored. It refused the issue's
  checked-in-copies instruction on the ground that it uses no crate schema.
- `airphoto_props.py:203-216` cites this repo's `item_validate.check_provenance` as the
  anti-pattern to avoid — a check that compares items to each other cannot see a key missing
  from all of them.

`stac_pointcloud_bc` is where the vendored-schema mechanism lives (`schemas/<prefix>/vX.Y.Z/`
plus a `schemas_preload()` seeding `pystac`'s `RegisteredValidator` cache). Not used here,
because no crate schema is authored.

crate's rule (`pkgdown/assets/stac/README.md:13`): "A prefix earns a schema here only when more
than one catalogue writes it, or something outside NGE reads it … provenance that only one
catalogue writes goes in the standard fields instead." `crate#23` stays open pending the
prefixes the sibling migrations settle on.

## Plan review (Plan agent, 2026-10-13)

Findings folded into `task_plan.md` before the baseline. The ones that changed the design:

| finding | what changed |
|---|---|
| per-section all-or-nothing is false on 3 live items | replaced by a per-field exact census (verified above) |
| a prefix table is weaker than the key-set equality it replaces | the declared **key** set is still asserted — every published key must be declared, entry names included |
| the per-section counts were printed, never asserted | the census is the assertion; a section lost on every item used to pass |
| `processing:software` spans all three upstream sections | sections re-addressed as (property, entry) pairs |
| `{}` and `{"link": "+<sha>"}` are schema-valid | both refused explicitly; one-sided version/sha is an upstream break, not a null |
| `--only`'s preflight goes blind on the renamed build | two arms: canonicalised value-loss, plus a key-shape comparison that covers the two all-null items |
| the fixtures `nge:probe`/`nge:kept` become vacuous once the preflight canonicalises | re-expressed in real declared names |
| `NGE_PROVENANCE_NULL` must be derived as declared-minus-present | a mechanical port keeps `v is None` and makes it always empty |
| the map's field domain needs a totality check against `02_raster_tag.py` | asserted in the new driver and in `test_pipeline.R` |
| stale premises outside the listed files | `01_stage.R:44`, `02_raster_tag.py:75-82`, `fp_provenance.R:5`, `catalogue_release-check.sh` header, seven `CLAUDE.md` facts |
| `index.html` / `README.Rmd` / `readme_functions.R` are clean | every `nge:` hit there is a minified-JS `change:` substring; no time spent |

## The rename moves no bytes — measured, not reasoned (2026-10-13)

`WSG=larl ALLOW_DRIFT_SKEW=1 Rscript scripts/test_pipeline.R` passes end to end in ~21 s, and
the item it builds was compared asset by asset against what the API serves for
`larl_bt_ff04`:

```
identical file:checksum : 10 of 10 assets
moved                   : 0
```

So the claim that this is an item-JSON-only change is a measurement. `larl` is also one of the
three items in the 11-of-12 population, so the run exercised the omitted-key path: it published
8 provenance keys (no `link:run_uid`), and its COGs still carry all eleven `NGE_` value tags
plus `NGE_PROVENANCE_NULL = link_run_uid`.

The skew override is still required (`drift` 0.20.0 installed against 0.8.0 in the record) —
re-measured here rather than taken from the note, and it changed no bytes for this group.

## Mutation table (2026-10-13)

`scripts/prov_fields-check.py` is 38 assertions, 0 failed. Each guard was then removed in a
**copy** of `scripts/` and the driver re-run, so the measurement is of the guard and not of
the working tree:

| defect restored | assertions red |
|---|---|
| the declared-key arm | 2 |
| the stray-software-entry arm | 1 |
| the per-field census | 4 |
| the floor | 1 |
| `seen == 0` | 1 |
| `check_field_prefixes` | 3 |
| the processing-extension biconditional | 2 |
| the empty-software-map arm | 1 |
| the `<version>+<sha>` pair arm | 1 |
| the `processing:datetime` shape arm | 1 |
| the COG-tag reassembly | 2 |
| `NGE_PROVENANCE_NULL` as declared-minus-present (ported mechanically instead) | 1 |
| holding the bridged tags out of the generic diff | 1 |
| **the writer's refusal of a half-present software entry** | **0** |

The last row is the honest gap. The driver mirrors `item_create.py`'s writer rather than
importing it — importing runs the whole build — so mutating the writer cannot turn the driver
red. What *is* proven is the backstop that decides whether such a tree can be published: the
validator's `<version>+<sha>` arm, which refuses a half-present entry whatever wrote it. The
writer's own `raise` is a fail-fast convenience in front of that, and the two literal maps are
pinned to each other statically by the first three assertions, which parse
`item_create.py` and `02_raster_tag.py` instead of trusting the mirror.

## Errors Encountered

| Error | Resolution |
|-------|------------|

## Issue context

**If we do it:** each field an item carries says what it is. Clients that know the standard extension read the standard fields, and a reader does not have to know that `nge` means New Graph Environment. **If we never do:** the fields stay readable only to people who know the initials.

Decided for the catalogue family in NewGraphEnvironment/stac_pointcloud_bc#12 (2026-10-10):
- A field with a standard home uses it.
- Otherwise its prefix names what it describes.
- `nge:` stays only where New Graph Environment itself is the subject.

Each custom prefix gets a JSON Schema in crate, which items list in `stac_extensions` (NewGraphEnvironment/crate#23 is the umbrella; `lidarbc` and `las` are done there). **Prefer a standard field.** A custom prefix earns a crate schema only when more than one catalogue writes it, or something outside NGE reads it (`crate/pkgdown/assets/stac/README.md`), because every schema is permanent and every field change is a new version. Provenance that only this catalogue writes goes in `processing:*` or a `derived_from` link.

Once the mapping below is settled, file one crate issue for the custom prefixes that remain and link it from crate#23. This catalogue's rebuild waits on that crate deploy. Validate against copies of the schemas checked into this repo, as stac_pointcloud_bc#2 does, not against the live URLs. The [processing extension](https://github.com/stac-extensions/processing) (v1.2.0) defines `processing:datetime`, `processing:version`, `processing:software` (a name → version map) and `processing:lineage`.

## Fields (main, 2026-10-10)

The mapping below is a proposal. Check each row against what the field holds before renaming it.

| field | proposed | note |
|---|---|---|
| `nge:produced_datetime` | `processing:datetime` | the same meaning |
| `nge:flooded_version`, `nge:link_version`, `nge:drift_version` | `processing:software` `{"flooded": …, "link": …, "drift": …}` | |
| `nge:link_sha`, `nge:link_config_sha`, `nge:link_run_uid` | a prefix naming the link run (e.g. `link:`) | provenance with no standard home |
| `nge:landcover_stac_url` | a `derived_from` link to the land-cover item | a STAC core relation |
| `nge:landcover_collection`, `nge:landcover_source`, `nge:landcover_key`, `nge:landcover_item_hash` | a `landcover:` prefix | they describe the input land cover, not NGE |

`nge:probe`, `nge:kept` and `nge:x` appear only in test fixtures (`scripts/catalogue_release-check.sh`, `scripts/test_pipeline.R`), not in items.

## Do the COG tags move too? (decides the cost)

Not in the mapping above, and it is the difference between an item-JSON republish and
re-encoding the whole catalogue.

`02_raster_tag.py:250` derives each COG tag name as `NGE_<FIELD>` from `PROV_FIELDS`, and
`item_validate.py:546` verifies *"each COG's `NGE_` tags agree with its item's non-null `nge:`
properties"*. So renaming the properties either breaks that cross-check or moves the tags with
them — and moving the tags rewrites every COG's bytes, so every `file:checksum` in all 23 items
moves, on a bucket with **no rollback**.

**stac_airphoto_bc#47 already decided this for the family, and chose to keep the tag names:**
*"The COG tags keep their names (`FLY_VERSION`, `FLY_SHA`, `PIPELINE_SHA`), so the rename moves
no checksum."* It published 2026-10-11 as item JSON only, 0 of 10,100 API items left carrying an
`nge:` key. Following it here means the cross-check gains a property → tag-name map (the one
place the old names survive) and this catalogue's rename needs **no COG rebuild at all** —
which also means it does not have to wait for a rebuild, contrary to the "When" section below.

Worth confirming against airphoto's `stac_validate.py` before committing to it, since this
repo's tag set is 12 fields rather than 4 and `PROV_NULL_TAG` has no property counterpart.

## When

Renaming changes every published item, so it rides with this catalogue's next full rebuild, not a release of its own. NEWS names each old → new pair, because a saved filter on an old name stops matching.



