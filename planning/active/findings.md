# Findings — Collection publishes license: proprietary (#47)

## Measurements taken before planning (2026-09-03)

All read from the producers themselves, not from the issue body.

| fact | source |
|---|---|
| `io-lulc-annual-v02` is `CC-BY-4.0`; licence link `https://creativecommons.org/licenses/by/4.0/`; providers Esri `[licensor]`, Impact Observatory `[processor, producer, licensor]`, Microsoft `[host]`; temporal 2017-01-01 → 2024-01-01 | `GET planetarycomputer.microsoft.com/api/stac/v1/collections/io-lulc-annual-v02` |
| `mrdem-30` is `OGL-Canada-2.0`; no `providers`, no licence link | `GET datacube.services.geo.ca/stac/api/collections/mrdem-30` |
| Live collection: `license: proprietary`, `providers: null`, `sci:citation: null`, `version: 1.0.0`, link rels served = `items/parent/root/self/queryables` only | `GET images.a11s.one/collections/stac-floodplains-bc` |
| Sibling `stac-elevation-bc` serves `providers` **and** `keywords` intact; our own collection serves `version` (an extension field) | `GET images.a11s.one/collections/...` |

## A `rel: license` link survives pgstac — measured, not assumed

The local build publishes **23** `rel: item` links and the API serves **none** of them,
which reads at first as "pgstac drops stored collection links". It does not. From
stac-fastapi-pgstac `stac_fastapi/pgstac/models/links.py`:

```python
INFERRED_LINK_RELS = ["self", "item", "parent", "collection", "root", "items", "child"]
...
links += [{**link, "href": self.resolve(link["href"])}
          for link in extra_links if link["rel"] not in INFERRED_LINK_RELS]
```

`core.py` passes `get_links(extra_links=collection.get("links"))`, so any rel *outside* that
list is kept and its href resolved through `urljoin(base_url, href)` — which returns an
absolute `https://` href unchanged. `item` is in the list; `license` and `derived_from` are
not. So both new links reach the API.

This is reasoning about source, not a measurement of *this* deployment — which is exactly
why Phase 4 reads them back from the live API after the release. `rel: license` is the
least-attested of the three fields we add, because links go through `get_links()`, a
different code path from the stored `content` blob that carries `license` and `sci:citation`.

## The scientific extension validates with no `sci:` field at all

`https://stac-extensions.github.io/scientific/v1.0.0/schema.json`, Collection branch:
`oneOf` → `allOf` → **`anyOf`**. One `anyOf` arm is `{"required": ["summaries"], ...}` and
validates trivially. Our collection has `summaries`. So a collection declaring the extension
with **zero** `sci:` fields passes `pystac.Collection.validate()` clean.

Same shape as the #34/#35 row in `code-check.md`: declaring a schema extension is not
evidence the field is populated. Hence full-string-equality assertions in `item_validate.py`,
not a presence check and not token containment.

## The build tree already holds #26

| | |
|---|---|
| local items | 23 |
| live items | 20 |
| live-but-not-local (orphans) | **none** |
| local-but-not-live | `lnth_ch_ff04`, `thom_ch_ff04`, `unth_ch_ff04` |
| local items carrying a non-null `nge:` value | **21** of 23 |
| distinct `(landcover_source, landcover_collection, landcover_stac_url)` | 21 × `('io-lulc', 'io-lulc-annual-v02', 'https://planetarycomputer.microsoft.com/api/stac/v1')`, 2 × all-null |

So `PROVENANCE_FLOOR=21`, no `--allow-retract` is needed, and the premise assertion in
Phase 2 must treat a **null** `nge:landcover_collection` as legal — 2 items legitimately
carry none, and failing on them would be a guard that fails toward abort.

## Sibling licensing precedent

`stac_dem_bc/LICENSE` and `stac_uav_bc/LICENSE` are both MIT (21 lines,
`Copyright (c) 2025 Allan Irvine`), while their collections publish `CC-BY-4.0`. So the
established split is **code MIT, published data CC BY** — the repo `LICENSE` covers the
scripts, the collection's `license` field covers the products. The issue body asked for
CC BY 4.0 as the repo `LICENSE`; the user chose the sibling-consistent split instead.

`stac_dem_bc/scripts/collection_patch.py` exists for precisely this reason upstream — its
docstring says *"providers — CC-BY-4.0 obliges attribution and the collection carried none."*
It publishes `New Graph Environment` (no `Ltd.`); we publish the legal entity name here per
the issue, so the two collections on one endpoint will differ until `stac_dem_bc` follows.

## Why the literals are duplicated across item_create.py and item_validate.py

`item_validate.py:68-71` gives two reasons for duplicating `REQUIRED_NGE_PROPERTIES` rather
than importing. Only one carries here:

- *"importing that module would run the entire build"* — **still true**, and stronger than
  the comment says: `item_create.py` raises `SystemExit` at module level when nothing is
  staged, and writes 24 files as an import side effect.
- *"derived from the data, a value that vanished would take the expectation with it"* —
  **does not apply**. `license`, `providers` and the citation are literals, not derived.

The decisive reason is a third one: if both sides read one shared constant, the guard
degenerates to `x == x` — a round-trip through our own assignment, which returns identical
forever. Duplication only works because the assertions are **full equality**; token
containment would let the two copies drift arbitrarily far while staying green.

## Plan-agent review (concurrent, pre-baseline)

Eight substantive findings; the load-bearing ones were verified against the tree before
being folded into the plan. What changed:

| finding | change |
|---|---|
| citation guard was token-containment | → full string equality. A bag of words (`"Impact Observatory Esri CC BY 4.0 ..."`) passes containment while attributing nothing |
| providers guard was a `(name, roles)` projection | → full dict compare + `len() == 6`. The projection is blind to a duplicate entry (a set cannot see a repeat) and to a stripped or wrong `url` |
| extension/field check was one-directional | → biconditional, matching `check_version_stamp` |
| placement "after the count check" | → in-loop, before the stamp check. After the count check puts it behind `check_checksums`' 670 MB re-read, which short-circuits it |
| step-5 API check would be tautological in the harness | → three negative `FAKE_LIVE_*` cases. The curl shim serves the fixture back from disk; the harness names this trap itself at lines 42-44 for the version gate |
| nothing tied the citation to the data | → the premise assertion on `nge:landcover_collection` |
| bucket copy unchecked | → mirror the read-back on S3, same argument the file already makes for `version` |
| my own figure of "20 published item links" | → **23**. Corrected |

Its finding that a hand-edit of `collection.json` proves only the validator (rfp#243,
"guard the chooser") is why Phase 3 mutates the constant in `item_create.py` and rebuilds.

## Errors Encountered

| Error | Resolution |
|-------|------------|
