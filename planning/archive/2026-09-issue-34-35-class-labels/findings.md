# Findings — Embed class labels in the published COGs (#34 + #35)

## The measurements that changed the design

Both issues assumed a mechanism that does not exist.

| measured | consequence |
|---|---|
| GDAL CANNOT embed category names in a GeoTIFF — `SetCategoryNames` always writes a `.aux.xml` PAM sidecar, even on GDAL 3.13 | #34's "SetCategoryNames ... with no external file to find" is not achievable |
| Only a RAT embeds, and only from GDAL 3.12+ (into the `GDAL_METADATA` tag) | a RAT is the vehicle for both issues |
| terra links GDAL 3.8.5 | terra cannot be the final writer — it pushes the RAT back to a sidecar |
| rasterio has no RAT/category API; `uv pip install gdal` -> "no usable wheels" | #35's Option A is blocked by the uv env |
| `rio-cogeo.cog_translate` DROPS the RAT; `rasterio.shutil.copy(driver="COG")` CARRIES it | the fix needs no new dependency |
| a PAM `.aux.xml` RAT can be hand-written as plain XML and GDAL reads it | authorable without osgeo |
| geoserv titiler sets `GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR` + `CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif,.TIF,.tiff"` | a published sidecar is invisible to our own server; embedding is the only option |

## Verified on the real BULK rasters (CreateCopy vs terra)

RAT embedded in the .tif, no sidecar left behind, `cog_validate` True, colour table (256
entries), band description, nodata, all dataset tags and band tags preserved, block
512x512, same 5 overview levels, main IFD at 0.02%. Sizes: classified 1.24MB vs 1.13,
transition 2.27MB vs 2.38.

Also: an `r+` tag write with a PAM sidecar present leaves the sidecar byte-identical.

## Traps found by measurement

- **GDAL's PAM parser silently ignores a `.aux.xml` carrying an `<?xml ...?>` declaration.**
  Same bytes otherwise: RAT read count 2 without it, 0 with it. `ET.write(encoding="utf-8")`
  emits one by DEFAULT, so the natural call is the broken one, and it fails invisibly.
  UTF-8 and XML escaping both survive into the embedded RAT once the declaration is gone.
- **The classification extension validates an item that declares the URL and carries ZERO
  `classification:classes`.** The Item branch "does not require them". So pystac is green on
  a total uniform loss of the feature — the absolute assertion must be hand-written.
- `classification:classes` v2.0.0 `name` is `^[0-9A-Za-z-_]+$`. Five of drift's ten class
  names contain a space and `Snow/Ice` contains a slash. Verified the pattern IS enforced.
- `color_hint` (UNDERSCORE in v2.0.0, not `color-hint`) is 6 hex chars with no leading `#`.

## Measured, not assumed

- BULK transition: 61 distinct codes, 8 no-change carrying 90.9% of valid cells, 1001-11011,
  nodata -2147483648. All values fit uint16. No code touches class 0.
- `OVERVIEW_RESAMPLING=NEAREST` DID take effect: 0 invented codes in overviews, for both the
  CreateCopy output and terra's current output. The risk is latent, so it gets a guard, not a fix.

## Independent oracle for the from->to decode

`transition_vector.gpkg`'s `transition` layer carries `transition` ("Trees -> Water"),
`from_class`, `to_class` — upstream-produced, so checking decoded raster labels against it
is non-circular. 53 distinct strings vs 53 changed codes in the raster.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `uv run` outside the repo root builds an ad-hoc env without numpy | run `uv run` from the project dir; pass absolute script paths |
| PAM sidecar written by `ET.write(encoding="utf-8")` silently ignored by GDAL | `xml_declaration=False` |
| `rasterio.errors.RasterioIOError: Dataset is closed` | read `ds.descriptions` inside the `with` block |
