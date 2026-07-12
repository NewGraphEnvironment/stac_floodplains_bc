# 02_cog.R — convert the staged rasters to Cloud-Optimized GeoTIFFs.
#
# Reads data/raw/<wsg>/*.tif and writes data/stac/<wsg>/*.tif as COGs.
# Classified + transition rasters are categorical, so overviews resample NEAREST
# to avoid inventing class values. Compression is DEFLATE (lossless).

library(terra)

raw_dir <- file.path("data", "raw")
stac_dir <- file.path("data", "stac")

tifs <- list.files(raw_dir, pattern = "\\.tif$", recursive = TRUE, full.names = TRUE)
message(length(tifs), " staged rasters found")

converted <- 0
failed <- 0

for (src in tifs) {
  rel <- sub(paste0("^", raw_dir, "/"), "", src)   # <wsg>/classified_2017.tif
  dst <- file.path(stac_dir, rel)
  dir.create(dirname(dst), recursive = TRUE, showWarnings = FALSE)

  ok <- tryCatch({
    r <- terra::rast(src)
    terra::writeRaster(
      r, dst, filetype = "COG",
      gdal = c("COMPRESS=DEFLATE", "OVERVIEW_RESAMPLING=NEAREST"),
      overwrite = TRUE
    )
    TRUE
  }, error = function(e) {
    warning("Failed: ", src, " — ", conditionMessage(e))
    FALSE
  })

  if (ok) converted <- converted + 1 else failed <- failed + 1
}

message(converted, " converted, ", failed, " failed")
if (failed) stop(failed, " raster(s) failed to convert")
