# Review round 1 — #17 run provenance (`17-publish-run-provenance-as-stac-item-prop`)

Scope: `git diff main...HEAD -- scripts/` — `01_stage.R`, `fp_provenance.R`, `03_cog_tag.py`,
`05_stac_register.py`, `item_validate.py`, `test_pipeline.R`.

Everything below was probed against the real code, with a positive control where the claim is
about a branch not being taken. Items listed in the brief as ALREADY MEASURED were re-verified
where they were load-bearing for a finding, and all held.

---

## Findings

### 1. **[bug]** `scripts/fp_provenance.R:141` — the `link_log` exception cannot tell a modelled null from a schema break, so an upstream rename publishes silent nulls

```r
if (i == 1L && identical(key, "link_log") && is.null(cur[["link_log"]])) {
  # Modelled absence — the producer could not read link's log for this area.
  return(NA)
}
```

`cur[["link_log"]]` is `NULL` in **two** different states, and the function's whole thesis is
that they must be treated differently:

| upstream state | what it means | what the function documents | what it does |
|---|---|---|---|
| `"link_log": null` | producer found no log row | NA -> publish null | NA ✓ |
| `link_log` key **absent / renamed** | schema break | `stop()` | **NA -> publish null** ✗ |

This is the exact distinction the brief records as measured — `read_json` retains the name for a
JSON null, so `%in% names()` separates the two and `[[ ]]` does not — and line 145 immediately
below uses `%in% names(cur)` correctly for every other key. Line 141 is the one place that
reaches for `[[ ]]`, and it is the one place where the two states diverge.

Verified against the real reader (`fp_prov_item` -> `fp_prov_leaf`), with a positive control so a
non-firing probe is distinguishable from a passing one:

```
A. link_log fully present         expect value    ACTUAL: RUN1                    (control fires)
B. "link_log": null               expect NA       ACTUAL: NA -> null              (correct)
C. link_log KEY ABSENT            expect stop()   ACTUAL: NA -> published as null (WRONG)
D. link_log RENAMED to linkLog    expect stop()   ACTUAL: NA -> published as null (WRONG)
```

(An earlier run of this probe reported C as "passes through unchanged" because a `sub()` regex
missed a newline and never mutated the JSON. Rebuilt with explicit inputs; the table above is
from the rebuilt probe.)

**Why it matters beyond the one branch.** Three fields ride on `link_log` —
`link_run_uid`, `link_config_sha256`, `link_sha`. `nge:link_run_uid` is the field
`05_stac_register.py:305` singles out for its own counter, on the stated grounds that it is
"legitimately null even on a fresh block". After a rename, that counter reports the items as
untraceable-but-fine, which is indistinguishable from the normal forward-only state the whole
feature exists to make legible. Per the file's own comment, this "would be invisible for as long
as nobody happened to compare a published property against the producer's own file".

**The schema-version pin is not a backstop for this.** `fp_prov_read()` only fires when upstream
*bumps* `schema_version`. A rename shipped without a bump — the realistic case for an in-flight
branch (floodplains#33) that has not yet emitted a file — sails straight through it into this
branch.

Fix is one clause, matching the style already used two lines below:

```r
if (i == 1L && identical(key, "link_log") && is.list(cur) &&
    "link_log" %in% names(cur) && is.null(cur[["link_log"]])) {
  return(NA)
}
```

Worth pinning with a test, since the failing direction is silent: assert case C/D `stop()` and
case B returns NA, in one table.

---

### 2. **[fragile]** `scripts/fp_provenance.R:141` — a producer using jsonlite defaults emits `{}` for a null `link_log`, which hard-stops the entire staging run

`01_stage.R:307-317` documents at length that `jsonlite` serialises an R `NULL` as `{}` unless
`null = "null"` is passed, and sets it on this repo's writer. The producer is a sibling R repo
subject to the identical trap, and nothing here anticipates it. Measured:

```
producer with jsonlite DEFAULTS : {"link_log":{},"other":"x"}
producer with null = "null"     : {"link_log":null,"other":"x"}
```

Fed `"link_log": {}`, the reader does not take the exception (`list()` is not `NULL`), falls to
the `%in% names()` check on `run_uid`, and aborts:

```
STOP: provenance.json TEST [link_run_uid]: section is present but key 'link_log$run_uid'
is missing ... This is a schema break, not an absence
```

That refusal takes down staging for the whole region, on input the producer intends as a routine
modelled absence. This fails **loud**, which is the safe direction and why this is `fragile` and
not `bug` — but it is a foreseeable first-contact failure with an upstream that has not shipped
yet, and the fix is cheap: treat a zero-length list at `link_log` as the same modelled absence as
`null`, or state the `null = "null"` requirement as an explicit contract on floodplains#33.

---

### 3. **[fragile]** `scripts/03_cog_tag.py:120-125` — the stale-tag guard detects a stale SHARED field but cannot clear it, so it re-tags forever and the stale tag survives

The `MANAGED_KEYS` comparison is correct and the reasoning in its comment is right: comparing over
the managed set rather than `tags.items()` is what lets a now-absent key register as a mismatch.
I verified the three GDAL behaviours it rests on, all exactly as documented:

```
1 fresh empty-string key present?   False          (write "" -> key absent)
2 NGE_B after writing "" over it:   None           (write "" -> key deleted)
3 after writing OTHER only, KEEP:   1  -> merge    (update_tags merges)
4 colon key:  {'NGE': 'X=abc'}                     (colon collapses the namespace)
```

The asymmetry is between the two tag builders. `provenance_tags()` writes `""` for a null, which
**deletes**; `shared_tags()` *omits* a `None` field entirely, so there is nothing to delete with.
So for a shared field that becomes null:

- the skip check correctly detects the mismatch (`existing.get(k)` is a value, `want.get(k)` is `None`),
- `update_tags(**tags)` merges and the key is not in `tags`, so nothing is removed,
- next run detects the same mismatch again — a non-converging re-tag loop, with the stale value
  still on the published COG.

Reachability is genuinely low: it needs a `SHARED_FIELDS` member to be null in `meta.json` on a
re-run of 03 without 01/02, and 01 writes all of them for any well-formed `area.yml`. But the
comment above `MANAGED_KEYS` claims this guard stops "the stale tag survives on a published
asset", and for the shared half that claim does not hold. Making `shared_tags()` emit `""` rather
than skipping would close it and would make the two builders agree on one encoding.

---

### 4. **[fragile]** `scripts/03_cog_tag.py:37-41` — `PROV_FIELDS` is the one copy of the field set with no guard in the add direction, and nothing validates the `NGE_` tags

The set is now declared in five places. Four of them are tied together:

| copy | guarded by | direction covered |
|---|---|---|
| `01_stage.R` `PROV_FIELDS` | `stopifnot(setequal(...))` in `fp_provenance.R:56` | both |
| `fp_provenance.R` `FP_PROV_MAP` | same `stopifnot` | both |
| `05_stac_register.py` | `item_validate.py` set **equality** | both |
| `item_validate.py` | same | both |
| **`03_cog_tag.py`** | — | **add direction not covered** |

Adding a twelfth field to `01_stage.R` / `05` / `item_validate.py` and forgetting `03_cog_tag.py`
produces no error anywhere: `provenance_tags()` iterates its own shorter list, `MANAGED_KEYS` is
derived from that same list, `item_validate.py` never reads a COG, and `test_pipeline.R` asserts
only on item JSON and `meta.json` (grepped — there is no `NGE_` assertion anywhere in the repo).
The COGs ship with a silently incomplete tag set. The reverse direction is safe: a field in `03`
but not in `meta.json` raises `KeyError` on `meta[f]`.

`item_validate.py`'s docstring states set equality is "what keeps the two lists in step now that
they cannot import from one another" — accurate for the pair it names, and worth noting it does
not extend to the tag mirror. Cheapest close: assert in `test_pipeline.R` that the smoke-test COG
carries exactly `{NGE_<F> for F in PROV_FIELDS} | {NGE_PROVENANCE_NULL}` minus the null-encoded
ones, which also gives the tag path its first end-to-end assertion.

---

### 5. **[fragile]** `scripts/fp_provenance.R:81,104,105,115,116` — `$` partial-matches on lists, in the one file whose job is to make an upstream rename loud

`$` on a list falls back to prefix matching when there is no exact hit (`[[` does not — verified,
`list(ch_ff04="A")[["ch_ff"]]` is `NULL`, so the `[[scenario]]` indexing at :115-116 is safe from
prefix collisions, and focus item 3 is a non-issue).

```r
list(floodplain_sections = "X")$floodplain   # -> "X"
```

The schema-reading path uses `$` throughout: `got$schema_version`, `prov$network`,
`prov$floodplain`, `prov$landcover`, `s$inputs$species`. The failure needs a specific upstream
rename (e.g. `landcover` -> `landcover_v2` with no exact `landcover` remaining), and most such
renames land on a `stop()` a step later when a leaf is missing — so this is latent rather than
live, and I could not construct a case in the documented upstream shape that silently binds the
wrong section *and* survives the leaf checks.

Flagging it only because it is the same class as finding 1 and sits in the same file: this reader
is the single point at which an upstream rename is supposed to become loud, and `$` is a
mechanism that can quietly resolve one. `[[` throughout would remove the class for the cost of
five characters.

---

## Checked and clean

Not defects — recording them so a later round does not re-derive them.

- **`stopifnot` / `PROV_FIELDS` ordering (focus 2).** `01_stage.R` defines `PROV_FIELDS` at :52
  and sources the reader at :66, so the assertion has its operand. Sourced without it, the failure
  is `object 'PROV_FIELDS' not found` — loud, at source time, before any staging. Correct
  direction. Note the file header claims it is also sourced by `fp_provenance-check.R`, which does
  not exist in `scripts/`; that is a doc-vs-tree gap, not a runtime one.
- **`has_prov` type safety (focus 4).** `length(v) == 1L && is.na(v)` short-circuits, so `is.na()`
  is never reached with a length != 1 value and `&&` cannot hit the R >= 4.3 length-1 error.
  `fp_prov_item` normalises every element to a scalar or `NA` first. `meta[PROV_FIELDS]` uses `[`,
  which yields a `NULL`-valued element rather than erroring on a missing name, and `length(NULL)
  == 1L` is `FALSE`, so it counts as present rather than crashing. No collision between
  `PROV_FIELDS` and the existing `meta` names (checked all 17).
- **`meta[f]` vs `.get` (focus 5).** Deliberate and consistent in both `03_cog_tag.py:69,71` and
  `05_stac_register.py:216` — a missing key is a staging bug and raises. The `""` encoding and the
  `MANAGED_KEYS` skip comparison interact correctly for the provenance half: `want` normalises
  `""` to `None`, which is what a read returns for a deleted key, so a null field matches on the
  second run instead of re-tagging forever. Confirmed `tags` ⊆ `MANAGED_KEYS`, so no written key
  escapes the comparison.
- **`item_validate.py:74` set equality + `seen == 0` guard.** Absolute rather than comparative, so
  it survives a uniform defect — the #23 hole. The `seen == 0` branch is unreachable from `main()`
  (which already enforces `expected >= 1` and `items == expected` earlier), but it is correct
  defensive code for a direct call and costs nothing.
- **`fp_prov_sections` multi-match guard.** `Filter` + `length(net) > 1L` -> `stop()` is right;
  it refuses to guess rather than silently taking the first. MORR's two-target case is the reason
  it exists and it handles it.
- **Target species selection.** `01_stage.R:305` passes `tgt$species`, not `area$species`. Given
  MORR declares a top-level `species: co` plus co and ch targets, the area-level read would have
  attached coho's network provenance to the chinook item with both values valid strings. Correct
  as written, and the comment explaining it is accurate.
- **`na = "null"` + `null = "null"`.** Both confirmed necessary and both set. `NA` -> `"NA"` and
  `NULL` -> `{}` without them; `{}` additionally passes Python's `is not None`, which would have
  defeated `provenance_tags()`'s null detection at `03_cog_tag.py:69`.
- **GDAL colon collapse.** Reproduced: `{"NGE:X": "abc"}` round-trips as `{'NGE': 'X=abc'}`. The
  `NGE_` prefix choice is correct and the comment's account of the failure is accurate.
- **`pystac` null preservation**, per the brief. Not re-derived.

---

## Suggested order

1. Finding 1 — one clause, silent failure, defeats the feature's stated purpose.
2. Finding 4 — cheap, and it is the guard hole most likely to be exercised next (a twelfth field).
3. Finding 2 — worth settling as an explicit contract with floodplains#33 before it emits files.
4. Findings 3 and 5 — latent; fix if the files are open anyway.
