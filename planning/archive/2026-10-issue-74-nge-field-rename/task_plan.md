# Task: Move the nge: item fields to standard or descriptive names (#74)

Every custom property this catalogue publishes sits under `nge:`, which names who built the
catalogue and not what the field holds. The family rule (`stac_pointcloud_bc#12`): a field with
a standard home uses it, otherwise its prefix names what it describes, and `nge:` stays only
where New Graph Environment itself is the subject. `stac_airphoto_bc#47` published its half on
2026-10-11.

Outcome: 12 `nge:` properties become `processing:datetime` + `processing:software` (4 fields),
2 `link:*` and 5 `landcover:*`, published as **item JSON only** — no COG re-encoded, no
`file:checksum` moved.

## Decisions (user, 2026-10-13)

- `link:run_uid`, `link:config_sha256` for the run fields.
- **An absent value omits the key**, uniformly across all twelve. Forced for `processing:*`
  (measured: every field is typed `string`, and the item branch's `require_any_field` fails an
  item that declares the extension with no `processing:` field) and applied to the rest for one
  rule. The guard strength that omission costs is bought back by the per-field census below.
- `landcover:stac_url` stays a **property**; no per-item `derived_from` link (the collection
  publishes one, and `check_citation_premise` reads the value).
- **No crate schema** for `link:`/`landcover:` — crate's own rule, and `airphoto:`'s precedent.
  Nothing vendored, nothing waits on a crate deploy.
- **COG tag names are kept** (`NGE_LINK_VERSION` … `NGE_PROVENANCE_NULL`), so
  `02_raster_tag.py`, `01_stage.R`, `fp_provenance.R` and `meta.json`'s field names do not
  change. The rename lives at the publish boundary and the map is the one place the old names
  survive.

## Mapping

| was | now |
|---|---|
| `nge:produced_datetime` | `processing:datetime` |
| `nge:link_version` | `processing:software` → `link`, before the `+` |
| `nge:link_sha` | `processing:software` → `link`, after the `+` |
| `nge:flooded_version` | `processing:software` → `flooded` |
| `nge:drift_version` | `processing:software` → `drift` |
| `nge:link_run_uid` | `link:run_uid` |
| `nge:link_config_sha256` | `link:config_sha256` |
| `nge:landcover_source` | `landcover:source` |
| `nge:landcover_collection` | `landcover:collection` |
| `nge:landcover_stac_url` | `landcover:stac_url` |
| `nge:landcover_key` | `landcover:key` |
| `nge:landcover_item_hash` | `landcover:item_hash` |

## Phase 1: the map, and the writer

- [x] One declared structure in `scripts/item_create.py` replacing `PROV_FIELDS` /
      `NGE_PROV_PROPERTIES`: staged `meta.json` field → published property, with the
      `processing:software` entry name for the four version/sha fields, plus the prefix table
      (`processing` → the extension URL, `link`/`landcover` → `None`).
- [x] `PROCESSING_EXT` declared **iff** the item carries a `processing:` field.
- [x] Property assembly: omit a key whose staged value is absent; omit the whole
      `processing:software` key when no entry has a value; refuse a half-written `link` entry
      (exactly one of version/sha absent is an upstream schema break, not a null).
- [x] `DERIVATION_STATEMENT` — it names two `nge:` properties and ships in the **published
      collection description**.
- [x] The two coverage prints (`_no_prov`, `_untraceable`).

## Phase 2: the guards

- [x] The declared contract in `scripts/item_validate.py`, in published names, hardcoded and
      duplicated rather than imported (the reason is already written at `:429-438`).
- [x] `check_provenance` rewritten. **Not** per-section all-or-nothing: measured on the live
      catalogue, `link_run_uid` is absent on 3 of 23 items while the rest of its section has
      values, so that arm would refuse three live items. Replacement:
      - every published `processing:`/`link:`/`landcover:` key must be in the declared set, and
        every `processing:software` entry name in the declared entry set (this is what still
        catches a typo'd or thirteenth field under an allowed prefix);
      - a **per-field exact census**, a literal a human sets, asserted on a full release only —
        the same shape and reason as `PROVENANCE_FLOOR` and `EXPECTED_DEPRECATED`. Today:
        `link_run_uid` 18, every other field 21. This is what replaces key-set equality's
        uniform-loss detection, and it closes the older hole that the per-section counts were
        printed and never asserted;
      - the item-level floor exact in both directions, and `seen == 0` still a failure.
- [x] `check_processing_stamp`: the extension declared **iff** at least one `processing:` field
      — the iff-pairing `check_version_stamp` and `check_scientific` already use, because the
      schema that would check the field is selected BY the extension list.
- [x] `processing:software` shape: a non-empty object, every value a string, declared entry
      names only. An empty object is schema-valid and satisfies `require_any_field`, so it
      would read as "provenance present".
- [x] `processing:datetime` shape asserted here with a message naming the cause: the schema
      pins a `Z`/`+00:00` suffix on a value passed through verbatim from upstream.
- [x] `check_cog_tags` bridged through the map rather than deriving `NGE_<FIELD>` from the
      property name: three entry kinds (1:1; one software entry → 1 tag; the `link` entry → 2
      tags, reassembled as `NGE_LINK_VERSION + "+" + NGE_LINK_SHA`, never split).
      `NGE_PROVENANCE_NULL` becomes *declared minus present* — a mechanical port of the old
      `v is None` derivation would make it always empty.
- [x] `check_citation_premise`'s claims, `check_deprecated`'s version key (now a
      `processing:software` entry), and the `DERIVATION_STATEMENT` copy.

## Phase 3: prove the new arms fire

- [x] `scripts/prov_fields-check.py`, modelled on `scripts/year_sets-check.py`: synthetic
      `data/stac`-shaped trees with real tagged GeoTIFFs, every assertion grepping **its own**
      message. Fixtures cover all three real populations (12 of 12, 11 of 12, 0 of 12).
- [x] Arms: an undeclared key under an allowed prefix; a resurrected `nge:` key; the census
      short and over; the floor short and over; `processing:software: {}`; a half-written
      `link` entry; `processing:datetime` without the extension; the extension with no
      `processing:` field; `NGE_PROVENANCE_NULL` garbage on an all-null item; each reassembled
      tag perturbed; the map's field domain against `02_raster_tag.py`'s own list.
- [x] Mutation evidence in `findings.md` — each guard removed in turn, the assertions it turns
      red counted.

## Phase 4: the release path

- [x] `scripts/catalogue_release.sh` `--only` preflight, two arms: canonicalise both sides into
      the staged field names (a legacy `nge:` reader and the new map) and keep the per-key
      value→absent refusal; plus a **shape** arm refusing `--only` whenever the live item's
      provenance key shape differs from the build's. Without the second arm the first renamed
      build passes `--only` on the two all-null items, because the API serves them no
      provenance keys at all.
- [x] `scripts/catalogue_release-check.sh`: fixtures re-expressed in real declared names, the
      hard-coded property count, and the assertion strings.

## Phase 5: the staging cross-check

- [x] `scripts/test_pipeline.R`: the `meta.json` ↔ published reconciliation inverts the map
      (12 staged fields ↔ 9 published keys, including the 2→1 `link` collapse) instead of
      differing by a prefix.
- [x] Run one group end to end and read the item JSON.

## Phase 6: what a reader sees

- [x] `NEWS.md` under `## Unreleased`: the mapping table, that a saved filter on an old name
      stops matching, that the `link` entry is split on the **last** `+`, that no COG and no
      checksum moved, and that `processing:datetime` is the land-cover run time.
- [x] `ATTRIBUTION.md` (the `nge:landcover_*` sentence, and "keeps non-null" which omission
      falsifies), `scripts/README.md`, `CLAUDE.md`, and the stale premises in `01_stage.R`,
      `02_raster_tag.py`, `fp_provenance.R`, `catalogue_release-check.sh`'s header.
- [x] Edit issue #74's body: the mapping as shipped, the crate dependency removed, the COG-tag
      question resolved.
- [x] Comment on `crate#23` recording that these prefixes take no schema, and why.

## Validation

- [x] `uv run python scripts/prov_fields-check.py` — 44 assertions, 0 failed
- [x] `bash scripts/catalogue_release-check.sh` — ALL PASS, cases 1-17
- [x] `WSG=larl ALLOW_DRIFT_SKEW=1 Rscript scripts/test_pipeline.R` — PASS, and all 10 assets byte-identical to the live item
- [x] `uv run python scripts/attribution_drift-check.py` — clean
- [x] `/code-check branch` — five rounds, 25 findings, all fixed; ended on an enumeration rather than a quiet round
- [x] PWF checkboxes match landed work
- [x] `/planning-archive`, then `/gh-pr-push`

## Not in this work

The release. The tag, the full rebuild and the publish need AWS + SSH and are the operator's
step; the first renamed release must be **full**, not `--only`, for two independent reasons
(the preflight refuses a renamed contract, and the collection description itself changed).
`NEWS.md` reserves `v2.0.0` for corrected geometry, so the rename ships as a minor with the
breaking-for-consumers note stated in the entry — the number is the operator's call at release.
