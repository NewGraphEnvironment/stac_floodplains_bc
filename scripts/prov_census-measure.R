# prov_census-measure.R — PRODUCE the provenance floor and the per-field census (#82).
#
# Usage:
#   Rscript scripts/prov_census-measure.R
#
#   exit 0  a census was printed — the numbers to paste
#   exit 1  no census was printed — the read was incomplete, and the failures say where
#
# A MEASUREMENT, NOT A GATE. Every other `*-check.{R,py}` beside it asserts an expectation;
# this one produces one, which is why it is not named `-check`. A passing run says nothing
# about whether the build is correct — it says "here are the numbers a human sets".
#
# Those numbers are `PROVENANCE_FLOOR` (scripts/catalogue_release.sh), `PROV_CENSUS`
# (scripts/item_validate.py) and `prov_fields-check.py`'s fixture populations: exact literals
# a human sets, deliberately, because an expectation derived from the data cannot be
# contradicted by it (#32, #74). Nothing in this repo PRODUCED them until now, so the only
# routes were a full ~900 MB build or a throwaway script — which is how they went stale
# between releases with nothing to say so (#75 measured the gap; see CLAUDE.md).
#
# It needs `$FLOODPLAINS_DATA` and the config tree beside it, and nothing else: no stage, no
# writes, no network, no database. It walks the roster the way 01_stage.R does and drives this
# repo's own reader (scripts/fp_provenance.R), so the numbers come from the same code the build
# reads provenance with rather than from a second implementation of it.
#
# CAVEAT, and it is the reason the output carries its own provenance: run against a tree that
# is MID-WRITE — an upstream `run_region.R` in flight, which was the case when #82 was specced
# — the numbers describe a half-finished roster. The timestamp and the producer's HEAD printed
# below are what make that visible instead of silent; the mtime guard catches the sharpest
# case (a raster newer than the record describing it) and refuses.
#
# WHAT IT DOES NOT CHECK, so nobody reads exit 0 as "this build will stage". It does not open
# the GeoPackages — the build SKIPS a group whose bundle it cannot read and REFUSES a layer
# carrying no usable item key or another group's — and it does not run fp_years_reconcile().
# Every one of those makes a real build stage FEWER items or stop outright, so this script's
# count can only sit at or above what such a build publishes, and both of those outcomes are
# loud. What it does mirror is the build's SELECTION, in the build's order (see below).

suppressPackageStartupMessages({
  library(jsonlite)
  library(yaml)
})

FLOODPLAINS_DATA <- Sys.getenv("FLOODPLAINS_DATA", unset = file.path("..", "floodplains", "data"))
CONFIG_DIR <- file.path(dirname(FLOODPLAINS_DATA), "config")

# PROV_FIELDS is declared in 01_stage.R, a script that stages on source. Evaluate that one
# assignment rather than the file, so this measurement needs no upstream tree to be read and
# cannot stage. Same construction as fp_provenance-check.R:24-30, and for the same reason: a
# fifth copy of the field list is what #74 spent its review rounds avoiding, and a census
# taken over a copied list would silently stop counting a field the build still publishes.
exprs <- parse(file.path("scripts", "01_stage.R"))
is_prov <- vapply(exprs, function(e) is.call(e) && identical(e[[1]], as.name("<-")) &&
                    identical(e[[2]], as.name("PROV_FIELDS")), logical(1))
stopifnot("PROV_FIELDS assignment not found in 01_stage.R" = sum(is_prov) == 1L)
eval(exprs[[which(is_prov)]])
source(file.path("scripts", "fp_provenance.R"))

# --- What produced this census ----------------------------------------------------------
# A census printed without these is a number with no date, which is the state #75 found the
# literals in. `git describe` is read from the producer tree, not this one: the question a
# re-taken literal needs answered is which upstream run the numbers describe.
#
# system2(stdout = TRUE) WARNS rather than raising on a non-zero exit and returns the output
# so far, so the status is read off the result. A copied data tree and the sandboxes this
# script is proven in are not git repositories at all, and that is a stated outcome rather
# than a failure — the measurement does not depend on it.
git_stamp <- function(dir) {
  if (!dir.exists(dir)) return("not present")
  out <- suppressWarnings(system2("git", c("-C", dir, "describe", "--tags", "--always", "--dirty"),
                                  stdout = TRUE, stderr = FALSE))
  if (!is.null(attr(out, "status")) || !length(out)) return("not a git tree")
  out[1]
}

cat("provenance census — a MEASUREMENT, not a gate\n")
cat("  measured           ", format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), "\n", sep = "")
cat("  FLOODPLAINS_DATA   ", normalizePath(FLOODPLAINS_DATA, mustWork = FALSE), "\n", sep = "")
cat("  producer           ", git_stamp(dirname(FLOODPLAINS_DATA)), "\n", sep = "")
cat("  reader             scripts/fp_provenance.R, schema_version ",
    FP_PROV_SCHEMA_VERSION, "\n", sep = "")

# --- The roster -------------------------------------------------------------------------
# Every config/regions/*.yml contributes its watershed_groups, exactly as 01_stage.R:135-160
# resolves them. `[[` and never `$`: `$watershed_groups` PARTIAL-MATCHES a retired roster key,
# so a region file carrying only `watershed_groups_retired:` would put whole retired groups
# into this census (measured, 01_stage.R:138-143).
region_files <- list.files(file.path(CONFIG_DIR, "regions"), pattern = "\\.yml$",
                           full.names = TRUE)
if (!length(region_files)) {
  cat("\nNo region config at ", file.path(CONFIG_DIR, "regions"),
      " — set $FLOODPLAINS_DATA to the producer's data directory.\n", sep = "")
  quit(status = 1)
}
wsgs <- character(0)
for (rf in region_files) {
  rc <- yaml::read_yaml(rf)
  wsgs <- union(wsgs, tolower(rc[["watershed_groups"]]))
}

# --- Walk it ----------------------------------------------------------------------------
# The build's SELECTION, in the build's ORDER, which is the one deviation from #82's spec and
# is load-bearing. 01_stage.R's "no rasters" skip (:375) sits ABOVE its first fp_prov_* call
# (:396), so a target with no rasters never reaches the reader. Measured 2026-10-15: three
# rostered targets (kotl/larl/sloc) declare `all_ff04` while their records hold only `bt_*`,
# so reading them raises fp_prov_sections()'s own refusal — and walking the roster in the
# spec's order would print NO census on a tree a build is perfectly happy with.
#
# A skip is therefore not a failure. It is recorded, named, and reported beside a banner: the
# census still describes exactly the set a build of this tree would stage, which is the set
# the literals have to match, and such a build drops a PARTIAL_STAGE marker that refuses the
# release anyway.
counts <- setNames(integer(length(PROV_FIELDS)), PROV_FIELDS)
absences <- list()           # per staged item: the fields it carries no value for
staged <- character(0)
skips <- character(0)        # "<id or group>  <why>"
failures <- character(0)     # "<id or group>: <the reader's own message>"
# Counted, not inferred as staged + skipped: a skip can be a whole GROUP (no bundle) or one
# TARGET (no rasters), so that subtraction is only right while every skip happens to be a
# target — which it is today and will not stay. A group with no area.yml declares no targets
# this script can see at all, so it contributes to neither and is reported on its own line.
n_targets <- 0L
no_roster <- character(0)

for (wsg in wsgs) {
  area_yml <- file.path(CONFIG_DIR, wsg, "area.yml")
  if (!file.exists(area_yml)) {
    skips <- c(skips, paste0(toupper(wsg), "  no area.yml at ", area_yml))
    no_roster <- c(no_roster, toupper(wsg))
    next
  }
  area <- yaml::read_yaml(area_yml)
  # `area[["targets"]]`, never `area$targets`: the producer is mid-way through retiring
  # target blocks, and `$` returns a `targets_retired:` block — which would count items
  # nobody publishes (measured, 01_stage.R:217-222).
  targets <- area[["targets"]]
  if (is.null(targets)) {
    targets <- list(list(species = area[["species"]], scenario = area[["primary_scenario"]]))
  }
  n_targets <- n_targets + length(targets)

  src_wsg <- file.path(FLOODPLAINS_DATA, wsg)

  # Both bundles, existence only (01_stage.R:250). Absent, the build skips the whole group
  # before it reads any provenance, so the group's targets are not in the census either.
  gpkg_src <- file.path(src_wsg, c("floodplain.gpkg", "floodplain_landcover.gpkg"))
  missing_gpkg <- gpkg_src[!file.exists(gpkg_src)]
  if (length(missing_gpkg)) {
    skips <- c(skips, paste0(toupper(wsg), "  no ",
                             paste(basename(missing_gpkg), collapse = " / "), " at ", src_wsg))
    next
  }

  # One record per WSG upstream, so read once and select per target. NULL is the normal
  # forward-only state (floodplains#33 is forward-only), not a failure — every area modelled
  # before it carries none until it is re-run, and those items are exactly what the floor's
  # denominator counts. A RAISE is the other thing entirely: unreadable JSON, or a
  # schema_version this reader does not implement (fp_provenance.R:147-166 draws the line).
  wsg_prov <- tryCatch(fp_prov_read(src_wsg),
                       error = function(e) structure(conditionMessage(e), class = "fp_failed"))
  if (inherits(wsg_prov, "fp_failed")) {
    failures <- c(failures, paste0(toupper(wsg), ": ", as.character(wsg_prov)))
    next
  }

  for (tgt_i in seq_along(targets)) {
    tgt <- targets[[tgt_i]]
    # The same two assertions 01_stage.R:338-356 makes where the roster is read, because
    # every downstream symptom is quiet: `paste0(wsg, "_", NULL)` is "bulk_", not an error.
    # Recorded as a failure rather than raised, so one malformed target does not cost the
    # walk — and a failure is what suppresses the census, which is the right disposition for
    # a roster this script cannot read.
    bad_field <- NULL
    if (!is.list(tgt)) {
      bad_field <- paste0("target ", tgt_i, " is ", class(tgt)[1], ", not a mapping")
    } else {
      for (f in c("species", "scenario")) {
        v <- tgt[[f]]
        if (!is.character(v) || length(v) != 1L || is.na(v) || !nzchar(v)) {
          bad_field <- paste0("target ", tgt_i, " declares no usable `", f, "` (",
                              deparse(v)[1], ")")
          break
        }
      }
    }
    if (!is.null(bad_field)) {
      failures <- c(failures, paste0("config/", wsg, "/area.yml: ", bad_field))
      next
    }
    species <- tgt[["species"]]
    scenario <- tgt[["scenario"]]
    item_id <- paste0(wsg, "_", scenario)

    src_rasters <- file.path(src_wsg, "rasters", scenario)
    # ANCHORED at both ends (01_stage.R:402). list.files(pattern =) is an unanchored regex and
    # every source raster directory carries a `classified_<yyyy>.tif.aux.xml` sidecar beside
    # each `.tif`, so `classified_[0-9]{4}\\.tif` would match both and count the year twice.
    years <- if (dir.exists(src_rasters)) {
      sort(as.integer(sub("^classified_([0-9]{4})\\.tif$", "\\1",
                          list.files(src_rasters, pattern = "^classified_[0-9]{4}\\.tif$"))))
    } else integer(0)
    if (!length(years)) {
      skips <- c(skips, paste0(item_id, "  no classified raster at ", src_rasters))
      next
    }

    # The item's own provenance, through the reader the build uses. `years` is the one
    # argument the record does not supply: it feeds the `landcover_key` fold, which asserts
    # the record's per-year digests against the span the item publishes — so the two sides of
    # that fold keep two different producers, here as in the stage.
    #
    # fp_prov_rasters_current() first, same order as 01_stage.R:422: a raster newer than the
    # landcover section describing it is a step in flight or crashed between its two writes,
    # which is the mid-write state this script's caveat names. It refuses, and so does this.
    got <- tryCatch({
      fp_prov_rasters_current(src_wsg,
                              file.path(src_rasters,
                                        c(sprintf("classified_%d.tif", years), "transition.tif")),
                              wsg_prov, species, scenario, item_id)
      fp_prov_item(wsg_prov, species, scenario, item_id, years)
    }, error = function(e) structure(conditionMessage(e), class = "fp_failed"))
    if (inherits(got, "fp_failed")) {
      failures <- c(failures, paste0(item_id, ": ", as.character(got)))
      next
    }

    staged <- c(staged, item_id)
    carried <- !vapply(got, function(v) length(v) == 1L && is.na(v), logical(1))
    counts <- counts + as.integer(carried)
    absences[[item_id]] <- PROV_FIELDS[!carried]
  }
}

# --- Refuse, rather than print a census that is short for any other reason --------------
# The output becomes a literal that GATES releases, and a count low for any reason other than
# the data is the dangerous direction: pasted into PROVENANCE_FLOOR, it is then satisfied by a
# build that lost provenance. So one failed read costs the whole census, loudly, and the
# failures carry the reader's own messages — a suite with N refusals has N ways to exit 1, and
# only the message says which one fired.
if (length(failures)) {
  cat("\nNO CENSUS: ", length(failures), " read(s) failed, so any count printed here would be ",
      "short for a reason other than the data.\n", sep = "")
  for (f in failures) cat("  - ", f, "\n", sep = "")
  cat("\nFix the record upstream (or this reader, if the producer's shape moved) and re-run.\n")
  quit(status = 1)
}

if (length(skips)) {
  cat("\nWARNING: ", length(skips), " rostered target(s)/group(s) would not stage:\n", sep = "")
  for (s in skips) cat("  ", s, "\n", sep = "")
  cat("A full release from this tree is refused by the PARTIAL_STAGE interlock unless\n",
      "ALLOW_SKIPPED=1. Any census below is of the set a build of THIS tree stages.\n", sep = "")
}

# Nothing staged is not a census of zero; it is a measurement that did not happen. Printing
# `PROVENANCE_FLOOR=0` here and exiting 0 is the fail-toward-pass direction, and 0 is the one
# value every presence check in the publish path waves through — it was true of v1.0.0. Same
# refusal item_validate.py makes for a wrong `--base` rather than reporting `valid: 0`.
if (!length(staged)) {
  cat("\nNO CENSUS: nothing staged. A floor of 0 is a number a reader that found nothing ",
      "produces,\nand it was once true, so it cannot be told from a measurement that worked. ",
      "Check that\n$FLOODPLAINS_DATA points at a populated producer tree (it resolved to ",
      normalizePath(FLOODPLAINS_DATA, mustWork = FALSE), ").\n", sep = "")
  quit(status = 1)
}

n_any <- sum(vapply(absences, function(a) length(a) < length(PROV_FIELDS), logical(1)))
cat("\nitems on the roster: ", n_targets,
    "   staged: ", length(staged),
    "   carrying any provenance: ", n_any, "   <- PROVENANCE_FLOOR\n", sep = "")
if (length(no_roster)) {
  cat("plus ", length(no_roster), " rostered group(s) declaring no targets this script can see (",
      paste(no_roster, collapse = ", "), "), so they are in neither count above.\n", sep = "")
}
for (f in PROV_FIELDS) cat(sprintf("  %-22s %d\n", f, counts[[f]]))

# --- Paste-ready, naming every destination ---------------------------------------------
# All three, in one block, because they are re-taken together and nothing else joins them: the
# floor, the per-field census, and prov_fields-check.py's fixture populations. #75 found two of
# the three stale; a block that printed only the one being asked for would leave the others
# exactly as findable as they were then.
cat("\n--- paste these, in the one commit that gets tagged ---\n")
cat("scripts/catalogue_release.sh\n")
cat("  PROVENANCE_FLOOR=", n_any, "\n", sep = "")
cat("scripts/item_validate.py\n")
cat("  PROV_CENSUS = {\n")
for (f in PROV_FIELDS) cat('      "', f, '": ', counts[[f]], ",\n", sep = "")
cat("  }\n")
# The fixture's populations are the distinct ABSENCE PATTERNS, not the per-field counts: it
# builds items, and an item is either whole, short of one field, or short of a section. Grouped
# and named, so the fixture can be rewritten from this and the live shape read off it — the
# three populations prov_fields-check.py covers today (all twelve / only link_run_uid absent /
# none at all) are a fact about the catalogue, not a constant.
cat("scripts/prov_fields-check.py\n")
patterns <- vapply(absences, function(a) if (length(a)) paste(a, collapse = "+") else "", character(1))
for (p in unique(patterns)) {
  ids <- names(patterns)[patterns == p]
  # Three labels, not two: "with none at all" is its own population in that fixture, and
  # spelling it as every field missing in turn is unreadable at twelve fields.
  label <- if (!nzchar(p)) paste0("with all ", length(PROV_FIELDS))
           else if (length(absences[[ids[1]]]) == length(PROV_FIELDS)) "with none at all"
           else paste0("missing ", gsub("+", " + ", p, fixed = TRUE))
  cat("  ", length(ids), " item(s) ", label, ": ", paste(ids, collapse = ", "), "\n", sep = "")
}
quit(status = 0)
