# Review round 1 — branch `74-move-the-nge-item-fields-to-standard-or` (base 844ba81)

Reviewer: code-review subagent. Checklist read in full (code-check.md mechanisms + -python/-r/-shell/-spatial).
Every claim below was reproduced against the tree or measured on this machine; what is measured says so.

**Evidence runs made during this review**

- `uv run python scripts/prov_fields-check.py` → 38 assertions, 0 failed.
- `bash scripts/catalogue_release-check.sh` → ALL PASS (cases 1–16).
- `pystac` validation of the real built `larl_bt_ff04.json`: item OK; extension-declared-with-no-`processing:`-field
  **refused**; `processing:` field with the extension absent **passes**; `processing:software: {}` **passes**.
  All three schema claims in the code comments hold.

**Side effect you need to know about:** I ran `Rscript scripts/test_pipeline.R`, which re-runs `01_stage.R`
and wipes `data/raw` + `data/stac` before staging. It halted at the `ALLOW_DRIFT_SKEW` gate
(`ufra_ch_ff04`: rasters from drift 0.8.0 vs installed drift 0.20.0), so your previous `larl_bt_ff04`
build is gone and `data/` now holds a partial UFRA stage with no item JSON. `data/` is gitignored and
rebuildable with `scripts/run_pipeline.sh`; sorry for the churn.

---

## Findings

### 1. [bug] `scripts/test_pipeline.R:150-200` — the staged→published "extra field" join was deleted, not replaced

The removed block derived the staged provenance set **from the data**:

```r
staged_prov <- setdiff(names(meta), meta_core)        # meta's own names, minus the non-provenance core
item_prov   <- sub("^nge:", "", grep("^nge:", names(props), value = TRUE))
if (!setequal(staged_prov, item_prov)) stop(...)
```

and its own comment named exactly what it existed for: *"a twelfth field added to 01 (and to
fp_provenance.R, which its stopifnot forces) would be staged into meta.json, published nowhere, and
leave every guard green."*

The replacement is one-directional. `prov_fields` (line 161-170) is a **literal**, and the only check
against `meta` is `setdiff(prov_fields, names(meta))` (line 179) — literal ⊆ meta. A thirteenth field
added to `01_stage.R`'s `PROV_FIELDS` and `fp_provenance.R`'s `FP_PROV_MAP` is now:

- staged into `meta.json` (01_stage writes it);
- **not** tagged into any COG (`02_raster_tag.py` has its own list);
- **not** published (`item_create.py` reads only its map);
- invisible to `meta_prov_missing`, `want_keys`/`item_keys`, and `want_entries`/`item_entries`.

Confirmed by grep: `meta_core` and any other use of `names(meta)` are gone from the file (only line 179
remains). And `prov_fields-check.py` does not close it — it joins `item_create.py` ↔ `item_validate.py`
↔ `02_raster_tag.py`, all three of which are publish-side; it never reads `01_stage.R`. The only
mechanical join left on the staging side is `fp_provenance.R:136`'s `stopifnot`, which compares two
staging-side copies to each other.

The comment at line 154-160 overstates what the new block does — *"what THIS one joins is the two
halves of the ferry: 01_stage.R's staged field names, and what item_create.py published from them"* —
it joins a **fourth literal copy** of those names to the published keys, not the staged names
themselves. (Checklist: "A guard's scope, escape hatches, and remedies"; "One fact derived twice".)

Smallest restoration: keep `meta_core` and assert
`setequal(setdiff(names(meta), meta_core), prov_fields)` alongside the new key checks. The false
failure that costs (a new *non*-provenance meta field) is the point — it forces a human to classify it.

### 2. [fragile] `scripts/catalogue_release.sh:341-342, 358-365` — the `--only` SHAPE arm refuses a per-item provenance **gain**, and misdiagnoses it

```python
shape  = [('-' + k) for k in keys(bucket...) if k not in keys(built...)]
shape += [('+' + k) for k in keys(built...)  if k not in keys(bucket...)]
```

Any non-empty `shape` exits 1 with *"A renamed or re-shaped provenance contract is a FULL-release
change."* The `-` direction is right (and is what the API cannot see). The `+` direction refuses the
normal forward-only state the rest of the branch is built on.

Concrete, reachable case: `CLAUDE.md` and `NEWS.md` both record that `kotl`/`larl`/`sloc` legitimately
lack `link_run_uid` because their upstream block predates link#262. When one of those is re-run and the
producer now supplies it, the build publishes `link:run_uid` and the bucket copy does not, so
`shape == ["+link:run_uid"]`, `lost == []`, and `--only kotl_bt_ff04` is refused — with a message
naming a contract rename that did not happen. That is precisely the #36 single-group pilot republish
the flag exists for, and the reason the arm gives ("republishing one item would leave every other live
item on the old contract") does not apply: the contract is unchanged, only this item's coverage, and
#74's own premise is that "presence varies per item by design."

Suggested narrowing: refuse on `-` keys only, or on `+` keys only when the prefix/shape (not the
membership) differs — e.g. compare the set of **prefixes and `processing:software` entry names** rather
than the full key set.

### 3. [fragile] `scripts/01_stage.R:70-74` — comment still asserts the pre-#74 published-null contract

```
# Absent provenance is the NORMAL state... Every field is
# published as an explicit JSON null rather than omitted — an absent property reads as
# "not implemented", a null one as "we looked and there was not one", and only the second
# is true.
```

This is now false and argues *against* the change the branch makes. It sits eight lines below the
comment block the diff did edit (lines 40-48), in the file that owns the staged names, so it is the
first thing the next reader hits. `item_create.py:475`, `item_validate.py:518` and `CLAUDE.md:125`
all carry the corrected version; this is the one copy that was missed.
(Checklist: "Documentation Staleness"; "Documents that share an ancestor corroborate nothing".)

### 4. [fragile] `scripts/prov_fields-check.py` is referenced by no documentation and run by nothing

Measured: `grep -c prov_fields-check` is 0 in both `CLAUDE.md` and `scripts/README.md`, and it appears
in no `*.sh`. Every sibling guard driver is documented in both places —
`year_sets-check.py` (1/2), `fp_provenance-check.R` (2/2), `stage_years-check.R` (1/3),
`catalogue_release-check.sh` (1/2). Not being wired into `run_pipeline.sh` is deliberate and stated in
the docstring, but that makes a human knowing it exists the **only** trigger, and a 429-line guard
driver nobody is told about is the one that rots first. One row in `scripts/README.md`'s check-script
table and one clause in `CLAUDE.md` beside its siblings.

### 5. [fragile] `scripts/prov_fields-check.py:401-407` — the "a tag missing from the COG" fixture does not remove the tag, and the comment states a false measured fact

```python
"tags_override": {"NGE_LANDCOVER_KEY": None}
# None drops the tag on write, so this is the "tag went missing" direction...
```

Measured on this repo's venv (rasterio writing a 1×1 GTiff, then reading `ds.tags()`):

```
update_tags(A='x', B=None, C='')  ->  {'A': 'x', 'B': 'None'}
```

`None` is written as the **literal string `"None"`**; it is `''` that GDAL drops. So the fixture
exercises the same value-differs branch as the preceding case ("a plain tag perturbed"), and the
genuinely-missing-tag direction — a COG lacking a tag the item publishes — is **not covered** by the
suite. The product code does handle it (`want` carries the key, `managed` includes it from `want`,
`got.get(k)` is `None` → `_same` false → reported), so this is a fixture that cannot reach the failure
mode it is named for, not a product bug. `tags_override` can only set values; it needs a delete
sentinel (or write `''`) to reach the real path.

Incidentally, the same measurement **confirms** `02_raster_tag.py`'s absence encoding (`""` → dropped
on read) and therefore `item_validate.check_cog_tags`' comment about it.

### 6. [fragile] `scripts/item_validate.py:533` — `PROV_CENSUS`'s comment names a source that does not produce 10 of its 12 numbers

> *Set from the numbers 01_stage.R and item_create.py print for the build being released…*

Measured: `01_stage.R` prints only `N of M staged item(s) carry run provenance` (item-level), and
`item_create.py` prints only `provenance block: N/M` (item-level) and
`link run traceable (link:run_uid): N/M`. Nothing anywhere prints a per-field count for the other ten
fields, and `main()`'s successful-run line prints `traced` plus the three per-section counts, not the
census. Following the comment literally gives 21 for all ten, which is right today only because the
item-level count and the per-field counts coincide in this build — i.e. the procedure is correct by
coincidence of the data. It fails safe (a partial loss makes the guard fire rather than pass), but
setting the literal for the next release currently means deliberately failing a release to read the
`set it to N` message. Either print the census on the success path, or say in the comment that the
census failure message is where the numbers come from.

### 7. [fragile] `scripts/item_validate.py:2033` vs `:2083` — a malformed `processing:software` is diagnosed by the wrong guard

`check_deprecated` now reads the version through `_software(props).get("flooded")` (line 352), and
`_software` returns `{}` for any non-dict. `check_deprecated` runs at line 2033; `check_processing_stamp`,
which is the guard that *names* a bad `processing:software` shape, runs at 2083 and `main()` returns
before reaching it. So an item (or a build) whose `processing:software` came out as a string or a list
fails with 21 copies of *"carries no flooded version, so nothing here can vouch that it was built on
flooded >= 0.5.0 … Rebuild it, or mark it"* — advice that sends the operator at the producer rather
than at the serialiser. Pre-#74 this state was unreachable (the value was a scalar property). Moving
`check_processing_stamp` above `check_deprecated` costs nothing: it is pure JSON, like the premise and
deprecation checks already hoisted above `check_checksums`' 670 MB re-read for the same reason.

---

## Checked and clean (so the next round need not re-derive it)

- **`check_cog_tags` bridging.** `bridged` holds the pair's two tag names out of the generic diff;
  the reassembly `"+".join(...)` is reached for every COG including when the entry is absent
  (`published is None and all(p is None)` is the only skip); the published value is never split.
  `NGE_PROVENANCE_NULL` is derived declared-minus-present, which is what keeps the arm alive now that
  no null properties exist — the mechanical port of the old `v is None` derivation would have compared
  `{}` against `{}` on every item, and the suite proves the new derivation fires on an all-absent item.
  `prov_present`'s per-entry expansion makes `present` agree with `02_raster_tag.py`'s
  `meta[f] is None` derivation, so the sorted null lists match on all three live populations.
- **`PROV_SECTIONS` is still meaningful.** It is keyed on staged names and fed through `prov_present`,
  which expands each software **entry** separately, so an item carrying only `flooded` counts in
  `floodplain` alone. It is printed, not asserted, and says so.
- **The declared-key / census / floor arms are all reachable and non-tautological**, and every
  `expect_problem` in `prov_fields-check.py` greps its own message — I checked that the needles are
  unique within the function under test (notably `"does not declare"` matches
  `check_field_prefixes`' second message and not its first, and `check_provenance` is called with
  `floor=None` wherever the census must not also fire).
- **`publish()` in `prov_fields-check.py` is not verification reading its own output.** It is pinned
  statically against `item_create.py`'s real `PROV_PROPERTIES`/`PROV_SOFTWARE` by `literal()` +
  `ast.literal_eval`, and I confirmed those three comparisons can fail (they are whole-dict equality,
  not containment). Its one divergence from the writer — it joins a half-present pair instead of
  raising — is unreachable from any fixture in the file (`without()` never splits a software entry).
- **Shell details in the `--only` preflight.** `IFS='|' read -r` keeps empty fields in position
  (verified: `"12|12||"` → `c=""`, `d=""`); the heredoc supplies the trailing newline so `read` exits 0
  under `set -e`; the `python3 -c "…"` double-quoted body contains no `$`, backtick, backslash or
  double quote other than the three intended interpolations; `mktemp -t only_bucket.XXXXXX` satisfies
  both BSD and GNU; there is exactly **one** `trap … EXIT` in the script, so nothing replaces anything,
  and it is registered after `mktemp` succeeds and before the first path that can exit.
- **`curl` failure vs empty result.** `-sf` makes HTTP errors non-zero and both reads branch on exit
  status, so a 403/404 on either is distinguishable. One residual: a bucket read that returns 200 with
  an empty or non-JSON body fails inside the *second* `python3`, so it is reported as
  *"Could not read the live item's provenance"* — the API's message for a bucket-side fault. Low
  consequence (it still refuses), noted rather than filed.
- **`catalogue_release-check.sh` case 16.** The shim's key rewrite does what the case claims
  (`link:run_uid`→`nge:run_uid`, `landcover:key`→`nge:key`, `datetime` untouched; the conditional
  expression's precedence is correct), and its branch guard `[ "${rel%.json}" != "$rel" ]` means asset
  reads (`.tif`, `.gpkg`) fall through to `cat` — so step 5's checksum probe cannot be corrupted by it.
  Harness runs green.
- **R traps in `test_pipeline.R`.** Probed on this machine: `NULL[["link"]]` is `NULL` (not an error),
  so `props[["processing:software"]][["link"]]` is safe when the key is absent;
  `setequal(character(0), NULL)` is `TRUE`; `jsonlite::read_json` (which defaults
  `simplifyVector = FALSE`) preserves the **name** of a JSON null while the element is `NULL`, which is
  what `staged_present` depends on, and `01_stage.R:444` passes `na = "null", null = "null"` so the
  NA→null→NULL chain holds. `list(x = if (FALSE) y)` keeps the element (unlike `c()`), so the
  `want`/`got` lists stay length 3 and `for (k in names(want))` covers all three. `$stac_extensions`
  has no partial-match sibling. `ls` does shadow `base::ls` at global scope but `ls(` is never called
  in the file.
- **No stale `nge:` reads anywhere in code.** `grep -rn "nge:" --include=*.{R,Rmd,py,sh}` outside
  `planning/` returns only prose and the two deliberate sites (the COG tag names and the preflight's
  dual-shape canonicaliser). `README.Rmd` and `scripts/readme_functions.R` reference no provenance
  field at all, so the landing page cannot have gone stale.
- **`PROV_CENSUS` / `PROVENANCE_FLOOR` arithmetic** is consistent with the stated populations
  (18 + 3 = 21 for eleven fields, 18 for `link_run_uid`, 2 of 23 unprovenanced and both in
  `EXPECTED_DEPRECATED`), and `item_create.py`'s coverage prints were correctly ported
  (`not (PROV_KEYS & set(props))`, `"link:run_uid" not in props`) now that nulls are omitted.
- **`item_create.py`'s conditional extension** is evaluated after `properties.update(prov)` and
  nothing adds a `processing:` key afterwards, so the biconditional every validator asserts is true
  by construction; the half-present `SystemExit` fires before any file is written (the preflight loop
  precedes the writes).

## Not flagged, deliberately

- `PROV_PREFIXES` being derived from `PROV_KEYS` means the declared-key arm's scope shrinks if a whole
  prefix is retired from the contract while `FIELD_PREFIXES` keeps it. Reachable only by a future
  edit that removes every key of a prefix; mentioning it here rather than as a finding.
- `software[entry] = "+".join(str(v) …)` stringifies a non-string version, where plain properties pass
  through raw. Only reachable if a producer publishes a numeric version; `test_pipeline.R`'s
  `identical()` comparison would catch it on the next run.
- `catalogue_release.sh:56-57`'s "the next full release sets 1" prose contradicts `PROVENANCE_FLOOR=21`
  two lines below. Pre-existing, outside this diff.
