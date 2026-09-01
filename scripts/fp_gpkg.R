# fp_gpkg.R — deterministic GeoPackage writing for the publish layer.
#
# Sourced by 01_stage.R (the only script here that WRITES a GeoPackage) and by
# gpkg_determinism-check.R, so the check exercises the same writer the pipeline
# uses rather than a reimplementation of it.
#
# WHY THE PIN
# GDAL stamps `gpkg_contents.last_change` with wall-clock time, so an unpinned
# write produces different bytes on every run from identical inputs. Since #22
# publishes `file:checksum` on every asset, that would make this one asset's
# checksum churn each rebuild while every other asset stayed stable — which reads
# as "checksums are unreliable" and whose actual cause is one unpinned writer.
# Measured here before it was fixed: two extracts of the same layer, 1.2 s apart,
# gave md5 5429357d… and c2bfa94b…; pinned, both gave ea0ac66f….
#
# Ported from floodplains#45 (`floodplains/scripts/fp_gpkg.R`). The fix does NOT
# travel with the file — it is a property of the process doing the writing — so it
# has to be applied in every repo that writes one.
#
# WHY AN ENVIRONMENT VARIABLE, not st_write(config_options=)
# GDAL reads its config from the environment, so one call covers every write in
# the process. Per-call options are silently incomplete the moment someone adds
# another write and forgets to pass them.
#
# SCOPE OF THE GUARANTEE
# A write into an ABSENT file is byte-reproducible. Rewriting a layer into an
# EXISTING gpkg is not — SQLite free-page state differs from a fresh insert and
# the pin cannot reach it (`VACUUM` does not close it either). gpkg_write_layer()
# therefore unlinks before writing; do not "optimise" that away.

suppressMessages(library(sf))

# Any fixed instant works; this is the one floodplains#45 verified.
GPKG_EPOCH <- "2000-01-01T00:00:00.000Z"

gpkg_pin_date <- function(quiet = TRUE) {
  Sys.setenv(OGR_CURRENT_DATE = GPKG_EPOCH)
  if (!quiet) message("GeoPackage timestamps pinned to ", GPKG_EPOCH, " (floodplains#45)")
  invisible(GPKG_EPOCH)
}

#' Write one sf object to a fresh single-layer GeoPackage.
#'
#' Unlinks first so the write lands in an absent file, which is the only case the
#' timestamp pin makes byte-reproducible.
gpkg_write_layer <- function(dat, dst, layer) {
  unlink(dst)
  sf::st_write(dat, dst, layer = layer, quiet = TRUE)
  invisible(dst)
}

#' Extract a single layer from a source GeoPackage into a fresh one.
#'
#' `dst_layer` is deliberately generic (`transition`), not the producer-keyed
#' source name. QGIS styles and .qlr files bind to `path|layername=`, so a name
#' carrying the species/scenario/year span would break every downstream style the
#' moment the model is re-run — and the span is expected to move (2017-2023 today,
#' 2017-2025 next, possibly 2010-2025 on satellite data). Identity is carried by
#' the item id and the layer's own wsg/species/scenario columns instead.
gpkg_extract_layer <- function(src, layer, dst, dst_layer) {
  # st_layers()$name returns clean names. Never match on `ogrinfo -so` output:
  # it appends the geometry type to most layer names but NOT to those declared
  # `Unknown (any)` — MORR's transition layer is exactly that case, so a
  # suffix-assuming regex misses one layer in the catalogue and no other.
  available <- sf::st_layers(src)$name
  if (!layer %in% available) {
    stop("layer '", layer, "' not in ", src, " (have: ",
         paste(available, collapse = ", "), ")")
  }
  gpkg_write_layer(sf::st_read(src, layer = layer, quiet = TRUE), dst, dst_layer)
}
