# Findings — Published COGs are not valid COGs (#33)

## Measured at plan time, 2026-09-01

### Every published COG fails validation

```
classified_2017.tif       valid=False
  The offset of the main IFD should be < 300. It is 595868 instead
  This file used to have optimizations in its layout, but those have been,
    at least partly, invalidated by later changes
  The offset of the IFD for overview of index 0 is 2522, whereas it should be
    greater than the one of the main image, which is at byte 595868
transition_2017_2023.tif  valid=False
  The offset of the main IFD should be < 300. It is 1330104 instead
```

Against the file sizes, the cost is total rather than partial: 98.9% and 99.6% of each file must
be fetched before a client can read the header.

### terra preserves everything through the COG write

The fix hinges on this, so it was measured rather than assumed:

```
raw tagged        {'WSG': 'UFRA', 'NGE_LINK_RUN_UID': 'RUN1'} | colormap 256 entries
after terra       {'WSG': 'UFRA', 'NGE_LINK_RUN_UID': 'RUN1'}
colormap          256 entries
band description  ('class_name',)
valid COG         True
```

So tagging the staged raster and letting `terra::writeRaster(filetype = "COG")` lay out the
final bytes loses nothing and fixes the layout.

### Determinism holds on both writes

Two terra COG writes of identical input are byte-identical, and two identical rasterio
`update_tags` writes are byte-identical. Neither step churns `file:checksum`.

This mattered enough to check because the repo has already been bitten by exactly this class —
`OGR_CURRENT_DATE` and GeoPackage `last_change`.

### Why it survived

Nothing errored. Every `file:checksum` verified, because the hash is taken after the tag write
and describes the broken-layout bytes faithfully. The files open correctly in QGIS. Only the
layout was wrong, and nothing in the repo looked at layout — so the guard added in Phase 1 is
the first thing that can see it.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `Rscript -e '...' SP="$SP"` — the var was empty inside R | That form passes `SP=...` as a command-line ARG, not an env var. Use `SP="$SP" Rscript -e '...'`. |
