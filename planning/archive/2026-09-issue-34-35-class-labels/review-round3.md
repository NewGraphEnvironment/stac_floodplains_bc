# Review — round 3 (#34/#35 class labels): the fixes, and the mechanism

Scope as briefed: (a) review round 2's six fixes as new code, (b) name the mechanism,
(c) only then sweep for remaining instances. Everything below was measured against the
real `data/stac/bulk_co_ff04` build or against COGs built with the same
`03_cog.py` creation options — nothing here is reasoned about.

**First, a state note that changes how to read this file.** `git status` reports
`MM scripts/item_validate.py` — there are **unstaged edits on top of the staged diff**,
made while this review was running. The staged blob carries `elif base_width > 512`;
the working tree carries `elif max(base_width, base_height) > COG_BLOCK_SIZE`. So
finding 1 below is real in the thing under review and **already repaired in the tree**;
finding 2 is a defect *in that repair*. Both are reported, because the commit is what
ships and it is currently the staged blob.

---

## Controls run first (so a clean result means something)

| control | result |
|---|---|
| `uv run python scripts/item_validate.py` on the real build | **green** — 1 item + 1 collection, provenance, cog layout, 9/81 class labels, every pixel value described (12.9 s) |
| GDAL COG overview threshold, measured across 8 shapes | overviews built iff `max(w, h) > BLOCKSIZE`; `512x512 -> none`, `513x400 -> [2]`, `400x513 -> [2]`, `64x1024 -> [2]` |
| same, with `BLOCKSIZE` overridden | 256: `300x300 -> [2]`; 1024: `600x600 -> []`. The threshold **is** the block size, not the constant 512 |
| pystac rejects a class missing `value` / with a string `value` | **both rejected** — so `check_pixel_values`' bare `int(c["value"])` is protected by main()'s validate-first ordering. Not a round-2-finding-4 recurrence |
| `test_pipeline.R` label oracle, three defects restored | multiplier 1000->100: **fires** (1 unexplained); titles rotated one place against values: **fires** (5); a class renamed in `classes.json` only: **fires** (14). Control passes with 0 |

---

## Findings

### 1. **[bug]** `scripts/item_validate.py:473` (staged) — round 2 fix 5's threshold is width-only, and it fails toward pass

```python
elif base_width > 512:
```

The property being stood in for is *"the driver would have built overviews here, so
their absence means the resampling contract went unchecked."* Measured, that property is
`max(width, height) > blocksize` — **either** dimension. Testing the width alone leaves a
tall narrow raster silently exempt from the guard, which is the direction that does not
announce itself.

Restored the defect the guard exists to catch (a COG built with `OVERVIEWS=NONE`):

```
400x4000, overviews stripped:
  staged   -> CLEAN                       <-- guard did NOT fire
  worktree -> "400x4000 COG has no overviews, so the resampling contract
               could not be checked"
4000x400, overviews stripped (control, other axis):
  staged   -> fires
```

CLAUDE.md class: *"A guard's scope is usually a coincidence, and it will not announce
itself"* — the scope was pinned to the fact that today's rasters are 11552 px **wide**,
and the guard's own comment says it is about future groups rather than current ones, so
its whole reason for existing is the case it does not cover.

**Already fixed in the working tree.** The fix is correct and I confirmed the new premise
is tight in both directions: `ov.width >= base_width and ov.height >= base_height` fires
exactly when `OVERVIEW_LEVEL` was ignored (identical dataset) and does not fire on the
`1x1024 -> 1x512` false-alarm case that a width-only premise would have aborted on
(measured — `1x2000` has `ov0 = 1x1000`, width unchanged, height halved). **Make sure that
hunk is staged before committing.**

---

### 2. **[fragile]** `scripts/item_validate.py:212` (working tree) — `COG_BLOCK_SIZE = 512` is a third party's default hardcoded, and the artifact answers it for free

```python
# The COG driver's default block size, and therefore the size above which it builds
# overviews. 03_cog.py does not override BLOCKSIZE, so this is the value in force.
COG_BLOCK_SIZE = 512
```

The comment states the premise instead of checking it. `03_cog.py`'s `CREATION_OPTIONS`
is a dict that already grew `BIGTIFF` *"so the choice is a decision rather than a
default"*, so a future `BLOCKSIZE` entry is the obvious next edit — and nothing ties the
two files together.

Measured, adding `BLOCKSIZE=1024` to `03_cog.py` and leaving `COG_BLOCK_SIZE` at 512:

```
600x600 BLOCKSIZE=1024 -> overviews=[]   ds.block_shapes[0]=(1024, 1024)
check_pixel_values -> "600x600 COG has no overviews, so the resampling
                       contract could not be checked"
   -> the raster is CORRECT (the driver builds none at or under one block)
      but the release is blocked, after the whole build succeeded
```

The dataset already reports it. The value is one attribute away from the open that is
happening anyway, and cannot drift from the bytes being validated:

```python
has_overviews = bool(ds.overviews(1))
base_width, base_height = ds.width, ds.height
block_size = max(ds.block_shapes[0])          # (1024, 1024) above, (512, 512) today
...
elif max(base_width, base_height) > block_size:
```

CLAUDE.md: *"A new feature can silently invalidate an unrelated flag's stated
rationale"* — a comment explaining why a shortcut is safe is load-bearing, and its
premises expire.

---

### 3. **[fragile]** `scripts/item_validate.py:477` — the premise-failure `continue` swallows the check the function is named for

```python
if ov.width >= base_width and ov.height >= base_height:
    problems.append(... "it did not select an overview" ...)
    continue                      # <- skips `undescribed` for this asset
```

`base_vals` has already been computed at this point (the expensive blockwise read), and
`declared` is already in hand. The `continue` throws both away, so the asset's
**undescribed-pixel-value** report — the primary contract in this function's docstring,
*"Every pixel value PRESENT in a raster must have a class"* — is never produced.

Measured, on a raster carrying one pixel value (99) that no class describes:

```
premise holds   -> ['... 1 pixel value(s) have no class: [99] — the upstream
                    encoding may have changed']
option ignored  -> ['... OVERVIEW_LEVEL=0 returned 1000x1000 against a
                    1000x1000 base — it did not select an overview ...']
```

The release blocks either way, so this is fail-toward-abort rather than
fail-toward-pass — but the operator is sent to look at a GDAL open option and never
learns the published pixels are unlabelled. Same family as **round 2 finding 3** (*"the
gate dies and discards the problem list already accumulated"*), one instance over, and
it is inside the fix for round 2 finding 1.

Fix: set a flag instead of `continue`-ing, and gate only the `invented` comparison on it
(that one genuinely cannot be computed).

```python
ov_checked = True
...
    ov_checked = False          # in place of `continue`
...
if ov_checked:
    invented = sorted(ov_vals - base_vals)
```

---

## (b) The mechanism

Three rounds, three fixes, and each fix has introduced its own unverified premise one
level up:

| round | the guard | the premise it rested on | how it failed |
|---|---|---|---|
| 1 | overview values ⊆ base values | `OVERVIEW_LEVEL=0` selected an overview | a typo'd open option opens full res; guard compares a band to itself |
| 2 | that premise, asserted | `ov.width` is the dimension that shrinks | width-only; a tall narrow raster is exempt |
| 3 | "overviews were warranted" | `512` is the driver's threshold | it is the driver's *default BLOCKSIZE*, which `03_cog.py` may override |

That is a regress, not a run of bad luck, and it has a single generator:

**Every new premise is written as a literal derived from reasoning about a producer's
behaviour, when the object being validated can answer the same question directly.** The
file is otherwise disciplined about this — it opens the TIFF itself rather than asking
GDAL for a RAT, precisely because GDAL would answer from a sidecar. The same instinct is
not applied to the premises.

**The one change that closes the class** is a discriminator applied to every literal in
the file, not another instance fix. For each constant, ask:

> Is this a **contract this repo chose** — in which case hardcoding it is the whole
> point, because a derived expectation cannot fire — or a **fact about a third party's
> behaviour**, in which case it must be read from the artifact?

Applied across the diff, the candidate set is closed and small:

| literal | kind | verdict |
|---|---|---|
| `EXPECTED_RAT_ROWS = {9, 81}` | contract (9 classes, 9x9) | correctly absolute — its docstring already says so |
| `usages != ["5","2","6","7","8","9"]` | contract (`02_raster_tag.py`'s field order) | correctly absolute |
| `REQUIRED_NGE_PROPERTIES`, `SHARED_TAG_PROPERTIES` | contract | correctly absolute, and documented as such |
| `MULTIHASH_SHA256 "1220"`, `GDAL_METADATA_TAG 42112`, `typ != 2` | format spec | fixed by standard |
| **`COG_BLOCK_SIZE = 512`** | **GDAL's default** | **the one hit** — read `ds.block_shapes` |

One hit. That is what makes "this class is now closed" a measurement rather than a claim
— the enumeration terminates, and there is no level above `ds.block_shapes` for the
block size to be derived from.

---

## (c) Remaining instances — swept, none found

- **Round 2 fix 1** (premise on `OVERVIEW_LEVEL`) — the worktree form is tight in both
  directions (measured above). Finding 3 is about its `continue`, not its condition.
- **Round 2 fix 2** (`test_pipeline.R` oracle shape) — `stopifnot` on the columns and on
  `nrow(tr) > 0` both fire, and they run before `paste()` so the zero-length recycling
  cannot reach the comparison. The `paste()` result is no longer load-bearing.
- **Round 2 fix 3** (RAT row parse wrapped) — the `continue` there skips only the
  `got`/`want` comparison, which genuinely cannot be computed from rows that did not
  parse. The usage-mismatch problem it was written to preserve **is** still appended
  before it. Correct.
- **Round 2 fix 4** (`.get()` on `title`/`color_hint`) — the sibling site,
  `check_pixel_values`' `int(c["value"])`, is bare. Measured: pystac rejects both a
  missing `value` and a string `value` against the live v2.0.0 schema, and `main()`
  validates before it calls `check_pixel_values`, so the crash is unreachable. Not a
  recurrence.
- **Round 2 fix 6** (`item_doc`) — no remaining read of `item_json` after the rebind;
  the path binding at line 90 is reset each iteration.
- **`test_pipeline.R` label oracle** — I expected this to be a proxy (comparing a *set of
  pair names* rather than the numeric decode, since `transition_vector.gpkg`'s
  `transition` column is a string like `"Trees -> Water"` and carries no code). Measured
  instead of asserted: it fires on all three defects tried, including the multiplier
  change I predicted it would miss. The oracle is stronger than it reads. No finding.
- **`05_stac_register.py`** — `_load_classes` raises rather than defaulting and runs
  before the first write; `_assert_unique_names` covers the `A__B` slug-collision case
  (verified the collision would be caught, not merely improbable); `2011 = Trees to
  Rangeland` checks out against `classes.json` (Trees=2, Rangeland=11); `re` is imported;
  the `_slug` docstring's "three with a space, one with a slash" is correct for the 9
  classes on disk.

---

## Not re-flagged (accepted tradeoffs)

Uniform 81-row RAT; `NO_CHANGE_RGB` / `"D9D9D9"` duplication; network schema fetches
during pystac validation; numpy via rasterio; 0.85 GB peak RSS; the 9-class table
excluding drift's code 0.

## One non-finding worth a line

`_read_embedded_rat` matches `sample="0"` (band 1) and nothing asserts `ds.count == 1`.
A multi-band raster's RAT on band 2 would read as "no RAT" — fail toward report, which is
the safe direction, so this is a note rather than a finding.
