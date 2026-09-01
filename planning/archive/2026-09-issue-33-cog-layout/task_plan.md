# Task: Published COGs are not valid COGs (#33)

`03_cog_tag.py` writes GDAL tags **in place** with `IGNORE_COG_LAYOUT_BREAK="YES"`, and it runs
*after* `02_cog.R` has built the COG. That flag is an acknowledgement that the write invalidates
the layout. The main IFD moves to the end of the file:

| asset | size | main IFD at | must fetch before reading the header |
|---|---|---|---|
| `classified_2017.tif` | 602,582 B | 595,868 | **98.9%** |
| `transition_2017_2023.tif` | 1,335,328 B | 1,330,104 | **99.6%** |

So the one thing COG buys over a plain GeoTIFF is gone, and the geoserv stack runs titiler,
which is the reason these are COGs at all.

The failure direction is why it survived: nothing errored, every checksum verified, and the
files open fine in QGIS. Only the *layout* was wrong, and nothing in the repo looks at layout.

Blocks #34 and #35, which both write through the same tag step.

## Measured before planning

- `terra::writeRaster(filetype = "COG")` **preserves** arbitrary GDAL tags, the 256-entry
  colormap and the band description, and produces `cog_validate == True`.
- Two terra COG writes of identical input are **byte-identical** — no checksum churn.
- rasterio `update_tags` writes are byte-deterministic too.

## Phase 1: The guard first, red against the current tree

- [x] Add `rio-cogeo` to `pyproject.toml`; confirm it resolves over the existing rasterio
      rather than pulling its own GDAL — it does (deps are click/morecantile/pydantic/rasterio)
- [x] Bump `requires-python` to `>=3.11`; rio-cogeo 7 needs it and the `>=3.10` floor was
      aspirational — the venv is 3.12.13
- [x] `scripts/item_validate.py` — `check_cog_layout()` asserting `cog_validate()` passes,
      wired into `main()` beside `check_cog_tags()`
- [x] Confirm it **fails on the current tree**, naming the IFD offset — all 4 COGs red
- [x] Non-vacuity: count comparisons and fail on zero, matching the sibling checks

## Phase 2: Reorder

- [x] `git mv scripts/03_cog_tag.py scripts/02_raster_tag.py`; repoint the glob to `RAW_DIR`,
      drop `IGNORE_COG_LAYOUT_BREAK`; remove the now-orphaned `STAC_DIR`
- [x] `git mv scripts/02_cog.R scripts/03_cog.R` — header updated, logic unchanged
- [x] Reorder `scripts/run_pipeline.sh` and `scripts/test_pipeline.R`
- [x] Verify the skip-when-matching branch is still reachable — re-running the tag step
      alone reports `Tagged 0, skipped 4`, so it stays meaningful and stays
- [x] Guard from Phase 1 now passes: `cog layout: valid on every COG`

## Phase 3: Docs and comments that encode the old order

- [x] `scripts/README.md` step table
- [x] `CLAUDE.md` rebuild line
- [x] `05_stac_register.py` byte-finality comment — the COG write is now the last step
- [x] Sweep for other references: `README.md` (a duplicate Tag row the first edit created),
      `run_pipeline.sh` + `test_pipeline.R` headers and the PASS line, `item_validate.py`
      docstring. Everything left is in `planning/archive/`, which is history.

## Phase 4: End to end on BULK

- [x] `WSG=bulk Rscript scripts/test_pipeline.R` green
- [x] `cog_validate` passes on all four of BULK's COGs
- [x] Tags, colormap and band description present on the published COGs
- [x] Two consecutive runs produce identical `file:checksum` values
- [x] MORR (two targets, 8 rasters) green — the tag step now reads a different directory,
      and MORR is where item-keying bites

## Phase 5: Plan-review findings (folded in pre-PR)

- [x] Extend `check_cog_tags()` past `NGE_` to the shared identity/metric tags — terra is a
      new party in the tag path and nothing checked it
- [x] Fix two bugs in that fix: the gate used an exact compare while the diff used a
      numeric one (empty-message failure), and the message named only `nge:`
- [x] `cog_validate(quiet=True)` — it printed its own coloured report on top of ours
- [x] `--exclude '*.aux.xml'` in the release sync; assert zero after a build
- [x] Rewrite the stale `MANAGED_KEYS` rationale, wrong in every clause post-reorder
- [x] Document that the tag step alone no longer repairs `data/stac`
- [x] Document the `"r+"` tripwire, and name pyproj in the pyproject comment
- [x] Empty-glob guard in the tag step

## Validation

- [x] Guard red before, green after — run in both states
- [x] Smoke test on `ufra`, `bulk` and `morr`
- [ ] `/code-check` clean
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
