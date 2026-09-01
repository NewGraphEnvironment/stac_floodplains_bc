# Published COGs are not valid COGs (#33)

Every raster this collection had ever published failed `cog_validate`. `03_cog_tag.py` wrote
GDAL tags **in place** with `IGNORE_COG_LAYOUT_BREAK="YES"` *after* `02_cog.R` built the COG,
which moved the main IFD to the end of the file. Fixed by reordering the pipeline so the COG
writer lays out the final bytes:

```
01_stage.R  ->  02_raster_tag.py  ->  03_cog.R  ->  05_stac_register.py
```

## Measurement

| asset | size | main IFD at | must fetch to read the header |
|---|---|---|---|
| `classified_2017.tif` | 602,582 B | 595,868 | **98.9%** |
| `transition_2017_2023.tif` | 1,335,328 B | 1,330,104 | **99.6%** |

So the range-request advantage COG exists for was not reduced, it was gone — and the geoserv
stack runs titiler, which is the reason these are COGs rather than plain GeoTIFFs.

The fix costs nothing, because `terra::writeRaster(filetype = "COG")` carries every GDAL tag,
the 256-entry colour table and the band description through unchanged — measured before the
reorder was planned, and confirmed afterwards on BULK at ~8x UFRA's file sizes. Two runs
produce identical `file:checksum` values, so no published checksum churns.

## Why it survived

Nothing errored. Every `file:checksum` verified, because the hash was taken *after* the tag
write and described the broken-layout bytes faithfully. The files open correctly in QGIS. Only
the layout was wrong, and nothing in the repo looked at layout.

That is the general lesson: a property no guard measures is a property that can be absent for
the entire life of a collection while every other signal reads green.

## Independent confirmation, found by accident

`rasterio.open(published_cog, "r+")` now raises:

```
CPLE_AppDefinedError: File ... has C(loud) O(ptimized) G(eoTIFF) layout.
Updating it will generally result in losing part of the optimizations
```

GDAL raises that **only when the file has COG layout**. The same open succeeded before this
branch. So the refusal is a second signal, independent of `cog_validate`, that the fix worked —
and it doubles as a tripwire: if `floodplains` ever emits COGs upstream, the tag step fails
loudly rather than silently breaking them.

## What review added

A concurrent Plan-agent review returned six actionable items. The strongest: `check_cog_tags()`
filtered to `NGE_`, so the nine shared identity/metric tags had **no guard anywhere**. That
mattered little when the tag writer and reader were the same rasterio write — this reorder puts
terra between them, so "the tags survive `writeRaster`" became a claim nothing checked.

Widening the guard surfaced two bugs in the widening itself, both found by running it against
restored defects rather than reading it:

- the gate was exact (`got != want`) while the diff was numeric-tolerant, so `'-738.20'`
  against a property of `-738.2` entered the failure block and reported an **empty message**
- the message still named only `nge:` after the check had grown past it

## Evidence

`findings.md` — the measurements, the guard proofs, and the two self-inflicted bugs.
`review-*` findings are folded into `findings.md` rather than kept separately.

Guards proven against both answers:

| restored defect | result |
|---|---|
| the defect itself (pre-fix tree) | red on all 4 COGs, naming IFD offsets |
| `WSG` tampered | fails, naming tag and property |
| `NET_HA` deleted | fails |
| `NET_HA` `-738.20` vs `-738.2` | passes — numeric compare, no false fail |
| zero COGs / zero items | fails rather than iterating nothing |

## Carried forward

- **#34 and #35 write through the tag step this issue moved** — class labels and the transition
  raster's legibility. They were sequenced after deliberately.
- **The published catalogue is still broken.** This fixes the builder; every live COG keeps the
  bad layout until a republish. That rides #26's full rebuild, or #36 for a single-group pilot.
- `requires-python` moved `>=3.10` -> `>=3.11` for rio-cogeo. This repo is the uv pilot for the
  `stac_*_bc` family, so siblings copying the pattern inherit the floor.
