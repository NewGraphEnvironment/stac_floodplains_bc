# #34 + #35 — class labels in the published COGs and in STAC

## Outcome

Published rasters carried class codes with nothing saying what they mean. Both issues
assumed labels could be written beside the colour table already in the COGs; measurement
showed that mechanism does not exist. **GDAL never embeds category names in a GeoTIFF** —
`SetCategoryNames` always writes a `.aux.xml` PAM sidecar, on every version tested up to
3.13. Only a Raster Attribute Table embeds, and only from **GDAL 3.12**, which added
RAT-in-`GDAL_METADATA`. That also ruled out publishing a sidecar: geoserv's titiler sets
`CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif,.TIF,.tiff"` and `catalogue_release.sh` already
excluded them, so a sidecar would have been invisible to this collection's own server.

The resolution was to use the sidecar as an **intermediate**: `02_raster_tag.py` hand-writes
PAM XML (stdlib only — the GDAL Python bindings have no wheel, so `osgeo` would have
reopened the conda->uv blocker this repo cleared) beside the *staged* raster, and the COG
conversion absorbs it into the published `.tif`. That forced the one architectural change,
`03_cog.R` -> `03_cog.py`: terra links GDAL 3.8.5 and would have pushed the RAT back out to
a sidecar. `rasterio.shutil.copy(driver="COG")` — a `CreateCopy` on the uv env's 3.12.1 —
carries it; `rio_cogeo.cog_translate` does not.

The same table is published as `classification:classes` on every raster asset, generated
from the same `data/raw/classes.json`, so the COG surface and the STAC surface cannot
disagree by construction.

## Measurement

- **Reachability, the whole point of the issue.** Labels read back over `/vsicurl` under
  geoserv titiler's own GDAL config (`GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR` +
  `.tif`-only): **9** RAT rows on a classified COG, **81** on the transition, against
  **0** for the live published catalogue.
- **No COG regression** vs the terra output replaced: `cog_validate` True, 256-entry colour
  table, band description, nodata, every dataset and band tag preserved, block 512x512,
  the same five overview levels, main IFD at **0.02%** of the file. Sizes 1.24 MB vs 1.13
  (classified) and 2.27 MB vs 2.38 (transition).
- **Transition raster, BULK:** 61 distinct codes, 8 no-change codes carrying **90.9%** of
  valid cells, values 1001-11011. (Issue #35 said 56 codes; it measured a different group.)
- **Release-gate memory:** 2.3 GB peak RSS for one raster -> **0.85 GB for all four**
  (0.34 GB under `GDAL_CACHEMAX=64`; the remainder is GDAL's own block cache, which sizes
  to a fraction of RAM rather than being a floor).
- **Overview threshold, measured not assumed:** the COG driver builds overviews iff
  `max(width, height) > BLOCKSIZE`. A 1x1024 raster's first overview is 1x512 — the width
  does not shrink — which is why the premise tests both dimensions.

### Traps found by measurement, both silent

- **GDAL's PAM parser ignores a `.aux.xml` carrying an `<?xml version...?>` declaration.**
  Same bytes otherwise: RAT read back without it, not read with it. `ElementTree` emits one
  **by default**, so the natural call is the broken one. Proven end to end — flipping the
  flag produces a clean build whose COGs carry no labels at all.
- **The STAC classification extension validates an item that declares it and carries ZERO
  `classification:classes`** — its Item branch "does not require them". So `pystac` is green
  on a total, uniform loss of the feature.

### Wrong turns, kept

- The claim that the XML declaration breaks PAM parsing was measured, then appeared to be
  **refuted** by an end-to-end test that passed with the declaration present, then
  re-confirmed. The confounder: `02`'s `r+` tag write, with a sidecar present, causes GDAL
  to embed the RAT into the *staged* raster, so a later declaration on the sidecar no longer
  mattered for that file. Settling it needed a raster with no pre-embedded RAT, then a flag
  flip in the code itself. (Useful side finding: a PAM sidecar takes precedence over an
  embedded RAT, so a stale embedded table cannot win.)
- The first `check_cog_rat` reported "no RAT" on COGs already measured as correct. The
  probe was wrong, not the data: GDAL nests the table inside
  `<Item name="DEFAULT_RASTER_ATTRIBUTE_TABLE" role="rat">`, not as a direct child of
  `<GDALMetadata>`.
- Two harness bugs cost a cycle each: `python3 -m http.server` does not support Range
  requests, so a `/vsicurl` test failed for reasons unrelated to the feature; and an `ls`
  colour alias leaked ANSI escapes into a path variable — the exact trap `code-check.md`
  documents.

## Review

Three `/code-check` rounds, **12 findings, all fixed**, each verified against a restored
defect. Round 2's headline was that **two of round 1's three fixes carried a new defect of
the same class they closed**. Round 3 named the mechanism rather than hunting instances:
every new premise had been written as *a literal reasoned from a producer's behaviour when
the artifact being validated answers the same question directly*. It then enumerated the
closed candidate set — contracts this repo chose (correctly hardcoded, since a derived
expectation cannot fire) versus facts about a third party (must be read from the artifact)
— and found exactly one remaining hit, `COG_BLOCK_SIZE`, now read from `ds.block_shapes`.
The enumeration terminating is what makes "this class is closed" a measurement.

A Plan review before implementation contributed the `transition_vector.gpkg` oracle, the
skip-branch ordering hazard in `02`, and the absolute row-count floors.

## Candidates for `soul/conventions/code-check.md`

Not added here — this repo's Code Check Conventions are synced from soul and an edit would
be overwritten:

1. A sidecar/config parser may silently ignore a file for a well-formed reason (an XML
   declaration), failing toward "absent" with no error.
2. A schema extension can validate a document carrying zero of the field the extension
   exists for — declaring it is not evidence it is populated.
3. The premise-regress mechanism above, and the contract-vs-third-party-fact discriminator
   that closes it.

Closed by: commits 3aca094, 504ee67 / PR (see branch
`34-35-embed-class-labels-rat-and-classification`)
