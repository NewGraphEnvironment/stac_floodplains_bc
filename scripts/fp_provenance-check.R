# fp_provenance-check.R — prove the provenance reader offline, against both known answers.
#
# Usage:
#   Rscript scripts/fp_provenance-check.R          (exit = number of failed assertions)
#
# fp_provenance.R is the only place this repo knows the producer's file shape, and until
# this script it was exercised only by a full stage. Every guard in it fails toward a
# STOP, and a guard nobody has seen fire is decoration — so each case here restores the
# defect the guard exists for and asserts the stop, beside a control that must pass.
#
# Two sources of fixtures, and both run:
#   - a synthetic schema-2 document built here, mutated per case, so the cases run on any
#     machine with no upstream data at all;
#   - the real `$FLOODPLAINS_DATA/{bulk,neexdzii}/provenance.json` when present (the
#     producer's own bytes — the only interop evidence), skipped OUT LOUD when absent, and
#     counted: a run in which every real-file case skipped says so in its last line.
#
# neexdzii is a Bulkley subset and declares wsg "BULK", so its file is read from a temp
# directory named `bulk` — fp_prov_read compares the declared wsg to the directory name.

suppressPackageStartupMessages(library(jsonlite))

# PROV_FIELDS is declared in 01_stage.R, a script that stages on source. Evaluate that one
# assignment rather than the file, so this check needs no upstream tree and cannot stage.
exprs <- parse(file.path("scripts", "01_stage.R"))
is_prov <- vapply(exprs, function(e) is.call(e) && identical(e[[1]], as.name("<-")) &&
                    identical(e[[2]], as.name("PROV_FIELDS")), logical(1))
stopifnot("PROV_FIELDS assignment not found in 01_stage.R" = sum(is_prov) == 1L)
eval(exprs[[which(is_prov)]])
source(file.path("scripts", "fp_provenance.R"))

FAILS <- 0L; N <- 0L; SKIPPED <- 0L
pass <- function(desc) { N <<- N + 1L; cat("  ok    ", desc, "\n", sep = "") }
fail <- function(desc, why) {
  N <<- N + 1L; FAILS <<- FAILS + 1L
  cat("  FAIL  ", desc, " — ", why, "\n", sep = "")
}
skip <- function(desc, why) { SKIPPED <<- SKIPPED + 1L; cat("  skip  ", desc, " (", why, ")\n", sep = "") }
expect_true <- function(desc, cond) if (isTRUE(cond)) pass(desc) else fail(desc, "condition false")
expect_equal <- function(desc, got, want) {
  if (identical(got, want)) pass(desc)
  else fail(desc, paste0("got ", deparse(got)[1], ", want ", deparse(want)[1]))
}
# A stop whose message names the cause. The pattern is part of the assertion: a guard that
# stops for the WRONG reason (a downstream error, a typo) must not read as the guard firing.
expect_stop <- function(desc, expr, pattern) {
  msg <- tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))
  if (is.null(msg)) fail(desc, "did not stop")
  else if (!grepl(pattern, msg, fixed = TRUE)) fail(desc, paste0("stopped for another reason: ", substr(msg, 1, 160)))
  else pass(desc)
}
is_na1 <- function(v) length(v) == 1L && is.na(v)

# --- fixtures ---------------------------------------------------------------------------
HEX <- function(seed) paste0("sha256:", substr(paste(rep(seed, 64), collapse = ""), 1, 64))
synthetic <- function() {
  list(
    area = "bulk", wsg = "BULK", schema_version = 2L,
    network = list(co3 = list(
      inputs = list(species = "co", link = list(version = "0.50.0", sha = "abc", sha_source = "git", dirty = FALSE)),
      inputs_hash = "x", outputs = list(), outputs_hash = "y",
      link_log = list(run_uid = "20260901_234743-6628379d", config_hash = HEX("1"), link_sha = "689146867a5f"),
      link_log_note = NULL,
      run = list(datetime_utc = "2026-09-01T23:47:43Z"))),
    floodplain = list(co_ff04 = list(
      inputs = list(scenario = "co_ff04", flooded = list(version = "0.5.0")),
      inputs_hash = "x", run = list(datetime_utc = "2026-09-02T19:00:00Z"))),
    landcover = list(co_ff04 = list(
      inputs = list(source = "io-lulc", collection = "io-lulc-annual-v02",
                    stac_url = "https://planetarycomputer.microsoft.com/api/stac/v1",
                    item_hash = HEX("c"),
                    classified_content_sha256 = list(`2017` = HEX("a"), `2020` = HEX("b"), `2023` = HEX("d")),
                    drift = list(version = "0.8.0")),
      inputs_hash = "x", run = list(datetime_utc = "2026-09-02T19:48:49Z")))
  )
}
WORK <- tempfile("prov_check_"); dir.create(WORK)
# Write a document to <WORK>/<case>/bulk/provenance.json and read it back through the
# real reader, so every case crosses the same JSON round-trip staging does.
read_doc <- function(doc, case) {
  d <- file.path(WORK, case, "bulk"); dir.create(d, recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(doc, file.path(d, "provenance.json"), auto_unbox = TRUE, null = "null", na = "null", digits = NA)
  fp_prov_read(d)
}
item <- function(prov, species = "co", scenario = "co_ff04") fp_prov_item(prov, species, scenario, "check")

# --- synthetic cases --------------------------------------------------------------------
cat("synthetic schema-2 document\n")
base <- read_doc(synthetic(), "base")
got <- item(base)
expect_equal("publishes exactly PROV_FIELDS, in order", names(got), PROV_FIELDS)
expect_true("every field non-null when all three sections are present",
            !any(vapply(got, is_na1, logical(1))))
expect_equal("link_run_uid is the log's run_uid", got$link_run_uid, "20260901_234743-6628379d")
expect_equal("flooded_version from the floodplain section", got$flooded_version, "0.5.0")
expect_equal("produced_datetime is the LANDCOVER step's stamp", got$produced_datetime, "2026-09-02T19:48:49Z")

cat("schema pin\n")
d <- synthetic(); d$schema_version <- 1L
expect_stop("schema_version 1 is refused, naming both versions", read_doc(d, "schema1"),
            "declares schema_version 1 but this reader implements 2")
d <- synthetic(); d$schema_version <- NULL
expect_stop("a missing schema_version is refused", read_doc(d, "schema_absent"), "<absent>")

cat("the rename's second signal: unknown top-level key\n")
d <- synthetic(); d$floodplain_v2 <- d$floodplain; d$floodplain <- NULL
expect_stop("a renamed section is refused, not read as a step that did not run",
            read_doc(d, "root_rename"), "unrecognised top-level key(s): floodplain_v2")

cat("absence vs schema break\n")
d <- synthetic(); d$landcover <- list()
got <- item(read_doc(d, "no_landcover"))
lc <- c("drift_version", "produced_datetime", "landcover_source", "landcover_collection", "landcover_stac_url", "landcover_key")
expect_true("no landcover section -> every landcover field NA", all(vapply(got[lc], is_na1, logical(1))))
expect_true("...and the network + floodplain fields still populated",
            !any(vapply(got[setdiff(PROV_FIELDS, lc)], is_na1, logical(1))))
d <- synthetic(); d$landcover$co_ff04$inputs$item_digest <- d$landcover$co_ff04$inputs$item_hash
d$landcover$co_ff04$inputs$item_hash <- NULL
expect_stop("a renamed LEAF under a present section stops (schema break, not an absence)",
            item(read_doc(d, "leaf_rename")), "is missing (stopped at 'item_hash')")
# `x$link_log <- NULL` REMOVES the key in R; `x["link_log"] <- list(NULL)` keeps it null.
# Both shapes are asserted because the reader must tell them apart: the producer sets
# link_log to null when it has no log row (a modelled absence), while a missing key is a
# rename. The first draft of this case used the removing form and the reader refused it —
# correctly — which is the assertion directly below.
d <- synthetic(); d$network$co3$link_log <- NULL
expect_stop("an ABSENT link_log key is a schema break, not the modelled null",
            item(read_doc(d, "link_log_absent")), "stopped at 'link_log'")
d <- synthetic(); d$network$co3["link_log"] <- list(NULL)
got <- item(read_doc(d, "link_log_null"))
expect_true("a modelled null link_log publishes the three link_log fields as NA",
            all(vapply(got[c("link_run_uid", "link_config_sha256", "link_sha")], is_na1, logical(1))))
expect_equal("...and link_version (from inputs$link) survives", got$link_version, "0.50.0")
d <- synthetic(); d$landcover$co_ff04$inputs$source <- list(name = "io-lulc")
expect_stop("an object where a scalar is expected stops rather than publishing its member",
            item(read_doc(d, "object_leaf")), "must be an atomic scalar")
d <- synthetic(); d$network$co3$inputs$species <- NULL
expect_stop("a network section with no inputs$species is a schema break",
            item(read_doc(d, "no_species")), "has no inputs$species")
d <- synthetic(); names(d$landcover) <- "ff04"
expect_stop("a re-keyed scenario section stops", item(read_doc(d, "rekeyed")), "not scenario ids of the form")
d <- synthetic(); d$wsg <- "MORR"
expect_stop("a file declaring another wsg than its directory stops", read_doc(d, "wrong_wsg"), "declares wsg 'MORR'")

# --- real files -------------------------------------------------------------------------
cat("real producer files\n")
FP <- Sys.getenv("FLOODPLAINS_DATA", unset = file.path("..", "floodplains", "data"))
real <- function(area) {
  src <- file.path(FP, area, "provenance.json")
  if (!file.exists(src) || file.size(src) == 0) return(NULL)
  d <- file.path(WORK, paste0("real_", area), "bulk"); dir.create(d, recursive = TRUE, showWarnings = FALSE)
  file.copy(src, file.path(d, "provenance.json"), overwrite = TRUE)
  fp_prov_read(d)
}
b <- real("bulk")
if (is.null(b)) skip("bulk/provenance.json reads", "not on this machine") else {
  got <- item(b)
  expect_true("bulk: link_* and flooded_version populated from the v2 file",
              !any(vapply(got[c("link_run_uid", "link_config_sha256", "link_sha", "link_version", "flooded_version")], is_na1, logical(1))))
  expect_equal("bulk: flooded_version is the #26 fix (0.5.0)", got$flooded_version, "0.5.0")
  expect_true("bulk: landcover fields NA while its step 3 has not been re-run",
              all(vapply(got[lc], is_na1, logical(1))))
}
n <- real("neexdzii")
if (is.null(n)) skip("neexdzii/provenance.json reads", "not on this machine") else {
  got <- item(n)
  expect_true("neexdzii: every field non-null", !any(vapply(got, is_na1, logical(1))))
  expect_equal("neexdzii: landcover_source", got$landcover_source, "io-lulc")
  expect_true("neexdzii: landcover_key is a sha256: string",
              grepl("^sha256:[0-9a-f]{64}$", got$landcover_key))
}

unlink(WORK, recursive = TRUE)
cat("\n", N, " assertions, ", FAILS, " failed, ", SKIPPED, " skipped",
    if (SKIPPED > 0 && is.null(b) && is.null(n)) " — NO real producer file was read; only synthetic cases ran" else "",
    "\n", sep = "")
quit(status = FAILS)
