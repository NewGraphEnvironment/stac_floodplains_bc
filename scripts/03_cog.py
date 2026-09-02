"""03_cog.py — convert the staged rasters to Cloud-Optimized GeoTIFFs.

Reads `data/raw/<item_id>/*.tif` and writes `data/stac/<item_id>/*.tif` as COGs.

Runs AFTER 02_raster_tag.py, and that order is load-bearing (#33): this is the last step
to touch the published bytes, so the COG layout it writes is the layout that ships.

This step used to be `03_cog.R`, using terra. It is Python now for one measured reason
(#34/#35): the labels have to travel INSIDE the `.tif`, and only a Raster Attribute Table
can do that. GDAL 3.12 added RAT-in-`GDAL_METADATA`; terra links GDAL 3.8.5, which predates
it and pushes the RAT back out to a `.aux.xml` sidecar — a file `catalogue_release.sh`
excludes from the sync and geoserv's titiler could not fetch anyway
(`CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif,.TIF,.tiff"`). Category names are not an
alternative: GDAL cannot embed those in a GeoTIFF at all, on any version.

`rasterio.shutil.copy` is a GDAL `CreateCopy`, and the uv env's GDAL is 3.12.1 — so the
PAM sidecar 02 wrote beside the staged raster is ABSORBED into the output's own
`GDAL_METADATA` tag and no sidecar is left behind. `rio_cogeo.cog_translate` is not
equivalent and must not be substituted: it rebuilds the dataset band by band and DROPS the
RAT (measured). Nor can this be done with the GDAL Python bindings — they have no wheel
(`uv pip install gdal` -> "all versions of gdal have no usable wheels"), so reaching for
them would reopen the conda->uv blocker this repo cleared.

Measured against the terra output it replaces, on real assets: RAT embedded, no sidecar,
`cog_validate` True, 256-entry colour table preserved, band description preserved, nodata
preserved, every dataset tag (WSG/SCENARIO/NET_HA/NGE_*/YEAR) and band tag
(DATE_TIME/STATISTICS_*) identical, block 512x512, the same five overview levels, main IFD
at 0.02% of the file.

One thing the rewrite retires: terra's `.tif.aux.json` sidecars, which nothing published or
read.

Usage:
    uv run python scripts/03_cog.py
"""

import sys
from pathlib import Path

import rasterio
import rasterio.shutil

RAW_DIR = Path("data/raw")
STAC_DIR = Path("data/stac")

# Categorical rasters, so overviews resample NEAREST: averaging class codes invents values
# that were never observed, and on the transition raster an invented code decodes to a
# from->to pair that did not happen there. The RAT would then label it confidently.
#
# GDAL warns rather than errors on an unknown creation option, so a typo here fails toward
# the CUBIC default silently — item_validate.py asserts the overview values are a subset of
# the base values rather than trusting this line.
CREATION_OPTIONS = {
    "COMPRESS": "DEFLATE",
    "OVERVIEW_RESAMPLING": "NEAREST",
    # Outputs are 1-3 MB today, far under the 4 GB classic-TIFF ceiling. Named explicitly
    # so the choice is a decision rather than a default, and so a future larger raster
    # switches format deliberately.
    "BIGTIFF": "IF_SAFER",
}


def main() -> int:
    # `*.tif`, never `*.tif*` — the latter would match the `.tif.aux.xml` RAT sidecars 02
    # writes beside these rasters and try to convert them as if they were images.
    tifs = sorted(RAW_DIR.glob("*/*.tif"))
    # Zero rasters iterates nothing and reports "0 converted, 0 failed" — indistinguishable
    # from a clean run, and exit 0 would carry it into item_create.py. The R version this replaces had
    # this hole; 02_raster_tag.py already carries the correct idiom.
    if not tifs:
        print(f"FAILED: no staged rasters under {RAW_DIR}/*/*.tif — nothing to convert",
              file=sys.stderr)
        return 1
    print(f"{len(tifs)} staged rasters found")

    converted = 0
    failures: list[str] = []

    for src in tifs:
        dst = STAC_DIR / src.relative_to(RAW_DIR)
        # CreateCopy will not create the destination directory; terra's writeRaster did not
        # either, which is why the R version made it explicitly too.
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            rasterio.shutil.copy(src, dst, driver="COG", **CREATION_OPTIONS)
        except Exception as e:  # noqa: BLE001 — collect every failure, report once
            failures.append(f"{src}: {e}")
            continue
        # The whole point of this step is that the labels end up in the FILE. Assert it
        # here, next to the write, rather than only in the validator: a sidecar beside the
        # output means the RAT did not make it in, and the failure is otherwise invisible
        # because every local reader loads PAM transparently and sees a RAT either way.
        stray = Path(str(dst) + ".aux.xml")
        if stray.exists():
            failures.append(
                f"{dst}: CreateCopy left a PAM sidecar, so the RAT is NOT embedded in the "
                f"COG — GDAL is {rasterio.__gdal_version__}, and RAT-in-GDAL_METADATA "
                f"needs 3.12+")
        converted += 1

    print(f"{converted} converted, {len(failures)} failed")
    if failures:
        for msg in failures:
            print(f"  {msg}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
