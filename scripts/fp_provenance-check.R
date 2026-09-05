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
# fp_prov_read compares the declared `area` to the directory it was read from (neexdzii is
# a Bulkley subset: area "neexdzii", wsg "BULK"), so each real file is read from a temp
# directory named after its area.

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
                    years = list(2017L, 2020L, 2023L),
                    change_interval = list(2017L, 2023L),
                    drift = list(version = "0.8.0")),
      inputs_hash = "x", run = list(datetime_utc = "2026-09-02T19:48:49Z")))
  )
}
WORK <- tempfile("prov_check_"); dir.create(WORK)
# Write a document to <WORK>/<case>/bulk/provenance.json and read it back through the
# real reader, so every case crosses the same JSON round-trip staging does.
read_doc <- function(doc, case, area = "bulk") {
  d <- file.path(WORK, case, area); dir.create(d, recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(doc, file.path(d, "provenance.json"), auto_unbox = TRUE, null = "null", na = "null", digits = NA)
  fp_prov_read(d)
}
YEARS <- c(2017, 2020, 2023)   # the published span; 01_stage.R passes doubles, folded identically
item <- function(prov, species = "co", scenario = "co_ff04") fp_prov_item(prov, species, scenario, "check", YEARS)

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
lc <- c("drift_version", "produced_datetime", "landcover_source", "landcover_collection", "landcover_stac_url", "landcover_key", "landcover_item_hash")
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
d <- synthetic(); d$area <- "morr"
expect_stop("a file declaring another area than its directory stops", read_doc(d, "wrong_area"), "declares area 'morr'")
d <- synthetic(); d$area <- NULL; d$wsg <- "MORR"
expect_stop("...and with no area recorded, the wsg is compared instead", read_doc(d, "wrong_wsg"), "declares area 'MORR'")
d <- synthetic(); d$area <- "neexdzii"
expect_true("a subset area sharing its parent's wsg reads from its own directory",
            !is.null(read_doc(d, "subset", area = "neexdzii")))

cat("rasters vs the record that describes them\n")
# The reference is the landcover section's run stamp, NOT the file's mtime. Three states,
# from the round-3 review; the third is the one a file-mtime reference cannot see, because
# every upstream step rewrites the whole file:
#   consistent            rasters T0-15s, stamp T0                      -> pass
#   step 3 crashed        rasters T0+10min, stamp T0, file mtime T0     -> stop
#   ...then step 1 re-ran rasters T0+10min, stamp T0, file mtime T0+20 -> stop (still)
stamp <- as.POSIXct("2026-09-02T19:48:49Z", format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")  # synthetic()'s
rd <- file.path(WORK, "mtime", "bulk"); dir.create(rd, recursive = TRUE, showWarnings = FALSE)
jsonlite::write_json(synthetic(), file.path(rd, "provenance.json"), auto_unbox = TRUE, null = "null", na = "null", digits = NA)
rp <- file.path(rd, sprintf("classified_%d.tif", YEARS)); for (f in rp) writeLines("x", f)
invisible(Sys.setFileTime(rp, stamp - 15))
mt_prov <- fp_prov_read(rd)
expect_true("rasters older than the section's stamp pass",
            isTRUE(fp_prov_rasters_current(rd, rp, mt_prov, "co", "co_ff04", "check")))
invisible(Sys.setFileTime(rp[2], stamp + 0.5))
expect_true("a raster written in the stamp's own second is the record's own raster (floored)",
            isTRUE(fp_prov_rasters_current(rd, rp, mt_prov, "co", "co_ff04", "check")))
invisible(Sys.setFileTime(rp[2], stamp + 600))
expect_stop("a raster newer than the stamp stops, naming it and the stamp",
            fp_prov_rasters_current(rd, rp, mt_prov, "co", "co_ff04", "check"), "classified_2020.tif")
# The masking row: another step rewrote the file AFTER the stale rasters. The file is now
# newer than every raster; the section stamp is not, and that is what is compared.
invisible(Sys.setFileTime(file.path(rd, "provenance.json"), stamp + 1200))
expect_stop("...and a later rewrite of the file by another step does not mask it",
            fp_prov_rasters_current(rd, rp, mt_prov, "co", "co_ff04", "check"), "classified_2020.tif")
expect_true("premise: the file really is newer than the late raster in that case",
            file.mtime(file.path(rd, "provenance.json")) > file.mtime(rp[2]))
d <- synthetic(); d$landcover <- list()
expect_true("no landcover section -> no fingerprint -> no check",
            isTRUE(fp_prov_rasters_current(rd, rp, read_doc(d, "mtime_nolc"), "co", "co_ff04", "check")))
d <- synthetic(); d$landcover$co_ff04$run$datetime_utc <- NULL
expect_stop("a landcover section with no run stamp cannot be checked and stops",
            fp_prov_rasters_current(rd, rp, read_doc(d, "mtime_nostamp"), "co", "co_ff04", "check"), "no parseable run$datetime_utc")

# --- the landcover fold (#40) ------------------------------------------------------------
cat("landcover_key: the fold of classified_content_sha256\n")
fold_of <- function(m) { d <- synthetic(); d$landcover$co_ff04$inputs$classified_content_sha256 <- m; item(read_doc(d, "fold"))$landcover_key }
ref <- fold_of(list(`2017` = HEX("a"), `2020` = HEX("b"), `2023` = HEX("d")))
expect_true("the fold is a sha256: digest", grepl("^sha256:[0-9a-f]{64}$", ref))
expect_true("...and is not any single year's digest", !ref %in% c(HEX("a"), HEX("b"), HEX("d")))
expect_equal("the fold is the stated rule, recomputed here",
             ref, paste0("sha256:", digest::digest(paste0("2017=", HEX("a"), "\n2020=", HEX("b"), "\n2023=", HEX("d")),
                                                   algo = "sha256", serialize = FALSE)))
expect_equal("key order in the map does not move it",
             fold_of(list(`2023` = HEX("d"), `2017` = HEX("a"), `2020` = HEX("b"))), ref)
expect_true("one changed hex digit in one year moves it",
            fold_of(list(`2017` = HEX("a"), `2020` = HEX("b"), `2023` = sub("d$", "e", HEX("d")))) != ref)
expect_stop("a missing year stops", fold_of(list(`2017` = HEX("a"), `2020` = HEX("b"))), "covers year(s) 2017, 2020 but the item publishes 2017, 2020, 2023")
expect_stop("an extra year stops", fold_of(list(`2017` = HEX("a"), `2020` = HEX("b"), `2023` = HEX("d"), `2026` = HEX("f"))), "covers year(s) 2017, 2020, 2023, 2026")
expect_stop("a value that is not sha256:<64 hex> stops", fold_of(list(`2017` = "abc", `2020` = HEX("b"), `2023` = HEX("d"))), "classified_content_sha256[2017] is not")
expect_stop("a scalar where the map should be stops", fold_of(HEX("a")), "must be an object keyed by year")
# `m["2020"] <- list(NULL)` keeps the year with a JSON null (upstream writes NA for a raster
# absent at digest time); `unlist()` would silently drop it. Same lesson as link_log above.
m <- list(`2017` = HEX("a"), `2020` = HEX("b"), `2023` = HEX("d")); m["2020"] <- list(NULL)
expect_stop("a year whose digest is JSON null stops, naming the year", fold_of(m), "classified_content_sha256[2020] is null")
expect_stop("a fold given no years stops, naming the cause",
            fp_fold_year_digests(list(`2017` = HEX("a")), "check", character(0)), "given no published years")
d <- synthetic(); d$landcover$co_ff04$inputs["classified_content_sha256"] <- list(NULL)
expect_true("a JSON-null map publishes NA (modelled absence), not a fold of nothing",
            is_na1(item(read_doc(d, "fold_null"))$landcover_key))
got <- item(base)
expect_equal("landcover_item_hash is the file's item_hash verbatim", got$landcover_item_hash, HEX("c"))
expect_true("landcover_key and landcover_item_hash are different values", got$landcover_key != got$landcover_item_hash)

# --- the item's temporal shape (#61) -----------------------------------------------------
cat("fp_prov_span: the year set is read, not declared\n")
span_of <- function(mut, case) {
  d <- synthetic()
  if (!is.null(mut)) d$landcover$co_ff04$inputs <- mut(d$landcover$co_ff04$inputs)
  fp_prov_span(read_doc(d, case), "co", "co_ff04", "check")
}
expect_equal("reads the recorded years as a sorted integer vector",
             span_of(NULL, "span_base")$years, c(2017L, 2020L, 2023L))
expect_equal("...and the change_interval beside them",
             span_of(NULL, "span_base")$change_interval, c(2017L, 2023L))
expect_equal("key order in the record does not move the result",
             span_of(function(i) { i$years <- list(2023L, 2017L, 2020L); i }, "span_unsorted")$years,
             c(2017L, 2020L, 2023L))
expect_equal("a seven-year record reads back as seven",
             span_of(function(i) { i$years <- as.list(2017:2023); i }, "span_seven")$years,
             2017:2023)
d <- synthetic(); d$landcover <- list()
expect_true("no landcover section -> NULL, the forward-only state",
            is.null(fp_prov_span(read_doc(d, "span_nolc"), "co", "co_ff04", "check")))
# The three-state discipline: a PRESENT section missing the key must stop, not degrade to
# NULL. A NULL here would silently route a provenanced item onto the disk-only path — the
# one path with nothing to check it against.
expect_stop("a present section with no inputs$years stops",
            span_of(function(i) { i$years <- NULL; i }, "span_noyears"), "has no inputs$years")
expect_stop("a present section with no inputs$change_interval stops",
            span_of(function(i) { i$change_interval <- NULL; i }, "span_noci"),
            "has no inputs$change_interval")
# `i["years"] <- list(NULL)` keeps the key with a JSON null. unlist() would DROP it and
# fold a shorter span that looks entirely valid — the same lesson as the digest map above.
expect_stop("a null year stops rather than being dropped",
            span_of(function(i) { i$years <- list(2017L, NULL, 2023L); i }, "span_nullyear"),
            "are not whole numbers")
expect_stop("a string year stops rather than being coerced",
            span_of(function(i) { i$years <- list(2017L, "2020", 2023L); i }, "span_stryear"),
            "are not whole numbers")
expect_stop("a repeated year stops",
            span_of(function(i) { i$years <- list(2017L, 2020L, 2020L); i }, "span_dup"),
            "repeats year(s) 2020")
# Not pedantry: jsonlite's auto_unbox writes a length-1 vector as {"years": 2017}, and
# item_create.py's `for yr in meta["years"]` then raises TypeError on an int. A latent
# crash three steps downstream, not a refusal.
expect_stop("a length-1 years stops",
            span_of(function(i) { i$years <- list(2017L); i }, "span_one"),
            "has 1 year(s)")

cat("fp_years_reconcile: disk against the record, both known answers\n")
SPAN3 <- list(years = c(2017L, 2020L, 2023L), change_interval = c(2017L, 2023L))
SPAN7 <- list(years = 2017:2023, change_interval = c(2017L, 2023L))
TS <- c(2017L, 2023L)
# Controls first. A guard that has never passed is as untested as one that has never fired.
expect_true("a three-year disk set matching its record passes, and reports traced",
            isTRUE(fp_years_reconcile(c(2017L, 2020L, 2023L), SPAN3, TS, "check")))
expect_true("a seven-year disk set matching its record passes",
            isTRUE(fp_years_reconcile(2017:2023, SPAN7, TS, "check")))
expect_true("no record -> FALSE, not a stop: the forward-only path is checked, not corroborated",
            identical(fp_years_reconcile(c(2017L, 2020L, 2023L), NULL, TS, "check"), FALSE))
# Arm (a): the record names a year the rasters do not have. This is the arm the issue's
# acceptance criterion names, and it must say WHICH year, in which direction.
expect_stop("a raster the record names but disk lacks stops, naming the direction",
            fp_years_reconcile(c(2017L, 2023L), SPAN3, TS, "check"),
            "recorded-but-absent: 2020; present-but-unrecorded: none")
# Arm (c): the mirror, which had no guard at all before this change — a raster upstream
# wrote that the record does not describe would have been staged and published.
expect_stop("a raster on disk the record does not name stops, naming the direction",
            fp_years_reconcile(c(2017L, 2020L, 2021L, 2023L), SPAN3, TS, "check"),
            "recorded-but-absent: none; present-but-unrecorded: 2021")
expect_stop("both directions at once are both reported",
            fp_years_reconcile(c(2017L, 2021L, 2023L), SPAN3, TS, "check"),
            "recorded-but-absent: 2020; present-but-unrecorded: 2021")
expect_stop("a duplicated disk year stops", fp_years_reconcile(c(2017L, 2020L, 2020L, 2023L), SPAN3, TS, "check"),
            "two staged rasters claim the same classified year (2020)")
expect_stop("a single classified raster stops", fp_years_reconcile(2017L, SPAN3, TS, "check"),
            "found 1 classified raster(s)")
expect_stop("a year set not covering the transition span stops",
            fp_years_reconcile(c(2018L, 2020L, 2022L), NULL, TS, "check"),
            "do not cover the transition span 2017-2023 (missing 2017, 2023)")
expect_stop("a change_interval the repo does not publish stops",
            fp_years_reconcile(c(2017L, 2020L, 2023L),
                               list(years = c(2017L, 2020L, 2023L), change_interval = c(2017L, 2020L)),
                               TS, "check"),
            "records change_interval 2017-2020")
# The arms are an ordered dispatch, so their order is load-bearing for WHICH message
# prints (never for whether it refuses — every arm is unconditionally a failure). Pinned
# with an input that trips two, so a reordering shows up here rather than in a confusing
# message during a release.
expect_stop("an input tripping two arms reports the structural one first",
            fp_years_reconcile(c(2019L), SPAN3, TS, "check"), "found 1 classified raster(s)")

# --- real files -------------------------------------------------------------------------
cat("real producer files\n")
FP <- Sys.getenv("FLOODPLAINS_DATA", unset = file.path("..", "floodplains", "data"))
real <- function(area) {
  src <- file.path(FP, area, "provenance.json")
  if (!file.exists(src) || file.size(src) == 0) return(NULL)
  d <- file.path(WORK, paste0("real_", area), area); dir.create(d, recursive = TRUE, showWarnings = FALSE)
  file.copy(src, file.path(d, "provenance.json"), overwrite = TRUE)
  fp_prov_read(d)
}
# The real files are a MOVING population: floodplains#79 is converting areas from the
# three-year span to annual, one at a time (bulk went from 3 to 7 during this session's own
# work). So the fold's years cannot come from the fixture constant here — that is a witness
# pinned to a copy, and it goes stale the moment upstream re-runs.
#
# This is the one place the fold's two sides share a source, and it is bounded: these cases
# exist to prove the reader parses PRODUCER BYTES. The disk-against-record reconciliation is
# proven on synthetic input above (fp_years_reconcile) and at the real call site in
# stage_years-check.R, neither of which reads its expectation out of the record.
real_item <- function(prov, species = "co", scenario = "co_ff04") {
  sp <- fp_prov_span(prov, species, scenario, "check")
  fp_prov_item(prov, species, scenario, "check", if (is.null(sp)) YEARS else sp$years)
}
b <- real("bulk")
if (is.null(b)) skip("bulk/provenance.json reads", "not on this machine") else {
  got <- real_item(b)
  expect_true("bulk: link_* and flooded_version populated from the v2 file",
              !any(vapply(got[c("link_run_uid", "link_config_sha256", "link_sha", "link_version", "flooded_version")], is_na1, logical(1))))
  expect_equal("bulk: flooded_version is the #26 fix (0.5.0)", got$flooded_version, "0.5.0")
  # Whichever span this area is on today, both ends of the published transition window must
  # be classified — the one property of a real year set that does not depend on which
  # population floodplains#79 has converted it to yet.
  expect_true("bulk: the recorded span covers the published transition window",
              all(c(2017L, 2023L) %in% fp_prov_span(b, "co", "co_ff04", "check")$years))
  # Whether bulk's landcover step has been re-run is a fact about the file, not about this
  # script: derive it from the raw JSON and assert the reader agrees in whichever state.
  raw <- jsonlite::read_json(file.path(FP, "bulk", "provenance.json"), simplifyVector = FALSE)
  lc_present <- !is.null((raw[["landcover"]] %||% list())[["co_ff04"]])
  expect_true(paste0("bulk: landcover fields ", if (lc_present) "populated" else "NA",
                     " — matching the file's landcover section being ",
                     if (lc_present) "present" else "absent"),
              if (lc_present) !any(vapply(got[lc], is_na1, logical(1)))
              else all(vapply(got[lc], is_na1, logical(1))))
}
n <- real("neexdzii")
if (is.null(n)) skip("neexdzii/provenance.json reads", "not on this machine") else {
  got <- real_item(n)
  expect_true("neexdzii: every field non-null", !any(vapply(got, is_na1, logical(1))))
  expect_equal("neexdzii: landcover_source", got$landcover_source, "io-lulc")
  expect_true("neexdzii: landcover_key is a sha256: string",
              grepl("^sha256:[0-9a-f]{64}$", got$landcover_key))
  expect_equal("neexdzii: landcover_item_hash is the recorded item_hash",
               got$landcover_item_hash, "sha256:c653b16d657768788957efa8a297d938e4ad4bef85538d9119e5bf3f24ed5904")
  # Pinned from the producer's file on 2026-09-02: a function of its three published
  # per-year digests and the rule above. This is the only assertion here that proves the
  # RULE rather than the reader, so it is the one worth keeping — but it is a witness
  # pinned to a copy, and floodplains#79 will re-run neexdzii onto an annual span and move
  # it. Gated on the file still being the build it was pinned from, and skipped OUT LOUD
  # otherwise, so a re-run reads as "re-take the pin" and not as "the fold broke".
  PIN_STAMP <- "2026-09-02T19:48:49Z"
  if (!identical(got$produced_datetime, PIN_STAMP)) {
    skip("neexdzii: landcover_key folds to the pinned value",
         paste0("upstream re-ran (", got$produced_datetime, " != pinned ", PIN_STAMP,
                ") — re-take the pin from the new file"))
  } else {
    expect_equal("neexdzii: landcover_key folds to the pinned value",
                 got$landcover_key, "sha256:27a0c5b649f44ed3f449820ec9c69ac96306aeccbe704ee80467d8a20fb89b04")
  }
}

unlink(WORK, recursive = TRUE)
cat("\n", N, " assertions, ", FAILS, " failed, ", SKIPPED, " skipped",
    if (is.null(n)) " — neexdzii absent: the fold was NOT proven against a producer file" else "",
    if (is.null(b)) " — bulk absent" else "",
    "\n", sep = "")
quit(status = FAILS)
