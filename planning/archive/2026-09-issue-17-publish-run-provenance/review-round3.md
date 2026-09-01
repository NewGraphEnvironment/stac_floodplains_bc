# Review — round 3 (#17, `17-publish-run-provenance-as-stac-item-prop`)

Scope: `git diff main...HEAD -- scripts/`, focused on the mechanism rather than more
instances, per the brief.

Everything below was measured against the real reader (`scripts/fp_provenance.R` sourced
directly) with a positive control first. The full 11-path × 4-case matrix is at the bottom.
Current tree passes: `item_validate.py` -> `valid: 2 item(s) + 1 collection(s) /
provenance: 11 nge: properties on every item, COG tags agree`.

---

## Answer to Q1 — the class is closed at depth ≥ 2 and open at depth 1. Here is the enumeration.

I walked all 11 `FP_PROV_MAP` paths through cases (a) section absent, (b) intermediate key
renamed/deleted, (c) leaf renamed, (d) leaf JSON null. 44 mutations plus 10 section-level
ones. Result:

| case | mutations | outcome |
|---|---|---|
| (b) intermediate key renamed or deleted, section present | 16 | **16 STOP** |
| (c) leaf renamed | 11 | **11 STOP** |
| (d) leaf JSON null | 11 | 11 null — correct by design |
| `link_log: null` (modelled absence) | 1 | 3 nulls — correct by design |
| (a) **top-level section key renamed** | 3 | **3 SILENT — 4 / 1 / 6 fields** |
| (a) **open-ended map key renamed** (floodplain/landcover scenario) | 3 | **SILENT — 1 / 6 / 7 fields** |
| open-ended map key renamed (network section name) | 1 | harmless — matched by value, not key |

**The mechanism.** Every guard in `fp_provenance.R` is a *presence assertion on a key the
producer's own document is expected to contain*. A rename emits two signals: a **missing
expected key** (ambiguous with a legitimate absence) and an **unexpected sibling key**
(never ambiguous). The reader only ever reads the first.

That is sufficient at depth ≥ 2 — and that is *why* rounds 1 and 2 closed those levels —
because the parent section being present is itself external evidence that rules out
legitimate absence. `fp_prov_leaf`'s contract ("section present, leaf absent -> stop")
is exactly this observation.

It is **not** sufficient at depth 1, where the parent is the document root and its presence
rules out nothing. So the class is closed at every depth where the parent's presence is
evidence, and open at exactly the two depths where it is not:

- **Axis 1 — fixed schema keys at the root** (`network` / `floodplain` / `landcover`).
  Closable, cheaply: reject unexpected top-level keys against the known set
  `{area, wsg, schema_version, network, floodplain, landcover}` in `fp_prov_read()`.
  A rename leaves `network_v2` behind; a legitimate absence leaves nothing behind. This is
  the same complement-based move that terminates the enumeration rather than sampling it.
- **Axis 2 — open-ended data map keys** (the scenario keys under `floodplain` and
  `landcover`). *Not* closable by unknown-key rejection, because those keys are data.
  This is the untouched axis; see finding 2.

Nothing else remains: (b)/(c) are 27/27 closed, and (d) is the intended behaviour.

---

## Findings

### 1. [fragile] `scripts/fp_provenance.R:100-141` — the "accepted residual" rationale for a renamed top-level section is wrong, and the exposure is 3 sections, not 1

Round 2 recorded a renamed `landcover` key as *"genuinely ambiguous with a legitimately-absent
section — the `schema_version` pin ... is the named guard"* and recommended accepting it. Two
corrections, both measured:

```
RENAME section 'network'    -> network_v2       SILENT NULLS(4)
RENAME section 'floodplain' -> floodplain_v2    SILENT NULLS(1)
RENAME section 'landcover'  -> landcover_v2     SILENT NULLS(6)
```

- **It is all three, not just `landcover`.** A single upstream root rename can take out
  every field in the block, including `nge:link_run_uid` — the one field
  `05_stac_register.py:304` singles out as the run identifier — and `05` will report
  `provenance block: 0/17`, which is the number both `01_stage.R:336-339` and
  `05_stac_register.py:294-296` document as *today's expected reading*. The alarm and the
  normal state are the same number.
- **It is not ambiguous.** A rename leaves an unrecognised sibling key at the root; a
  legitimate absence does not. `schema_version` is the wrong guard for it (it fires only on
  a bump, and an in-flight branch renaming without bumping is the realistic case — round 1
  established this). The discriminating signal exists and is one `setdiff(names(got), known)`
  away.

Not marked `bug` because it needs an upstream rename to happen, and the direction is
"publishes null" rather than "publishes wrong". But the decision to accept it should be
re-made against the correct facts, since the cost of closing it is one line.

---

### 2. [bug] `scripts/fp_provenance.R:138-139` — round-2's section-selection hardening was applied to `network` only; `floodplain` and `landcover` (7 of 11 fields) select by an unvalidated key

```r
floodplain = (prov[["floodplain"]] %||% list())[[scenario]],
landcover  = (prov[["landcover"]]  %||% list())[[scenario]]
```

Compare with the network selector immediately above it, which round 2 hardened: every
present section's shape is validated *before* matching, so an empty match can only mean the
species was not modelled. The two lines above have no shape check, no non-empty-block check,
and no residual analysis — and they match on the **key**, which shape validation cannot
protect anyway.

Measured, block present and non-empty, scenario key re-formatted `co_ff04` -> `ff04`:

```
floodplain scenario key co_ff04 -> ff04      SILENT NULLS(1): flooded_version
landcover  scenario key co_ff04 -> ff04      SILENT NULLS(6): drift_version, produced_datetime,
                                             landcover_source, landcover_collection,
                                             landcover_stac_url, landcover_key
BOTH keys -> ff04                            SILENT NULLS(7)
```

This is the asymmetry that matters: after round 2 the network residual is **one named case**
(species value drift, explicitly accepted). The floodplain/landcover residual is **the entire
key space** and has never been named. A change in how the producer keys its scenario map —
prefixing with the wsg, dropping the species prefix, appending the span — silently nulls 7 of
11 fields on **every item at once**, which is precisely the uniform loss a cross-item check
cannot see (`check_provenance` is absolute and so survives it, but it only asserts the keys
are *present*, and they are — as nulls).

The available external reference, unused: this repo already knows both steps ran for this
scenario. `01_stage.R:242-246` stops if `floodplain.gpkg` lacks the layer named `<scenario>`,
and `01_stage.R:225-230` stops if the landcover bundle lacks
`transition_<scenario>_2017_2023`. Note a per-target guard would false-fire on the legitimate
partial state (producer modelled other scenarios only); the safe form is at WSG level —
*block present and non-empty, and no key matches ANY of this WSG's targets* — which cannot be
a partial state, only a key-format break. Alternatively, mirror the network selector exactly
and match on a value inside the section if floodplains#33 records `scenario_id` in `inputs`.

---

### 3. [bug] `scripts/fp_provenance.R:186-190` — `length(cur) != 1L` is a proxy for "scalar"; a leaf that becomes a single-key object publishes that object's sole member as the value

```r
if (length(cur) != 1L) {
  stop(... "' is length ", length(cur), "; a published STAC property must be scalar.")
}
cur[[1]]
```

`length()` on a list is member count, not scalarity, so a one-member object satisfies the
proxy. Measured:

```
scalar leaf                  : io-lulc
leaf becomes 1-key OBJECT    : io-lulc     class: character     <- published as if scalar
leaf becomes 2-key OBJECT    : STOP
```

This is the **next axis** in a different direction from everything rounds 1-3 have covered:
every other guard in the file protects against *publishing a null in place of a value*. This
one publishes **a wrong value in place of the right one** — strictly worse, because a null is
detectable as "we looked and found none" while `nge:landcover_key = "sha256"` (from
`"item_hash": {"algorithm": "sha256"}`) is indistinguishable from a real hash. `has_prov`
counts it as traced (verified: `TRUE`), `05` publishes it, `03` tags it, and `check_cog_tags`
compares the tag against the property — both derived from the same wrong value, so they
agree.

One line closes it, and it is the same shape as the `%in% names()` fix from round 1 —
assert the property, not a quantity correlated with it:

```r
if (is.list(cur) || length(cur) != 1L) stop(... "must be a scalar, not a container")
```

---

### 4. [fragile] `scripts/fp_provenance.R:66-88` — the reader never checks the document's own `wsg`/`area` against the WSG it was read for

The file header documents the producer's root as `{ "area", "wsg", "schema_version",
"network", "floodplain", "landcover" }`. `fp_prov_read()` reads `schema_version` and ignores
`area` and `wsg` (grepped — nothing in `scripts/*.R` reads either; positive control confirms
the grep matches).

The path is derived (`src_wsg <- file.path(FLOODPLAINS_DATA, wsg)`), so this needs a
misplaced or stale upstream file to fire — but the failure is total and silent: every one of
the 11 fields is published as another area's run provenance, `traced` counts the item as
traced, `05` reports it in `provenance block: N/M`, and every downstream guard agrees because
they all compare the item against itself. It is the same class as finding 2 — an external
reference the code holds and does not use — and the fix is one `identical()`.

---

### 5. [fragile] `scripts/01_stage.R:52-56` — the one uncovered direction across the six field-list copies: adding a field to `PROV_FIELDS` and stopping there is a silent no-op

Answer to Q2. All six copies are identical today (verified by parsing each file). The pair
matrix:

| pair | add-to-one direction | remove-from-one direction |
|---|---|---|
| `01_stage` PROV_FIELDS ↔ `fp_provenance` FP_PROV_MAP | `stopifnot(setequal(...))` ✓ | ✓ |
| `01_stage` ↔ `05` | add to `05`: `meta[f]` KeyError ✓ / **add to `01`: nothing** ✗ | ✓ both |
| `01_stage` ↔ `03` | add to `03`: KeyError ✓ / **add to `01`: nothing** ✗ | ✓ both |
| `05` ↔ `item_validate` | set equality ✓ | ✓ |
| `03` ↔ published item | `check_cog_tags` equality ✓ | ✓ |
| `test_pipeline` ↔ item / meta | containment only; covered by `item_validate` equality | ✓ |

The `03` ↔ item pair is sound in the all-null state too, which is worth recording because it
is the state the repo expects to be in until floodplains#33 lands: `want["NGE_PROVENANCE_NULL"]`
is derived from the item's 12 nulls while `03` writes 11, so the comparison still fires. Round
2's inclusion of that tag is load-bearing, not cosmetic.

The gap: `FP_PROV_MAP` forces `01_stage.R` and `fp_provenance.R` to move together, and nothing
ties **that pair** to `05`/`03`. Add a twelfth field there and stop, and it is staged into
`meta.json`, published nowhere, and all six guards stay green — the field silently never ships,
which for an issue about provenance completeness is the failure mode itself. Cheapest close:
have `01_stage.R` write the field list into `meta.json` (e.g. `nge_prov_fields`) and have `05`
assert set equality against its own `PROV_FIELDS`.

---

### 6. [minor] `scripts/03_cog_tag.py:92` — `assert MANAGED_KEYS` cannot fail

```python
MANAGED_KEYS = ({...SHARED_FIELDS...} | {...PROV_FIELDS...}
                | {PROV_NULL_TAG, "YEAR", "YEAR_FROM", "YEAR_TO"})
assert MANAGED_KEYS, "MANAGED_KEYS is empty — every COG would be skipped"
```

The union includes a non-empty literal set, so `MANAGED_KEYS` is unconditionally truthy and
the assertion is a tautology. The concern behind it is real and correctly stated (`all([])` is
`True`), but the premise it asserts is satisfied by the expression's own structure rather than
by anything that could go wrong — CLAUDE.md's "a premise check satisfied by the happy path's
own structure is decoration". Harmless; noted only so a later reader does not count it as
coverage. If it is meant to guard the field lists being emptied, assert those instead:
`assert PROV_FIELDS and SHARED_FIELDS`.

---

## Q3 — guards whose scope is a coincidence of today's data

Swept; two, both already known and neither newly reachable:

- `item_validate.py:221` `expected_keys = max(asset_keys.values(), key=len)` — expectation
  derived from the data, structurally blind to a uniform loss. Pre-existing (main), and
  `check_provenance` / `check_cog_tags` are the absolute counterparts added by this branch,
  so the provenance half is covered. The *asset* set still has no absolute assertion in the
  release gate (only in `test_pipeline.R`, which `catalogue_release.sh` does not run).
- `fp_prov_leaf`'s `i == 1L && identical(key, "link_log")` — scoped by a fact about today's
  `FP_PROV_MAP` (no path carries `link_log` below depth 1) rather than pinned to it. Round 2
  verified it; still true; still unpinned. Low value to fix.

No third instance found. `REQUIRED_NGE_PROPERTIES`, `check_provenance`'s `seen == 0`,
`check_cog_tags`'s `compared == 0`, and the `pystac.MediaType.COG` comparison are all
absolute or derived from an external constant, which is correct.

---

## Q4 — `has_prov` / `traced` accounting

Re-derived. Sound in every route I could construct except via finding 3 and finding 4:

- `length(v) == 1L && is.na(v)` short-circuits, so `is.na()` never sees a non-length-1 value
  and `&&` cannot hit the R >= 4.3 length error. Confirmed.
- `meta[PROV_FIELDS]` uses `[`, so a missing name yields a `NULL` element rather than an
  error — and `length(NULL) == 1L` is `FALSE`, so it would be counted as **present**. Not
  reachable: `fp_prov_item()` returns `setNames(out, PROV_FIELDS)` unconditionally.
- Name collision between `meta`'s 17 keys and `PROV_FIELDS` would make `meta[PROV_FIELDS]`
  select the *pre-existing* element. Verified empty overlap (all 17 vs all 11). Unguarded, as
  round 2 noted; still a coincidence rather than an assertion, but a collision would also
  corrupt the published property, so it is not specifically an accounting problem.
- `traced` and `staged` are appended in the same block with no `next` between them; the
  counter cannot drift from the staged set.
- **Finding 3 inflates it**: a single-key-object leaf is counted as traced (measured `TRUE`).
- **Finding 4 mis-attributes it**: another area's provenance counts as traced.

Note also that an abort inside the item loop (the new `stop()`s at `fp_provenance.R:121`,
`:175`, `:187`) leaves `data/raw` without a `PARTIAL_STAGE` marker, since the marker is
written at the end of `01_stage.R`. `run_pipeline.sh` is `set -euo pipefail` so the pipeline
halts, and `catalogue_release.sh`'s step-0 live-vs-build comparison would catch a
hand-continued short tree — so this is covered, but it is covered by a different guard than
the one the marker exists to be.

---

## Appendix — the matrix

Reproduced with the real reader (`source("scripts/fp_provenance.R")`, `fp_prov_item()`),
positive control first. Synthetic v1 document matching the shape documented at
`fp_provenance.R:10-15`.

```
=== POSITIVE CONTROL ===
healthy                                        OK (no nulls)

=== (a) top-level SECTION absent / renamed ===
delete section 'network'                       SILENT NULLS(4)   <- legitimate
RENAME section 'network' -> network_v2         SILENT NULLS(4)   <- BREAK, silent
delete section 'floodplain'                    SILENT NULLS(1)   <- legitimate
RENAME section 'floodplain' -> floodplain_v2   SILENT NULLS(1)   <- BREAK, silent
delete section 'landcover'                     SILENT NULLS(6)   <- legitimate
RENAME section 'landcover' -> landcover_v2     SILENT NULLS(6)   <- BREAK, silent

=== (a2) open-ended MAP KEY renamed ===
network map key co3 -> co_3                    OK (no nulls)     <- value-matched, immune
floodplain scenario key co_ff04 -> ff04        SILENT NULLS(1)   <- BREAK, silent
landcover  scenario key co_ff04 -> ff04        SILENT NULLS(6)   <- BREAK, silent
BOTH scenario keys -> ff04                     SILENT NULLS(7)   <- BREAK, silent

=== (b) intermediate key renamed / deleted (section present) === 16/16 STOP
network$co3$inputs               rename/delete   STOP (shape loop, round-2 fix)
network$co3$link_log             rename/delete   STOP (round-1 fix)
network$co3$inputs$link          rename/delete   STOP
floodplain$co_ff04$inputs        rename/delete   STOP
floodplain$co_ff04$inputs$flooded rename/delete  STOP
landcover$co_ff04$inputs         rename/delete   STOP
landcover$co_ff04$inputs$drift   rename/delete   STOP
landcover$co_ff04$run            rename/delete   STOP

=== (c) leaf renamed === 11/11 STOP
link_run_uid link_config_sha256 link_sha link_version flooded_version drift_version
produced_datetime landcover_source landcover_collection landcover_stac_url landcover_key

=== (d) leaf JSON null === 11/11 single silent null — correct by design

=== link_log modelled null === SILENT NULLS(3) — correct by design
```
