# Code check — round 1: class labels (RAT + `classification:classes`)

Staged diff: `scripts/05_stac_register.py`, `scripts/item_validate.py`
(plus doc-only edits to `CLAUDE.md`, `README.md`, `scripts/README.md`).
Reviewed against `CLAUDE.md` "Code Check Conventions" in full.

Everything below was measured on the one staged item present
(`data/raw/bulk_co_ff04`, 11552 x 14651), not reasoned about.

---

## Controls run first (so a clean result means something)

| control | result |
|---|---|
| `_read_embedded_rat` on a real `CreateCopy` COG | RAT found, 81 rows, usages `['5','2','6','7','8','9']`, row0 `['1001','Water (no change)','217','217','217','255']` |
| full `check_cog_rat` + `check_transition_codes` against a synthetic item carrying `CLASSIFIED_CLASSES` / `TRANSITION_CLASSES` | **CLEAN** — arrow labels (`U+2192`) round-trip through the embedded RAT and compare equal to the item's `title` |
| overview resampling defect restored (`OVERVIEW_RESAMPLING=AVERAGE`) | guard **fires**: 7858 invented values vs 61 base values |
| RAT stripped (COG built from a raster that never had one) | guard **fires**: "no raster attribute table embedded in the COG" |
| empty `--base` | guard **fires**: "no COG assets compared" |
| `pystac` validate of an item carrying both class sets against the live v2.0.0 schema | **passes** — `name` slugs, integer `value`, uppercase `color_hint` all accepted |
| does any read in `item_validate.py` (`ds.tags()`, `cog_validate`, full `read`, `statistics`) leave a PAM sidecar that would false-trip the sidecar check? | **no** — sidecar absent after every one |

So the guards work, and the alarm can fire. The findings below are gaps in what
they cover, not breakage in what they do.

---

## Findings

### 1. **[fragile]** `scripts/item_validate.py:333-353` — the RAT/item comparison covers labels only, never colours

`want` is built as `{value: title}` and `got` as `{cells[0]: cells[1]}`. `cells[2:5]`
(the RAT's Red/Green/Blue) and the item's `color_hint` are never compared.

That is exactly the half that can genuinely drift. Every colour on both surfaces
derives from `classes.json` **except one**: `NO_CHANGE_RGB = (217, 217, 217)` in
`02_raster_tag.py:53` and the string `"D9D9D9"` in `05_stac_register.py:145`. The
accepted tradeoff is that this literal is duplicated by design — fine — but the
guard that is documented as making the duplication safe does not reach it.

Both docstrings claim otherwise:

- `05_stac_register.py:128-131` — *"Mirrors the RAT ... row for row and **colour for
  colour** ... item_validate.py checks the published bytes against the published JSON
  to prove it stayed that way."*
- `item_validate.py:273-274` — *"a RAT whose rows disagree with the
  `classification:classes` the same build published"*.

**Measured.** Built a transition COG whose RAT gives the no-change diagonal
`(255, 0, 255)` while the item publishes `color_hint: "D9D9D9"`, titles untouched:

```
RAT colour drifted (FF00FF vs item D9D9D9) -> check_cog_rat: CLEAN (guard did not fire)
```

Consequence is cartographic, not numeric — a QGIS render from the embedded RAT and a
web legend built from `classification:classes` would disagree, with every gate green.

CLAUDE.md class: *"A proxy assertion does not guard the thing it stands for"*, and
the `#33` corollary *"inserting a new party into a path silently narrows every partial
guard on it"*.

Fix is small — carry the triple through both sides:

```python
want = {int(c["value"]): (c["title"], c["color_hint"]) for c in classes}
...
got[int(cells[0])] = (cells[1], "".join(f"{int(x):02X}" for x in cells[2:5]))
```

Alternatively, if colour parity is deliberately out of scope, the two docstrings
should stop asserting it — a stated guarantee nothing checks is the failure mode
`#22` is already recorded for.

---

### 2. **[fragile]** `scripts/item_validate.py:362-413` — "every pixel value has a class" is transition-only, and the scope is a coincidence

`check_transition_codes` filters on `key.startswith("transition_")`, so the three
classified COGs per item never get either half of the check: no pixel value is
compared against the declared classes, and no overview is compared against the base
band.

The risk is the same one the function exists for. `01_stage.R:91` drops **code 0**
from drift's table (`classes[classes$code != 0, ]`), so `classes.json` describes
`{1,2,4,5,7,8,9,10,11}` and nothing else. A classified raster carrying code 0 as a
*value* — or any code a future drift adds — would ship with pixels the RAT and
`classification:classes` do not describe, and every gate stays green: the RAT still
has 9 rows, the titles still match, `cog_validate` still passes.

**Measured on today's data**, which is what makes the scope look correct:

```
classified_2017.tif values: [1, 2, 4, 5, 7, 8, 9, 10, 11]   # exactly the 9 declared
transition_2017_2023.tif:   61 of 81 declared codes present
```

That is a coincidence about the current upstream, not a property the guard checks —
CLAUDE.md, *"A guard's scope is usually a coincidence, and it will not announce
itself"*.

Note the overview half is partly covered by luck: `03_cog.py` applies one
`CREATION_OPTIONS` dict to both kinds, so a typo in `OVERVIEW_RESAMPLING` still trips
the transition check. The **undescribed-value** half has no such backstop.

Fix: drop the `transition_` filter and run the `declared` / `base_vals` comparison over
every COG asset (the classified assets already carry `classification:classes`, so
`declared` resolves for them unchanged). Rename accordingly.

---

### 3. **[fragile]** `scripts/item_validate.py:394` — the full-band read peaks at 2.3 GB RSS inside the release gate

```python
base_vals = set(np.unique(ds.read(1, masked=True).compressed()).tolist())
```

**Measured** on one transition COG (11552 x 14651, int32):

```
check_transition_codes on ONE transition COG: 1.2s, peak RSS 2.30 GB
```

169.2 M cells x 4 B = 677 MB for the band, +169 MB mask, +677 MB for `.compressed()`,
+677 MB for `np.unique`'s sort copy. It is freed between items so it does not compound
across the collection, but it is a hard floor for `catalogue_release.sh` step 1, which
gates every publish and is explicitly designed to be runnable "from a machine that does
not hold the source tree" — i.e. possibly a small one. A 2 GB runner OOMs here, and the
OOM lands after the whole build.

Worth noting because `02_raster_tag.py:160-161` declined to derive the RAT from observed
values partly on this cost ("would cost a full read of a ~677M-cell raster per item") —
the new check pays that cost anyway.

Exact same answer in ~constant memory:

```python
base_vals = set()
with rasterio.open(local) as ds:
    for _, win in ds.block_windows(1):
        base_vals |= set(np.unique(ds.read(1, window=win, masked=True).compressed()).tolist())
```

---

## Notes (not findings)

- `05_stac_register.py:76-78` — the `_slug` docstring says *"five of drift's ten class
  names carry a space while one carries a slash"*. Measured against the
  `classes.json` on disk: **9** classes, **3** with a space (`Flooded Vegetation`,
  `Built Area`, `Bare Ground`), 1 with a slash. The code is right; only the count in
  the rationale is off. Same for `item_validate.py:207`'s "9 land-cover classes" —
  that one is correct.
- `scripts/README.md`'s `item_validate.py` row was not extended with the new
  class-label checks while the `02`/`03` rows were. Cosmetic.
- `numpy` is imported in `check_transition_codes` but not declared in
  `pyproject.toml`; it arrives transitively via `rasterio`, which always requires it.
  Not a real exposure.

## Checked and clean

- Detect/explain predicate is the same on both new diffs (`changed` computed first,
  then gated) — the `#33` empty-message trap is avoided in both places.
- Zero-result guards present and correct on both new checks (`compared == 0`,
  `checked == 0`), matching the sibling checks.
- `_load_classes()` raises rather than defaulting, and runs **before** the first item
  JSON is written — a missing/empty `classes.json` cannot produce a mixture of
  labelled and unlabelled items.
- `EXPECTED_RAT_ROWS` is absolute, not derived from `classes.json` or the item, so a
  uniform emptying cannot make the comparison agree with itself.
- `_assert_unique_names` closes the `uniqueItems`-cannot-see-a-name-collision hole;
  slugs are injective for both sets (9 and 81, verified).
- `_read_embedded_rat` raises rather than returning `None` on BigTIFF / big-endian /
  wrong tag type, so an unparseable header cannot read as "no RAT".
- Transition value encoding `src*1000 + dst` is collision-free for codes <= 11, and the
  worked example in the new asset `description` (`2011 = Trees to Rangeland`) checks out.
- `key.startswith("transition")` cannot capture `transition_vector` — it is filtered by
  the `pystac.MediaType.COG` test first.
- `*.aux.xml` is still excluded from the S3 sync (`catalogue_release.sh:145`), and
  `03_cog.py` already asserts no sidecar is left beside the output.
