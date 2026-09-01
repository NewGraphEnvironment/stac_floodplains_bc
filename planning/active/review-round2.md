# Review — round 2 (#17, `17-publish-run-provenance-as-stac-item-prop`)

Scope: `git diff main...HEAD -- scripts/` plus the uncommitted round-1 fixes.
Focus per instruction: the round-1 **fixes**, not a fresh sweep.

All four findings were reproduced against the repo's own staged data
(`data/stac/morr_*`), with a positive control run first in every case so an empty
result could not be read as a pass.

Round-1 fixes re-verified as **correct and complete**: the `link_log` presence test,
the `$` → `[[` conversion, the `shared_tags()` `""` idiom, and `check_cog_tags()`'s
value-level reporting. Details under "Fixes verified sound" below.

---

## Findings

### 1. [bug] `scripts/fp_provenance.R:106` — round-1's rename defect, reproduced one level up

`fp_prov_sections()` selects the network block by reading `inputs$species` through a
`%||% ""` fallback inside a `Filter`:

```r
net <- Filter(function(s) identical(as.character(s[["inputs"]][["species"]] %||% ""), species),
              prov[["network"]] %||% list())
```

If the producer renames or drops `inputs` **inside a network section that is present**,
`s[["inputs"]]` is `NULL`, `NULL[["species"]]` is `NULL`, `%||% ""` makes it `""`, the
section fails the filter, `net` is empty, and `network` becomes `NULL`. Every downstream
`fp_prov_leaf()` call then takes its `is.null(section)` early return and publishes `NA`.

That is precisely the state this file's own contract forbids — *"section present, leaf
ABSENT -> stop()"* (fp_provenance.R:415–422) — and it is exactly the failure round 1
fixed at the leaf. Four fields go out as JSON null, indistinguishable from the normal
forward-only absence, including `nge:link_run_uid`, the one field
`05_stac_register.py:304` singles out as the run identifier.

Sharper still: the two-line comment immediately above (fp_provenance.R:104–105) states
that `[[` is used here so *"an upstream `inputs_v2` would silently satisfy `$inputs` — in
the one file whose job is making a rename loud."* The `[[` conversion stops the partial
match, and then `%||% ""` on the very next expression swallows the rename anyway. The
fix's stated purpose is not achieved on the line it was applied to.

Measured (`fp_prov_item(prov, "co", "co_ff04", ...)` on a synthetic v1 record):

| input | result |
|---|---|
| healthy | no nulls |
| `link_log` renamed (round-1 fix) | **STOP** — correct |
| `inputs` renamed to `inputs_v2` inside a present network section | **4 silent nulls** |
| network section's `species` value changes `co` -> `coho` | **4 silent nulls** |

Second, asymmetric half of the same guard: `length(net) > 1L` refuses to guess and stops,
but `length(net) == 0L` says nothing. Verified that a `network` block that is **present
and non-empty but matches nothing** is indistinguishable from one that is absent
altogether — both yield `network = NULL`. The first is a data/schema break; the second is
the legitimate absence the design allows. Guard fails toward "publish null".

Fix shape: read `inputs` and `species` through the same present-but-missing rule the rest
of the file uses rather than `%||% ""`, and stop when `prov[["network"]]` is non-empty yet
zero sections match. `%||%` is right for `prov[["network"]]` itself (a section may
legitimately be absent) and wrong for a key *inside* a section that is present.

Related, lower confidence, and arguably by design: renaming the `landcover` section key,
or a scenario key within it, also degrades silently to six nulls (measured). Unlike the
`inputs` case these are genuinely ambiguous with a legitimately-absent section — the
`schema_version` pin in `fp_prov_read()` is the named guard for them, and it only fires if
upstream bumps the version. Worth stating as an accepted residual rather than fixing.

---

### 2. [fragile] `scripts/item_validate.py:113` — `check_cog_tags()` filters on a duplicated media-type literal, with no non-vacuity counter

```python
if asset.get("type") != "image/tiff; application=geotiff; profile=cloud-optimized":
    continue
```

The string currently matches `pystac.MediaType.COG` (verified, pystac 1.15.1), so this is
not broken today. But `check_provenance()` two functions up carries a `seen == 0` guard
precisely because "nothing to check" and "everything checked out" are otherwise identical
output — and `check_cog_tags()` has no equivalent. If the filter ever matches nothing, the
function returns `[]` and `main()` prints `COG tags agree`: an affirmative claim of
success over zero comparisons.

Measured, with a **real defect present** (`NGE_LINK_SHA` tampered to `tampered-value`) and
the item's media type perturbed by one trailing space:

```
POSITIVE CONTROL (tag deleted, media type intact): FIRES
H1 media-type drift + real defect:                 *** SILENT PASS ***
```

Two one-line hardenings, both worth taking:

- Compare against `pystac.MediaType.COG` — `pystac` is already imported at
  item_validate.py:32, and 05_stac_register.py sets the media type from that same
  constant, so the two cannot drift.
- Count the `(asset, key)` comparisons actually made and append a problem when the count
  is zero, mirroring `check_provenance`'s `seen == 0`.

(The other two vacuity routes — no Feature JSON, and COGs absent from disk — are covered,
but only by `check_provenance` and `check_checksums` returning 1 earlier in `main()`. That
is an implicit ordering dependency; the counter makes it explicit.)

---

### 3. [fragile] `scripts/item_validate.py:120-121` — `NGE_PROVENANCE_NULL` is written but excluded from verification, and it is the only NGE_ tag present in the state the code calls normal

```python
got = {k: v for k, v in tags.items() if k.startswith("NGE_")
       and k != "NGE_PROVENANCE_NULL"}
```

`03_cog_tag.py:75` writes `NGE_PROVENANCE_NULL` as the comma-joined list of null fields —
the COG's whole "we looked and there was none" claim. Nothing reads it back. Per CLAUDE.md
*"A value nothing reads is wrong silently"*, and it is derivable from the item for free:
`",".join(sorted(k[len('nge:'):] for k, v in props.items() if k.startswith("nge:") and v is None))`.

This matters more than a normally-unread field, because it interacts with the state
01_stage.R:336-339 and 05_stac_register.py:294-296 both describe as today's expected
reading — **zero provenance coverage until floodplains#33 lands**. In that state every
`nge:` property is null, so `want` is `{}`; `03` writes `""` for all eleven NGE_ keys and
GDAL drops them, so the only NGE_ tag on the COG is `NGE_PROVENANCE_NULL` — which this
line excludes. `got` is `{}` too, and the comparison is `{} != {}` for every COG.

Measured — item properties all null, COGs correctly retagged, then
`NGE_PROVENANCE_NULL` overwritten with `THIS_IS_COMPLETE_GARBAGE`:

```
A: NGE_ tags now on COG: {'NGE_PROVENANCE_NULL': 'THIS_IS_COMPLETE_GARBAGE'}
A: garbage NGE_PROVENANCE_NULL under all-null props -> *** SILENT PASS ***
```

The check is non-vacuous today only because `data/stac` holds a fixture with all eleven
fields populated. On a real pre-#33 run it verifies nothing and still prints
`COG tags agree`. Including `NGE_PROVENANCE_NULL` in the comparison closes both the
unread-value gap and the vacuity, in one line.

---

### 4. [fragile] `scripts/03_cog_tag.py:72` / `item_validate.py:109` — a legitimate empty-string provenance value blocks the release with a misattributed message

`03` encodes null as `""` because GDAL drops an empty-string tag. A genuine `""` value
from upstream is therefore encoded identically to a null and vanishes from the COG, while
the item publishes `""` (not null), so `want` keeps the key and `got` does not.

Measured — `nge:link_sha` set to `""`, `03`'s exact write reproduced:

```
B: empty-string value, 03 wrote it faithfully -> FAILS(false alarm)
   morr_ch_ff06/classified_2017.tif: NGE_ tags disagree with the item's nge: properties
     — NGE_LINK_SHA: tag None vs property ''
```

Reachability is low (all eleven fields are hashes, versions, URLs and timestamps upstream)
and the direction is the safe one — it blocks a release rather than publishing silently.
The cost is that the message says "tags disagree", pointing at `03`, when the real cause is
that the encoding has no room for an empty string. Either treat `""` as null in
`fp_prov_leaf()` at the source, or have `check_cog_tags()` name the collision in its
message.

---

## Fixes verified sound (no action)

Each round-1 fix was re-derived rather than taken on trust.

1. **`fp_prov_leaf()` `link_log` presence test** — correct, and `i == 1L` is the right
   scope. No `FP_PROV_MAP` path carries `link_log` below depth 1, and the branch requires
   both `i == 1L` and `identical(key, "link_log")`, so no deeper nesting can take the
   exception. Re-confirmed the positive control: a renamed `link_log` still stops, a
   modelled null still yields three nulls. Also checked the branch is safe when `cur` is
   not a list (`names()` returns `NULL`, `%in%` is FALSE, falls through to the `stop()`).

2. **`shared_tags()` `""` idiom** — interacts correctly with `MANAGED_KEYS`. The skip
   comparison normalises both sides through `want = {k: (v if v != "" else None)}`, so a
   `None` shared field reads as `None` on both sides and matches. No interaction with
   `check_cog_tags()`, which only inspects `NGE_`-prefixed keys — no `SHARED_FIELDS` key
   carries that prefix.

   **No shared field can now be silently dropped where it previously errored.** The old
   comprehension's `if meta.get(f) is not None` clause was evaluated before the `meta[f]`
   lookup, so an absent key was already filtered out rather than raising `KeyError`. The
   change is a strict improvement: it moves the behaviour from "write nothing, stale tag
   survives an `update_tags()` merge" to "write `""`, stale tag deleted". Note the
   docstring's claim of parity with `provenance_tags()` holds for the encoding but not for
   the raise direction — `provenance_tags()` uses `meta[f]` and raises, `shared_tags()`
   uses `meta.get(f)` and does not. Behaviour is unchanged from before the fix, so not
   reported as a finding.

3. **`$` → `[[` conversion in `fp_provenance.R`** — complete. `grep -n '\$'` returns only
   comments and the `paste(path, collapse = "$")` message separators. No `$` remains on
   provenance-derived data in `01_stage.R` either; the single touchpoint (line 305) uses
   none, and `meta[PROV_FIELDS]` at line 322 is `[`, not `$`. (See finding 1 for why the
   conversion nonetheless does not achieve its stated goal on line 106.)

4. **`str(v)` stringification in `check_cog_tags()`** — no type can diverge. Both sides
   `str()` a value produced by `json.loads`, and the item's copy is that same Python object
   after a `json.dumps`/`json.loads` round trip, which preserves `int`, `float`, `bool` and
   `str` exactly. `fp_prov_leaf()` additionally enforces scalars (`length(cur) != 1L` →
   stop). The empty string is the only divergence, reported as finding 4.

5. **`c(meta, fp_prov_item(...))` name collision** — verified no overlap between the
   sixteen `meta` names and the eleven `PROV_FIELDS`, as the comment claims. Not guarded,
   but not currently reachable.

---

## Minor

- `scripts/fp_provenance.R:9` — the header states the reader is *"sourced by 01_stage.R
  alongside fp_gpkg.R, and by `fp_provenance-check.R`, so the check exercises this reader
  rather than a copy of it."* `scripts/fp_provenance-check.R` does not exist. The claim
  reads as an assurance that the reader is independently exercised; nothing does.
