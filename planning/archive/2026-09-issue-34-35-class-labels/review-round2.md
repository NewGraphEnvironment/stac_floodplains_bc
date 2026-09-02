# Review — round 2 (#34/#35 class labels)

Scope: staged diff (`/tmp/cc_diff2.txt`) — `scripts/05_stac_register.py`,
`scripts/item_validate.py`, `scripts/test_pipeline.R`, plus the committed context
(`01_stage.R`, `02_raster_tag.py`, `03_cog.py`). Everything below was probed against the
real `data/stac/bulk_co_ff04` build rather than reasoned about.

Round-1's three fixes are correct as far as they go — the colour tuple comparison does
compare colours, `check_pixel_values` does open all four COGs (measured: 2.8 s, 0 problems),
and the blockwise reads are blockwise. **Two of the three fixes carry a new defect of the
same class they were fixing**, which is findings 1 and 2.

---

## Findings

### 1. **[bug]** `scripts/item_validate.py:429` — the overview guard has no premise, and fails toward pass

`check_pixel_values` asserts `ov_vals ⊆ base_vals` to prove overview resampling is NEAREST.
Its own docstring gives the reason: *"GDAL only WARNS on an unknown creation option, so
`OVERVIEW_RESAMPLING=NEAREST` in 03_cog.py can fall back to the CUBIC default silently; this
asserts the property rather than trusting the line."*

The assertion then rests on an **equally silent open option**, unverified. `OVERVIEW_LEVEL=0`
is a GTiff open option; GDAL warns and continues on an option it does not recognise, so if the
name ever changes, the driver changes, or the option is dropped, `rasterio.open(local,
OVERVIEW_LEVEL=0)` returns the **full-resolution dataset** — `ov_vals` becomes exactly
`base_vals`, `invented` is empty by construction, and the guard reports success having checked
nothing.

Measured on the real transition COG:

```
base            61 distinct values
OVERVIEW_LEVEL=0  59 distinct values      <- a real overview
OVERVIEW_LEVELL=0 61 distinct values      <- typo'd option: opens full res, no error
ov0 - base: []      bogus - base: []      <- both "pass"
```

Nothing distinguishes those two runs. This is the round-1 memory fix introducing the exact
failure mode the function was written to close, one axis over — and it is the direction that
does not announce itself.

Cheap fix, one line beside the open:

```python
with rasterio.open(local, OVERVIEW_LEVEL=0) as ov:
    if ov.width >= ds_width:          # ds_width captured from the base open
        problems.append(f"{item_id}/{local.name}: OVERVIEW_LEVEL=0 did not select an "
                        f"overview ({ov.width} vs base {ds_width}) — the resampling "
                        f"contract was not checked")
```

Restore the defect to confirm: swap the keyword to `OVERVIEW_LEVELL` and the guard must go red.

---

### 2. **[bug]** `scripts/test_pipeline.R:280` — the empty-oracle guard is dead code, and the empty case reports the wrong cause

```r
upstream_pairs <- unique(paste(tr$from_class, "->", tr$to_class))
...
if (!length(upstream_pairs)) {
  stop("transition_vector.gpkg has no rows, so the label decode was not actually checked")
}
```

`paste()` recycles a zero-length argument to `""` when any other argument is non-zero-length —
the rule already in `CLAUDE.md` under *"`paste0()` treats a zero-length argument as `\"\"`"*.
Measured:

```r
z <- character(0); length(paste(z, "->", z))   # 1
paste(z, "->", z)                              # " -> "
paste(NULL, "->", NULL)                        # " -> "
```

So `upstream_pairs` is **never** length 0, and the guard added specifically to close the
vacuous-setdiff hole **cannot fire**. It is decoration.

What actually happens on an empty layer (or a `transition_vector.gpkg` that lost its
`from_class`/`to_class` columns — `tr$from_class` is then `NULL`, same result): `upstream_pairs`
is `" -> "`, `trimws()` gives `"->"`, which is not in `ours_pairs`, so the **first** stop fires:

> transition labels disagree with transition_vector.gpkg — upstream reports 1 pair(s) the
> published classes do not name: ->. The from\*1000+to decode may no longer match drift's encoding.

The failure direction is safe (it does fail) but the message points at drift's encoding when
the real fault is an empty or malformed oracle — a detect/explain mismatch that sends the reader
upstream to a package that is fine.

Fix: guard the oracle's shape before deriving anything from it, so both the emptiness and the
missing-column cases are named:

```r
stopifnot("transition_vector.gpkg lost from_class/to_class" =
            all(c("from_class", "to_class") %in% names(tr)))
if (!nrow(tr)) stop("transition_vector.gpkg has no rows, so the label decode was not checked")
upstream_pairs <- unique(paste(tr$from_class, "->", tr$to_class))
```

---

### 3. **[fragile]** `scripts/item_validate.py:348-351` — the RAT row parse crashes on exactly the tables the surrounding checks detect

The field-usage check appends a problem but does **not** `continue`:

```python
usages = [f.findtext("Usage") for f in rat.findall("FieldDefn")]
if usages != ["5", "2", "6", "7", "8", "9"]:
    problems.append(...)          # <- no continue
...
for row in rows:
    cells = [f.text for f in row.findall("F")]
    got[int(cells[0])] = (cells[1], "".join(f"{int(x):02X}" for x in cells[2:5]))
```

The positional indexing (`cells[0]` = value, `cells[1]` = name, `cells[2:5]` = RGB) is only
valid *because* the usage order is what `02_raster_tag.py` wrote. A RAT with a different
layout — a future GDAL schema, or an upstream raster that already carried its own table, which
is precisely what this guard exists to catch — reaches those `int()` calls. The `try/except`
above covers `_read_embedded_rat` only, so these escape:

| malformed row | result |
|---|---|
| 2 cells | silently yields colour `''` (mismatch reported — fine) |
| empty `<F/>` | **TypeError**, uncaught |
| non-numeric value | **ValueError**, uncaught |
| zero cells | **IndexError**, uncaught |

All four measured. The release gate then dies with a traceback and **discards the problem list
already accumulated**, including the usage-mismatch message that would have named the real
cause. Either `continue` after the usage failure, or extend the existing `except` to wrap the
row parse and report it as a problem.

---

### 4. **[fragile]** `scripts/item_validate.py:346` — `title`/`color_hint` are required by the guard but optional in the extension

```python
want = {int(c["value"]): (c["title"], c["color_hint"].upper()) for c in classes}
```

`value` is the only required field of a classification Class Object; `title` and `color_hint`
are optional. `05_stac_register.py` always writes both today, so this is unreachable from the
current producer — but `item_validate.py` validates *the JSON on disk*, which is the thing it
exists to distrust. A class entry missing either raises an uncaught `KeyError` (measured)
instead of being reported as a problem. Same crash-instead-of-report direction as finding 3;
`c.get("title")` / `(c.get("color_hint") or "").upper()` turns it into a reported mismatch.

---

### 5. **[fragile]** `scripts/item_validate.py:433` — "no overviews" is an unconditional release blocker

```python
else:
    problems.append(f"... COG has no overviews, so the resampling contract could not be checked")
```

`check_pixel_values` returning non-empty is a hard `return 1` from `main()`, so a COG the GDAL
COG driver legitimately built **without** overviews (anything under the 512 px block size)
blocks the release with no override, after the whole build has already succeeded — the
fail-toward-abort side of the guard rule. Today's rasters are 11552×14651 so it cannot fire,
which is a fact about the current watershed groups rather than a checked property. Either state
that dependency, or make the no-overview case conditional on the raster being large enough to
have warranted them.

---

### 6. **[fragile]** `scripts/test_pipeline.R:256` — `item_json` is rebound from a path to the parsed document mid-loop

Line 90 binds `item_json` to a **file path**, used at lines 98/112/176/178/186/190/197. Line 256
rebinds the same name to the **parsed list**. Nothing is broken today — every path use precedes
the rebind, and line 90 resets it each iteration. But the end of this loop is exactly where new
checks get appended (this diff appended 45 lines there), and the next one that writes
`basename(item_json)` or `file.exists(item_json)` will silently get a list. Use a second name
(`item_doc`), or reuse the parse already done at line 176.

---

## Checked and clean

- **Detect/explain predicate** — `check_cog_rat`'s `changed` is computed first and gated on,
  matching the round-1 fix in `check_cog_tags`. No empty-message path.
- **Empty-result guards** — `compared == 0` / `checked == 0` present in both new functions and
  reachable.
- **Round-2 scope fix** — removing the `transition_` key filter is safe: the media-type filter
  (`pystac.MediaType.COG`) keeps the three GeoPackage assets out, and `transition_vector` — the
  key that *does* collide on a `startswith` — is a GPKG. `kind` in `check_cog_rat` uses the same
  `startswith` but is likewise reached only for COGs.
- **Absolute expectations** — `EXPECTED_RAT_ROWS = {9, 81}` is hardcoded rather than derived, and
  `01_stage.R:100` pins the same 9 codes as an absolute set. A uniform class-table loss fires on
  both sides.
- **Colour comparison (round-1 fix 1)** — verified against the real RAT: rows parse as
  `['1','Water','65','155','223','255']`, reassemble to `419BDF`, and match the item's
  `color_hint`. Alpha is unpaired on the STAC side and correctly not compared.
- **`_slug` collisions** — guarded by `_assert_unique_names` on both class sets.
- **`_read_embedded_rat`** — raises rather than returning `None` on BigTIFF / big-endian / inline
  short values, so an unparseable header cannot read as "no RAT". Confirmed it finds the RAT in
  the published bytes (9 rows classified, usages `['5','2','6','7','8','9']`).
- **Script rename** — every reference to `03_cog.R` is updated (`run_pipeline.sh:40`,
  `test_pipeline.R:48`, both READMEs, `CLAUDE.md`); the only survivors are archived planning
  files, which are history.
- **`classes.json` placement** — at `data/raw/classes.json`, outside the `*/meta.json` glob and
  outside `$STAC_DIR/*.json`, so it cannot register as a phantom item.
- **`write_json(auto_unbox = TRUE)`** in `01_stage.R:111` — confirmed scalars, so
  `src["code"] * 1000` is arithmetic and not list repetition.

## Not re-flagged (accepted tradeoffs)

Uniform 81-row RAT; `NO_CHANGE_RGB` / `"D9D9D9"` duplication; network schema fetches during
pystac validation; numpy via rasterio; 0.85 GB peak RSS.
