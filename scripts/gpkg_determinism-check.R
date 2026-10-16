# gpkg_determinism-check.R — prove the GeoPackage timestamp pin actually works.
#
# This repo WRITES three GeoPackages per item and #22 publishes a `file:checksum` for
# each. If GDAL stamps a wall-clock time into any of them, that checksum churns on every
# rebuild from identical inputs — provenance in name only. scripts/fp_gpkg.R pins
# OGR_CURRENT_DATE to stop that. This checks the pin holds, over both writers:
#
#   * the single-layer extraction (`gpkg_extract_layer`, #23) -> transition_vector.gpkg
#   * the multi-layer selection (`gpkg_copy_layers`, #80) -> floodplain.gpkg and
#     floodplain_landcover.gpkg, which stopped being verbatim upstream copies in #80
#
#   Rscript scripts/gpkg_determinism-check.R                 # warm path: must MATCH
#   NO_PIN=1 Rscript scripts/gpkg_determinism-check.R        # cold path: must DIFFER
#   ITEM=morr_all_ff04 Rscript scripts/gpkg_determinism-check.R
#
# The cold path is the point. A guard nobody has seen fail is decoration — if the
# rebuilds match with the pin disabled, the check is not exercising what it claims
# and a green warm run means nothing. So NO_PIN=1 asserts they DIFFER and fails if
# they do not.
#
# Reads a staged tree (and $FLOODPLAINS_DATA when present); writes only to tempdir().
# Never touches data/.

suppressMessages(library(sf))
source(file.path("scripts", "fp_gpkg.R"))   # the real writers, not copies of them

# Smallest staged item by default. SLOC flipped to the whole network in the Columbia run of
# 2026-10-15, so the default moved with it (#89) — exactly as the note this comment replaces
# said it would have to. The failure mode the note existed for is the one the `ufra` defaults
# in test_pipeline.R and stage_years-check.R CARRIED, before #76 moved both to `bulk`: an id
# nothing stages any more, which stops the script rather than checking anything.
item <- Sys.getenv("ITEM", unset = "sloc_all_ff04")
# Strict truthiness: nzchar() would read NO_PIN=0 as enabled, so an operator turning the
# cold path OFF would turn it on and get "PASS (cold path)" for what they think is a warm
# check. Same form as ALLOW_SKIPPED in 01_stage.R.
no_pin <- tolower(Sys.getenv("NO_PIN", unset = "")) %in% c("1", "true", "yes")

staged <- file.path("data", "stac", item)
src <- file.path(staged, "floodplain_landcover.gpkg")
# BOTH staged bundles, not just the one arm 1 reads: `floodplain.gpkg` is where the second
# multi-layer arm takes its layer set from, and a missing one would otherwise surface further
# down as an st_layers() failure naming only a path. `transition_vector.gpkg` is NOT checked
# here because nothing reads it — arm 1 writes it into tempdir() from the landcover bundle.
# (An earlier version of this comment said "all three ... the other two" over a loop of two.)
for (f in c("floodplain_landcover.gpkg", "floodplain.gpkg")) {
  if (!file.exists(file.path(staged, f))) {
    stop("no staged ", f, " at ", staged,
         " — run scripts/run_pipeline.sh first, or set ITEM=")
  }
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
results <- list()   # one row per arm: label, source, md5 a, md5 b, size

#' Build twice from one source and report whether the bytes match.
#'
#' The unpinned stamp has millisecond resolution, so two writes in the same instant can
#' match by accident and report a false PASS. A full second apart makes that impossible —
#' and it still matters for the multi-layer arms, whose per-layer `last_change` values
#' could otherwise collide sub-millisecond.
twice <- function(label, source, build) {
  a <- file.path(tmp, paste0("det_a_", label, ".gpkg"))
  b <- file.path(tmp, paste0("det_b_", label, ".gpkg"))
  build(a)
  Sys.sleep(1.2)
  build(b)
  out <- list(label = label, source = source,
              md5_a = unname(tools::md5sum(a)), md5_b = unname(tools::md5sum(b)),
              size = file.size(a))
  unlink(c(a, b))
  out
}

# --- Arm 1: the single-layer extraction, from the staged bundle ----------------------
results[[length(results) + 1L]] <- twice(
  "transition_vector", src,
  function(dst) gpkg_extract_layer(src, layer, dst, "transition"))

# --- Arms 2-3: the multi-layer selection, from the PRODUCER's files ------------------
# Read upstream, NOT the staged copy, and this is the whole point of the arm. Since #80 the
# staged `floodplain*.gpkg` are themselves `gpkg_copy_layers()` output, so re-translating
# one would prove "translating our own output is stable" — a different and much weaker
# claim than "translating the producer's file is stable", which is the property whose
# failure churns 46 published checksums (two assets x 23 items).
#
# Skipped OUT LOUD when the source tree is absent, so a release cut from a machine that
# does not hold it reads as "not proven here", never as a pass. Same idiom as
# stage_years-check.R's missing-tree arm.
FP <- Sys.getenv("FLOODPLAINS_DATA", unset = "../floodplains/data")
src_wsg <- file.path(FP, meta$wsg_lower)
upstream_skipped <- character(0)
for (gp in c("floodplain.gpkg", "floodplain_landcover.gpkg")) {
  up <- file.path(src_wsg, gp)
  if (!file.exists(up)) { upstream_skipped <- c(upstream_skipped, gp); next }
  # The layer set comes from the STAGED file, and that is sound HERE and nowhere else:
  # determinism does not care which layers are selected, only that selecting the same ones
  # twice gives the same bytes. Said out loud because the repo's convention is the reverse —
  # item_validate.py and test_pipeline.R both take their expectations from a different
  # artifact than the one under test, precisely so an expectation cannot agree with itself.
  #
  # The ORDER this query returns them in does not have to match the stage's, because
  # gpkg_copy_layers() sorts internally. It did not always: while the writer honoured the
  # caller's order, this check's `ORDER BY table_name` and the stage's `st_layers()` order
  # produced different bytes from the same layers, so a green warm arm here described a file
  # the stage does not write. That is why the sort is in the writer rather than in its
  # callers.
  #
  # `layer_styles` is excluded BY NAME, which a staged-side list did not used to need:
  # since #95 `04_gpkg_style.py` registers it in `gpkg_contents` as `attributes`, so it is
  # now inside the filter above. It exists only on the staged side — the producer's file
  # has no style table — and `gpkg_copy_layers()` stops with GDAL's
  # `Couldn't fetch requested layer`, a message that blames the copier for a layer the
  # caller asked for. Excluding is right rather than intersecting with the producer's
  # layers, because a layer genuinely missing upstream must still fail loudly here.
  layers <- sf::st_read(file.path(staged, gp), quiet = TRUE,
                        query = paste("SELECT table_name FROM gpkg_contents",
                                      "WHERE data_type IN ('features','attributes')",
                                      "AND table_name <> 'layer_styles'",
                                      "ORDER BY table_name"))$table_name
  if (!length(layers)) stop("staged ", gp, " declares no layers — nothing to re-translate")
  local({
    u <- up; l <- layers
    results[[length(results) + 1L]] <<- twice(
      tools::file_path_sans_ext(gp), u,
      function(dst) gpkg_copy_layers(u, dst, l))
  })
}

message("\nitem   : ", item)
message("layer  : ", layer, " (transition_vector arm)")
for (r in results) {
  message(sprintf("%-25s %9d bytes  a %s  b %s  %s", r$label, r$size,
                  substr(r$md5_a, 1, 12), substr(r$md5_b, 1, 12),
                  if (identical(r$md5_a, r$md5_b)) "MATCH" else "DIFFER"))
  message(sprintf("%-25s from %s", "", r$source))
}
for (gp in upstream_skipped) {
  message("  skip  ", gp, " (no upstream file at ", file.path(src_wsg, gp), ")")
}

same <- vapply(results, function(r) identical(r$md5_a, r$md5_b), logical(1))
labels <- vapply(results, function(r) r$label, character(1))

if (no_pin) {
  # EVERY arm must differ, not merely one of them. A writer that turned out to be
  # timestamp-free would make its own arm match here, and reporting that as a cold-path
  # pass is the shape this check exists to refuse: it would mean the warm pass for that
  # arm proves nothing.
  if (any(same)) {
    stop("UNEXPECTED: ", paste(labels[same], collapse = ", "),
         " matched with the pin disabled. Those arms are not exercising what they claim — ",
         "investigate before trusting a warm pass.", call. = FALSE)
  }
  message("\nPASS (cold path): without the pin all ", length(results),
          " arm(s) differ, as expected.")
} else {
  if (!all(same)) {
    stop("Rebuilds differ WITH the pin set for: ", paste(labels[!same], collapse = ", "),
         ". Published file:checksum values for those assets will churn on every rebuild.",
         call. = FALSE)
  }
  message("\nPASS: all ", length(results),
          " arm(s) byte-identical across rebuilds — file:checksum is stable.")
  if (length(upstream_skipped)) {
    message("NOT PROVEN: the multi-layer writer was not exercised against the producer's ",
            paste(upstream_skipped, collapse = " / "),
            " — re-run where $FLOODPLAINS_DATA is present.")
  }
}
