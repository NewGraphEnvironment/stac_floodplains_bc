# Ship the class palette with the GeoPackages (#46)

Closed by PR (branch `46-ship-the-class-palette-with-the-geopacka`), merged code only — **no
release**. #26 rebuilds every asset and one tagged release there carries this, #47 and the
rebuild together. A release cut here would have published a complete public catalogue of
geometry already known to be over-mapped.

## Outcome

The published rasters have been self-describing since #34/#35; the vectors were not, so every
consumer re-derived the palette from a COG or invented one. Now the three GeoPackages open in
QGIS already styled, from the same `data/raw/classes.json` that feeds the raster attribute
table and `classification:classes`, and the styles ship as STAC assets as well.

The drift was not hypothetical: the hand-exported reference style we started from carried
QGIS auto-ramp colours, not drift's. Trees to Water rendered green where io-lulc has it blue.

Six new or changed surfaces: a generator (`style_qml-write.py`), the three committed styles,
a staleness guard, an embedding step (`04_gpkg_style.py`, stdlib `sqlite3`, no new
dependency), a churn guard, and validation in `item_validate.py`.

## Measurement

`check_layer_styles` runs in **0.7 s over all 23 items**, so none of the guard work is a cost.

Embedding adds **+208 KB to `transition_vector.gpkg`, +5.5%** (3,878,912 → 4,091,904 bytes).

The palette conflict that is still an open design call: colouring transition patches by
destination class keeps the vector and raster views in agreement, but Trees→Rangeland is
**62% of tree loss in Kootenay Lake** and has a **contrast ratio of 1.32** against white.
Agreement and legibility point opposite ways here.

Three findings that changed the implementation rather than confirming it:

- The generator was **non-deterministic** — `uuid4()` ids meant every run emitted different
  bytes at identical length, which would have churned the published `file:checksum` on every
  rebuild. The drift check caught it on its first run.
- **SQLite bumps its header change counter on any write transaction**, so a re-run rewriting
  identical rows still moved the file. The writer compares first and skips.
- We deliberately write **less than QGIS does**: no `gpkg_contents` row and no triggers.
  QGIS auto-styles fine without them, and registering the table adds a second wall-clock
  stamp. GDAL lists `layer_styles` as a layer either way, so it bought nothing.

## The wrong turns, kept

**Two restore-the-bug proofs were false at first, and reading the message rather than the
exit code is what caught both.** Five mutations all exited 1 with no style message: mutating
a GeoPackage changes its bytes, so the checksum check fired first and short-circuited. The
proofs only mean anything with `item_create.py` re-run in between. A sixth silently mutated
nothing, because ElementTree escapes the arrow as `-&gt;` in the raw file.

**A single-species fixture could not reach the layer-mapping failure mode.** KOTL has 8
styled layers; MORR has 24 and three layer shapes KOTL lacks (`_patches`,
`_by_blue_line_key`, `_by_gnis_name`). MORR is also the first tree with more than one item,
which is what makes the cross-item asset-key check able to discriminate at all.

**Two reviewers found 20 findings, including a blocker neither the author nor the tests saw.**
`if not cats: continue` turned "I could not read a palette here" into "this is fine", so a
`nullSymbol` renderer — a real QGIS renderer that draws nothing — skipped every content
check. One reviewer also found a **false refusal**: the renders-blank arm asserted a data
property (that a watershed had tree loss) and would have blocked a correct release, with a
measured margin of 3 across the 48 staged transition layers.

**11 guard arms restored and confirmed to fire**, plus the false-refusal case confirmed
accepted and its genuine counterpart still refused.

## Evidence

- `planning/archive/2026-09-issue-46-geopackage-layer-styles/{task_plan,findings,progress}.md`
- Verified against QGIS 4.2.1 through PyQGIS throughout — the real consumer, opened plain,
  never a round-trip through our own writer.
