# stage_years-check.R — prove 01_stage.R's year-set guard fires at the REAL call site (#61).
#
# Usage:
#   Rscript scripts/stage_years-check.R     (exit = number of failed assertions)
#
# fp_provenance-check.R drives fp_years_reconcile() directly, which covers the guard's
# arms but not the code that CHOOSES its arguments. A test that drives the helper covers
# the other value, not the call site — so this one restores each defect in a real upstream
# tree and runs 01_stage.R over it.
#
# Isolated by construction: the stage is run with its cwd in a sandbox holding a `scripts`
# symlink, so `data/raw` and `data/stac` land in the sandbox and the repo's own build tree
# is never touched. The upstream area is symlinked file-by-file, so no raster is copied.
#
# Each arm greps for ITS OWN message. A suite with N guards has N ways to exit 1, and every
# one of them looks like success to a check that reads the status.

suppressPackageStartupMessages(library(jsonlite))
suppressPackageStartupMessages(library(digest))
suppressPackageStartupMessages(library(yaml))

FAILS <- 0L; N <- 0L; SKIPPED <- 0L
pass <- function(d) { N <<- N + 1L; cat("  ok    ", d, "\n", sep = "") }
fail <- function(d, why) { N <<- N + 1L; FAILS <<- FAILS + 1L
                           cat("  FAIL  ", d, " — ", why, "\n", sep = "") }
skip <- function(d, why) { SKIPPED <<- SKIPPED + 1L; cat("  skip  ", d, " (", why, ")\n", sep = "") }
expect_true <- function(d, cond) if (isTRUE(cond)) pass(d) else fail(d, "condition false")

REPO <- normalizePath(".")
FP <- Sys.getenv("FLOODPLAINS_DATA", unset = file.path("..", "floodplains", "data"))
AREA <- "ufra"; SCEN <- "ch_ff04"

src_area <- file.path(FP, AREA)
src_cfg <- file.path(dirname(FP), "config", AREA, "area.yml")
region_files <- list.files(file.path(dirname(FP), "config", "regions"),
                           pattern = "\\.yml$", full.names = TRUE)
AREA_REGION <- NULL
for (rf in region_files) {
  rc <- yaml::read_yaml(rf)
  if (AREA %in% tolower(rc$watershed_groups)) { AREA_REGION <- rc$region; break }
}
if (!dir.exists(src_area) || !file.exists(src_cfg) || is.null(AREA_REGION)) {
  cat("  skip  every case (no upstream tree at ", FP, ")\n", sep = "")
  cat("\n0 assertions, 0 failed, 1 skipped — the call site was NOT proven\n")
  quit(status = 0)
}

# --- Build a sandbox whose upstream area is symlinks --------------------------------------
# `provenance.json` is a real copy in every sandbox: one arm rewrites it, and a symlink
# would rewrite the producer's own file.
sandbox <- function(case) {
  sbx <- file.path(tempdir(), paste0("stage_years_", case))
  unlink(sbx, recursive = TRUE)
  dir.create(file.path(sbx, "src", "config", "regions"), recursive = TRUE)
  dir.create(file.path(sbx, "src", "config", AREA), recursive = TRUE)
  dir.create(file.path(sbx, "src", "data", AREA, "rasters", SCEN), recursive = TRUE)
  invisible(file.symlink(file.path(REPO, "scripts"), file.path(sbx, "scripts")))

  # The region NAME is copied from the real roster, never invented: `region` is a published
  # meta.json field, so a synthetic one would move the bytes the control asserts are stable
  # and the failure would read as the code change having moved the data.
  writeLines(c(paste0("region: ", AREA_REGION), "watershed_groups:", paste0("  - ", AREA)),
             file.path(sbx, "src", "config", "regions", "test.yml"))
  stopifnot("area.yml copy failed" =
              file.copy(src_cfg, file.path(sbx, "src", "config", AREA, "area.yml")))
  stopifnot("provenance.json copy failed" =
              file.copy(file.path(src_area, "provenance.json"),
                        file.path(sbx, "src", "data", AREA, "provenance.json")))
  for (f in list.files(src_area, pattern = "\\.gpkg$")) {
    invisible(file.symlink(normalizePath(file.path(src_area, f)),
                           file.path(sbx, "src", "data", AREA, f)))
  }
  rd <- file.path(src_area, "rasters", SCEN)
  for (f in list.files(rd)) {
    invisible(file.symlink(normalizePath(file.path(rd, f)),
                           file.path(sbx, "src", "data", AREA, "rasters", SCEN, f)))
  }
  sbx
}

# Combined output, because a stop() lands on stderr and the progress lines on stdout, and
# the arms have to be told apart by MESSAGE, never by the exit status.
#
# Launched through a shell rather than system2(): 01_stage.R resolves `scripts/fp_gpkg.R`
# and `data/raw` against the CWD, and system2() cannot set one.
run_in <- function(sbx, drift_skew = FALSE) {
  cmd <- paste0("cd ", shQuote(sbx), " && FLOODPLAINS_DATA=",
                shQuote(file.path(sbx, "src", "data")), " WSG_ONLY=", AREA,
                if (drift_skew) " ALLOW_DRIFT_SKEW=1" else "",
                " Rscript ", shQuote(file.path(REPO, "scripts", "01_stage.R")), " 2>&1")
  paste(suppressWarnings(system(cmd, intern = TRUE)), collapse = "\n")
}

raster_path <- function(sbx, yr) {
  file.path(sbx, "src", "data", AREA, "rasters", SCEN, sprintf("classified_%d.tif", yr))
}

# --- Control: the unmutated tree stages, and does not move a three-year item ---------------
# The control is not decoration. A guard that has never passed is as untested as one that
# has never fired, and every arm below is only evidence if the same tree stages clean.
cat("control\n")
sbx <- sandbox("control")
out <- run_in(sbx, drift_skew = TRUE)
expect_true("the unmutated tree stages the item", grepl("STAGED ufra_ch_ff04", out, fixed = TRUE))
expect_true("...and trips none of the year-set arms",
            !grepl("recorded-but-absent|do not cover the transition span|change_interval", out))
# The issue's "every existing three-year item byte-identical — this issue changes code, not
# data" criterion, as a standing assertion rather than a one-off command.
#
# Against a PIN, not against `<repo>/data/raw`. 01_stage.R unlinks data/raw and data/stac
# wholesale on every run (:80-81), so the previous build is gone the moment anyone stages
# anything — a reference tree here would be present or absent depending on what was run
# last, and absent is the direction that reads as a pass.
#
# Taken 2026-09-05 from the last pre-change build of ufra_ch_ff04, and gated on ufra's own
# landcover stamp: floodplains#79 is converting areas to an annual span one at a time, and
# when it reaches ufra this pin stops describing anything. Skipped OUT LOUD then, so a
# re-run reads as "re-take the pin", never as "the code moved the data".
PIN_META_SHA256 <- "22c2460f77b6b7f0da3a2c23cf0290cddf81429e657a692fc3e7b2eaac0e68e3"
PIN_STAMP <- "2026-09-03T07:16:49Z"
built <- file.path(sbx, "data", "raw", "ufra_ch_ff04", "meta.json")
if (!file.exists(built)) {
  fail("a three-year item's meta.json is byte-identical to the pre-change build",
       "no meta.json staged")
} else {
  stamp <- jsonlite::read_json(built)$produced_datetime
  if (!identical(stamp, PIN_STAMP)) {
    skip("a three-year item's meta.json is byte-identical to the pre-change build",
         paste0("upstream re-ran ufra (", stamp, " != pinned ", PIN_STAMP,
                ") — re-take the pin from the new build"))
  } else {
    expect_true("a three-year item's meta.json is byte-identical to the pre-change build",
                identical(digest::digest(built, algo = "sha256", file = TRUE), PIN_META_SHA256))
  }
}
expect_true("the sandbox holds the build, and the repo's tree was not written",
            dir.exists(file.path(sbx, "data", "stac", "ufra_ch_ff04")))

# --- Arm (a): the record names a year the rasters do not have -----------------------------
cat("arm (a): a raster the record names is missing from disk\n")
sbx <- sandbox("missing")
gone <- raster_path(sbx, 2020)
stopifnot("premise: the raster to delete is there" = file.exists(gone))
unlink(gone)
expect_true("premise: the mutation took — classified_2020.tif is gone", !file.exists(gone))
out <- run_in(sbx)
expect_true("the stage refuses, naming the year and the direction",
            grepl("recorded-but-absent: 2020; present-but-unrecorded: none", out, fixed = TRUE))
expect_true("...and nothing was staged", !grepl("STAGED ufra_ch_ff04", out, fixed = TRUE))

# --- Arm (b): a raster on disk the record does not name -----------------------------------
# The direction with no guard AT ALL before this change: an extra raster upstream wrote
# would have been ignored by a constant year list and published nowhere, silently.
cat("arm (b): a raster on disk the record does not name\n")
sbx <- sandbox("extra")
extra <- raster_path(sbx, 2021)
stopifnot("premise: 2021 is not already there" = !file.exists(extra))
invisible(file.symlink(normalizePath(raster_path(sbx, 2020)), extra))
expect_true("premise: the mutation took — classified_2021.tif is there", file.exists(extra))
out <- run_in(sbx)
expect_true("the stage refuses, naming the unrecorded year",
            grepl("recorded-but-absent: none; present-but-unrecorded: 2021", out, fixed = TRUE))
expect_true("...and nothing was staged", !grepl("STAGED ufra_ch_ff04", out, fixed = TRUE))

# --- Arm (c): the record itself is wrong --------------------------------------------------
# Mutating the RECORD rather than the disk. The guard reads one copy of the year set from
# each side, and a proof that moves the wrong one exits 0 and reads as a pass (#26's mirror);
# this arm moves the provenance copy, arms (a)/(b) move the disk copy.
cat("arm (c): the record names a year that was never built\n")
sbx <- sandbox("record")
pj <- file.path(sbx, "src", "data", AREA, "provenance.json")
doc <- jsonlite::read_json(pj, simplifyVector = FALSE)
before <- unlist(doc$landcover[[SCEN]]$inputs$years)
doc$landcover[[SCEN]]$inputs$years <- list(2017L, 2019L, 2023L)
jsonlite::write_json(doc, pj, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
after <- unlist(jsonlite::read_json(pj, simplifyVector = FALSE)$landcover[[SCEN]]$inputs$years)
expect_true("premise: the mutation took — the record now says 2017, 2019, 2023",
            !identical(before, after) && identical(as.integer(after), c(2017L, 2019L, 2023L)))
out <- run_in(sbx)
expect_true("the stage refuses, reporting both directions",
            grepl("recorded-but-absent: 2019; present-but-unrecorded: 2020", out, fixed = TRUE))
expect_true("...and nothing was staged", !grepl("STAGED ufra_ch_ff04", out, fixed = TRUE))

for (case in c("control", "missing", "extra", "record")) {
  unlink(file.path(tempdir(), paste0("stage_years_", case)), recursive = TRUE)
}
cat("\n", N, " assertions, ", FAILS, " failed, ", SKIPPED, " skipped\n", sep = "")
quit(status = FAILS)
