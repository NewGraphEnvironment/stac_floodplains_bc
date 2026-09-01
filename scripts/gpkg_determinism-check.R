# gpkg_determinism-check.R — prove the GeoPackage timestamp pin actually works.
#
# 01_stage.R extracts a transition layer into a fresh GeoPackage, and #22 publishes
# a `file:checksum` for it. If GDAL stamps a wall-clock time into that file, the
# checksum churns on every rebuild from identical inputs — provenance in name only.
# scripts/fp_gpkg.R pins OGR_CURRENT_DATE to stop that. This checks the pin holds.
#
#   Rscript scripts/gpkg_determinism-check.R                 # warm path: must MATCH
#   NO_PIN=1 Rscript scripts/gpkg_determinism-check.R        # cold path: must DIFFER
#   ITEM=bulk_co_ff04 Rscript scripts/gpkg_determinism-check.R
#
# The cold path is the point. A guard nobody has seen fail is decoration — if the
# rebuilds match with the pin disabled, the check is not exercising what it claims
# and a green warm run means nothing. So NO_PIN=1 asserts they DIFFER and fails if
# they do not.
#
# Reads a staged tree; writes only to tempdir(). Never touches data/.

suppressMessages(library(sf))
source(file.path("scripts", "fp_gpkg.R"))   # the real writer, not a copy of it

item <- Sys.getenv("ITEM", unset = "sloc_bt_ff04")   # smallest staged item by default
# Strict truthiness: nzchar() would read NO_PIN=0 as enabled, so an operator turning the
# cold path OFF would turn it on and get "PASS (cold path)" for what they think is a warm
# check. Same form as ALLOW_SKIPPED in 01_stage.R.
no_pin <- tolower(Sys.getenv("NO_PIN", unset = "")) %in% c("1", "true", "yes")

src <- file.path("data", "stac", item, "floodplain_landcover.gpkg")
if (!file.exists(src)) {
  stop("no staged bundle at ", src, " — run scripts/run_pipeline.sh first, or set ITEM=")
}

meta <- jsonlite::read_json(file.path("data", "raw", item, "meta.json"))
layer <- paste0("transition_", meta$scenario, "_",
                meta$transition_span[[1]], "_", meta$transition_span[[2]])

if (no_pin) {
  # Unset rather than merely not setting: a parent process (or a previous call in
  # this session) may have exported it, which would leave the cold path silently
  # testing the pinned case and passing for the wrong reason.
  Sys.unsetenv("OGR_CURRENT_DATE")
  message("NO_PIN=1 — cold path; rebuilds MUST differ")
} else {
  gpkg_pin_date(quiet = FALSE)
}

tmp <- tempdir()
a <- file.path(tmp, "det_a.gpkg")
b <- file.path(tmp, "det_b.gpkg")

gpkg_extract_layer(src, layer, a, "transition")
# The unpinned stamp has millisecond resolution, so two writes in the same
# instant can match by accident and report a false PASS. A full second apart
# makes that impossible.
Sys.sleep(1.2)
gpkg_extract_layer(src, layer, b, "transition")

md5_a <- unname(tools::md5sum(a))
md5_b <- unname(tools::md5sum(b))
same <- identical(md5_a, md5_b)

message("\nitem   : ", item)
message("layer  : ", layer)
message("size   : ", file.size(a), " bytes (from a ", file.size(src), " byte bundle)")
message("md5 a  : ", md5_a)
message("md5 b  : ", md5_b)

unlink(c(a, b))

if (no_pin) {
  if (same) {
    stop("UNEXPECTED: rebuilds matched with the pin disabled. The check is not ",
         "exercising what it claims — investigate before trusting a warm pass.",
         call. = FALSE)
  }
  message("\nPASS (cold path): without the pin the rebuilds differ, as expected.")
} else {
  if (!same) {
    stop("Rebuilds differ WITH the pin set. Published file:checksum values for ",
         "transition_vector.gpkg will churn on every rebuild.", call. = FALSE)
  }
  message("\nPASS: byte-identical across rebuilds — file:checksum is stable.")
}
