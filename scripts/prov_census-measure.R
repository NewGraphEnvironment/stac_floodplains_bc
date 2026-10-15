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
# IT IS THE PRE-FLIGHT, NOT THE AUTHORITY. The release rebuilds anyway (#89 step 2), and
# `item_validate.py` prints the same twelve counts from the PUBLISHED items as its `census:`
# line. That line is what the literals are set from when a build exists; this script saves the
# round trip, and the two agreeing is worth more than either alone. Where they disagree, the
# build is right and the disagreement is the finding — see the pairing note below for the one
# way they can differ by construction.
#
# WHY THE STAGED COUNT EQUALS THE PUBLISHED ONE, AND THE ONE PLACE IT DOES NOT. This script
# counts a field as carried when `fp_prov_item()` returns a value for it — the meta.json level.
# `PROV_CENSUS` counts presence on the published item. They agree because item_create.py omits
# a key exactly when the staged value is null (#74) — EXCEPT through `processing:software`,
# where `link_version` and `link_sha` publish as one entry: item_create.py REFUSES an item
# carrying one without the other ("software entry is half-present") rather than writing
# `+<sha>` or a bare version. So this script can print two different counts for that pair while
# no publishable build can, and a build of such a tree stops at item_create.py rather than
# producing a census at all. The pairing is asserted where the map lives, over the pasted
# literal, by `prov_fields-check.py` — not copied into R, which would be a sixth copy of a
# publish-side fact. DUNC was in exactly that state when it was measured on 2026-10-14, until the
# Columbia run of 2026-10-15 wrote it a `link_log` (floodplains#133, open as written). The arm
# stays because the pair can empty again — and the condition is BOTH sources empty, not an
# unresolved sha: all 23 `all*` sections carry `inputs$link$sha: null` and publish anyway,
# because the log row supplies it.
#
# It needs `$FLOODPLAINS_DATA` and the config tree beside it, and nothing else: no stage, no
# writes, no network, no database, and no `drift`/`sf`/GDAL — it runs on a machine that cannot
# build. It walks the roster the way 01_stage.R does and drives this repo's own reader
# (scripts/fp_provenance.R), so the numbers come from the same code the build reads provenance
# with rather than from a second implementation of it.
#
# CAVEAT, and it is the reason the output carries its own provenance: run against a tree that
# is MID-WRITE — an upstream `run_region.R` in flight, which was the case both when #82 was
# specced AND while this script was written (a `columbia` run relabelled KOTL's record between
# two runs of it) — the numbers describe a half-finished roster. The timestamp and the
# producer's HEAD printed below are what make that visible instead of silent, and the mtime
# guard refuses the sharpest case: a raster newer than the record that describes it.
#
# WHAT IT DOES NOT CHECK, so nobody reads exit 0 as "this build will stage":
#   - it does not open the GeoPackages. Existence is checked, because the build skips a whole
#     group on a missing bundle; readability is not, because the build's key arms need
#     `sf`/GDAL (~15 s over the roster, measured) and that is the dependency separating "runs
#     where a build cannot" from "needs the build env". So a group whose bundle cannot be READ
#     is a build SKIP this script cannot see, and a target-level refusal below may belong to a
#     group the build would never have reached — conservative, which is why the refusal says
#     "stops or skips its group" rather than claiming the stronger one.
#   - it does not compare `drift_version` against the installed `drift`, which `ALLOW_DRIFT_SKEW`
#     governs, for the same reason: the comparison needs `drift` installed.
#   - it mirrors the roster walk rather than sharing one, which is the thing this repo normally
#     refuses (#90 tracks extracting an `fp_roster.R` both scripts source). Until then,
#     `prov_fields-check.py` statically asserts that 01_stage.R still contains the expressions
#     mirrored here.
# Every one of those makes a real build stage FEWER items or stop outright, so this script's
# count can only sit at or above what such a build publishes, and both of those are loud.

suppressPackageStartupMessages({
  library(jsonlite)
  library(yaml)
})

FLOODPLAINS_DATA <- Sys.getenv("FLOODPLAINS_DATA", unset = file.path("..", "floodplains", "data"))
CONFIG_DIR <- file.path(dirname(FLOODPLAINS_DATA), "config")

# WSG_ONLY reduces 01_stage.R to one group (`01_stage.R:166-177`) and this script reads the
# whole roster, so a shell that exported it for a smoke test would get a full-roster census
# from a tree whose build stages one item. Refused rather than reported: the asymmetry is
# invisible in the output, and the number is the thing being produced.
if (nzchar(Sys.getenv("WSG_ONLY", unset = ""))) {
  cat("NO CENSUS: WSG_ONLY is set (", Sys.getenv("WSG_ONLY"), "). 01_stage.R would stage that ",
      "one group\nwhile this script reads the whole roster, so the number would not describe ",
      "the build.\nUnset it and re-run.\n", sep = "")
  quit(status = 1)
}

# Two literals, both PARSED out of 01_stage.R and never copied: same construction as
# fp_provenance-check.R:24-30, and for the same reason — a fifth copy of the field list is what
# #74 spent its review rounds avoiding, and a census taken over a copied vector would silently
# stop counting a field the build still publishes. `TRANSITION_SPAN` is read the same way
# because `fp_years_reconcile()` needs it, and a copied `c(2017L, 2023L)` here would be the
# same defect in the other literal this repo keeps deliberately hardcoded.
stage_exprs <- parse(file.path("scripts", "01_stage.R"))
stage_literal <- function(name) {
  hit <- vapply(stage_exprs, function(e) is.call(e) && identical(e[[1]], as.name("<-")) &&
                  identical(e[[2]], as.name(name)), logical(1))
  if (sum(hit) != 1L) {
    stop("01_stage.R: expected exactly one top-level `", name, " <- ...`, found ", sum(hit),
         call. = FALSE)
  }
  eval(stage_exprs[[which(hit)]])
}
PROV_FIELDS <- stage_literal("PROV_FIELDS")
TRANSITION_SPAN <- stage_literal("TRANSITION_SPAN")
source(file.path("scripts", "fp_provenance.R"))

# --- What produced this census ----------------------------------------------------------
# A census printed without these is a number with no date, which is the state #75 found the
# literals in. Read from the PRODUCER tree, not this one: the question a re-taken literal needs
# answered is which upstream run the numbers describe. Both `describe` and the short sha,
# because `--always` yields the tag alone when HEAD sits on one.
#
# system2(stdout = TRUE) WARNS rather than raising on a non-zero exit and returns what it got,
# so the status is read off the result. A copied data tree, and the sandboxes this script is
# proven in, are not git repositories at all — a stated outcome, not a failure.
git_stamp <- function(dir) {
  if (!dir.exists(dir)) return("not present")
  one <- function(args) {
    out <- suppressWarnings(system2("git", c("-C", dir, args), stdout = TRUE, stderr = FALSE))
    if (!is.null(attr(out, "status")) || !length(out)) NA_character_ else out[1]
  }
  d <- one(c("describe", "--tags", "--always", "--dirty"))
  h <- one(c("rev-parse", "--short", "HEAD"))
  if (is.na(d) && is.na(h)) return("not a git tree")
  paste0(d, " (", h, ")")
}

allow_skipped <- tolower(Sys.getenv("ALLOW_SKIPPED", unset = "")) %in% c("1", "true", "yes")
cat("provenance census — a MEASUREMENT, not a gate\n")
cat("  measured           ", format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), "\n", sep = "")
cat("  FLOODPLAINS_DATA   ", normalizePath(FLOODPLAINS_DATA, mustWork = FALSE), "\n", sep = "")
cat("  producer           ", git_stamp(dirname(FLOODPLAINS_DATA)), "\n", sep = "")
cat("  reader             scripts/fp_provenance.R, schema_version ", FP_PROV_SCHEMA_VERSION,
    "; transition span ", paste(TRANSITION_SPAN, collapse = "-"), "\n", sep = "")
cat("  ALLOW_SKIPPED      ", if (allow_skipped) "set" else "unset", "\n", sep = "")

# --- The roster -------------------------------------------------------------------------
# Every config/regions/*.yml contributes its watershed_groups, exactly as 01_stage.R:135-160
# resolves them. `[[` and never `$`: `$watershed_groups` PARTIAL-MATCHES a retired roster key,
# so a region file carrying only `watershed_groups_retired:` would put whole retired groups
# into this census (measured, 01_stage.R:138-143).
region_files <- list.files(file.path(CONFIG_DIR, "regions"), pattern = "\\.yml$",
                           full.names = TRUE)
if (!length(region_files)) {
  cat("\nNO CENSUS: no region config at ", file.path(CONFIG_DIR, "regions"),
      " — set $FLOODPLAINS_DATA\nto the producer's data directory.\n", sep = "")
  quit(status = 1)
}
wsgs <- character(0)
no_region <- character(0)
for (rf in region_files) {
  rc <- yaml::read_yaml(rf)
  # A region file with no `region:` STOPS the build (01_stage.R:148-151), because the field
  # becomes a published meta.json property. Recorded rather than raised, so one bad file does
  # not cost the walk — and a recorded failure is what suppresses the census.
  if (is.null(rc[["region"]]) || !nzchar(rc[["region"]])) {
    no_region <- c(no_region, basename(rf))
    next
  }
  wsgs <- union(wsgs, tolower(rc[["watershed_groups"]]))
}

# --- Walk it ----------------------------------------------------------------------------
# The build's SELECTION, in the build's ORDER, which is the one deviation from #82's spec and
# is load-bearing rather than tidy. 01_stage.R's "no rasters" skip (:380) sits ABOVE its first
# fp_prov_* call (:380), so a target with no rasters never reaches the reader. A rostered target
# sits in exactly that state whenever its group's config is converted ahead of its run: three
# did at 2026-10-15T17:37Z (`kotl`, `larl`, `sloc`, declaring `all_ff04` over records holding
# only `bt_ff04`), one did at 18:33Z and none at 18:38Z, as the Columbia run landed group by
# group. Walking the roster in the spec's order raises on each of them, printing NO census on a
# tree a build is perfectly happy with; read rather than skipped, they would also contribute
# part of a record and move the floor to a number no build of that tree can produce. The count
# is dated because it moves hourly during an upstream run — the state is what is permanent.
#
# A skip is therefore not a failure. It is recorded, named, and reported: the census then
# describes exactly the set a build of this tree stages, which is the set the literals have to
# match.
counts <- setNames(integer(length(PROV_FIELDS)), PROV_FIELDS)
absences <- list()           # per staged item: the fields it carries no value for
staged <- character(0)
year_unchecked <- character(0)  # staged items whose year set had no record to check it against
skips <- character(0)        # display lines
failures <- character(0)     # display lines, each carrying the reader's own message
# Counted per ITEM, not inferred as roster minus staged: a skip or a read failure can land on a
# whole GROUP (a missing bundle, an unreadable record) or on one TARGET, and the subtraction is
# only right while every skip happens to be a target, which is the case for every skip this
# roster can produce until an `area.yml` carries a `targets:` block again. The identity is asserted before any
# number is printed.
n_targets <- 0L
n_skipped <- 0L
n_failed <- 0L
no_roster <- character(0)

for (wsg in wsgs) {
  area_yml <- file.path(CONFIG_DIR, wsg, "area.yml")
  if (!file.exists(area_yml)) {
    # The one group-level state whose targets cannot be known, so it is in neither count.
    skips <- c(skips, paste0(toupper(wsg), "  no area.yml at ", area_yml))
    no_roster <- c(no_roster, toupper(wsg))
    next
  }
  area <- yaml::read_yaml(area_yml)
  # `area[["targets"]]`, never `area$targets`: the producer is mid-way through retiring target
  # blocks, and `$` returns a `targets_retired:` block — which would count items nobody
  # publishes (measured, 01_stage.R:217-222).
  targets <- area[["targets"]]
  if (is.null(targets)) {
    targets <- list(list(species = area[["species"]], scenario = area[["primary_scenario"]]))
  }
  n_targets <- n_targets + length(targets)
  # The ids a group-level skip or failure takes down with it. Named on the line, because a
  # count that does not say which items it is about cannot be reconciled with a build log.
  target_ids <- vapply(targets, function(t) {
    sc <- if (is.list(t)) t[["scenario"]] else NULL
    if (is.character(sc) && length(sc) == 1L && !is.na(sc) && nzchar(sc))
      paste0(wsg, "_", sc) else paste0(wsg, "_<no scenario>")
  }, character(1))

  src_wsg <- file.path(FLOODPLAINS_DATA, wsg)

  # One record per WSG upstream, so read once and select per target. NULL is the normal
  # forward-only state (floodplains#33 is forward-only), not a failure — every area modelled
  # before it carries none until it is re-run, and those items are exactly what the floor's
  # denominator counts. A RAISE is the other thing entirely: unreadable JSON, or a
  # schema_version this reader does not implement (fp_provenance.R:147-166 draws the line).
  #
  # ABOVE the bundle arm, because 01_stage.R reads the record at :233 and skips on a missing
  # bundle at :251 — the reverse of this script's first draft, where a group with a broken
  # record AND no bundles was a recorded skip with a pasteable census while the build stops on
  # it outright. The order is only worth mirroring if it is mirrored where the two dispositions
  # differ, and this pair is exactly that place.
  wsg_prov <- tryCatch(fp_prov_read(src_wsg),
                       error = function(e) structure(conditionMessage(e), class = "fp_failed"))
  if (inherits(wsg_prov, "fp_failed")) {
    failures <- c(failures, paste0(toupper(wsg), " [", paste(target_ids, collapse = ", "), "]: ",
                                   as.character(wsg_prov)))
    n_failed <- n_failed + length(targets)
    next
  }

  # Both bundles, existence only (01_stage.R:250-256). Absent, the build skips the whole group,
  # so none of its targets is in the census either.
  gpkg_src <- file.path(src_wsg, c("floodplain.gpkg", "floodplain_landcover.gpkg"))
  missing_gpkg <- gpkg_src[!file.exists(gpkg_src)]
  if (length(missing_gpkg)) {
    skips <- c(skips, paste0(toupper(wsg), "  no ",
                             paste(basename(missing_gpkg), collapse = " / "), " at ", src_wsg,
                             " — ", paste(target_ids, collapse = ", ")))
    n_skipped <- n_skipped + length(targets)
    next
  }

  for (tgt_i in seq_along(targets)) {
    tgt <- targets[[tgt_i]]
    # The same two assertions 01_stage.R:328-353 makes where the roster is read, because every
    # downstream symptom is quiet: `paste0(wsg, "_", NULL)` is "bulk_", not an error.
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
      n_failed <- n_failed + 1L
      next
    }
    species <- tgt[["species"]]
    scenario <- tgt[["scenario"]]
    item_id <- paste0(wsg, "_", scenario)

    src_rasters <- file.path(src_wsg, "rasters", scenario)
    # The DIRECTORY, and only the directory, is the skip (01_stage.R:380). A directory that
    # exists holding none or one `classified_*.tif` does NOT skip in the build: it reaches
    # fp_years_reconcile(), which stops ("needs at least two classified years"), and 01_stage.R
    # has no per-area tryCatch — so the build stops. Treating that as a skip here would print a
    # census for a tree that cannot build, which is the direction this whole script argues
    # against. It goes to the reader arms below instead, and refuses there.
    if (!dir.exists(src_rasters)) {
      skips <- c(skips, paste0(item_id, "  no rasters/", scenario, "/ at ", src_wsg))
      n_skipped <- n_skipped + 1L
      next
    }

    # The build's own call order, so the first refusal an operator sees here is the one the
    # build would show them: fp_prov_span (:396) -> years (:402) -> fp_years_reconcile (:410)
    # -> fp_prov_rasters_current (:422) -> fp_prov_item (:670).
    #
    # `years` is ANCHORED at both ends (01_stage.R:402). list.files(pattern =) is an unanchored
    # regex and every source raster directory carries a `classified_<yyyy>.tif.aux.xml` sidecar
    # beside each `.tif`, so `classified_[0-9]{4}\\.tif` would match both and count the year
    # twice. It is also the one argument fp_prov_item() needs that the record does not supply:
    # it feeds the `landcover_key` fold, which asserts the record's per-year digests against
    # the span the item publishes — so the two sides of that fold keep two different producers,
    # here as in the stage.
    got <- tryCatch({
      span_rec <- fp_prov_span(wsg_prov, species, scenario, item_id)
      years <- sort(as.integer(sub("^classified_([0-9]{4})\\.tif$", "\\1",
                                   list.files(src_rasters,
                                              pattern = "^classified_[0-9]{4}\\.tif$"))))
      checked <- fp_years_reconcile(years, span_rec, TRANSITION_SPAN, item_id)
      raster_paths <- file.path(src_rasters,
                                c(sprintf("classified_%d.tif", years), "transition.tif"))
      fp_prov_rasters_current(src_wsg, raster_paths, wsg_prov, species, scenario, item_id)
      # `transition.tif` is the one source raster nothing above can miss for us.
      # fp_prov_rasters_current() filters to `file.exists()` (fp_provenance.R:589), so an
      # absent one is silently not mtime-checked, and the classified set came from
      # list.files() so it exists by construction. 01_stage.R:443 stops the build on it
      # ("Missing source raster"), which is why a target without one must not be counted as
      # staged. Placed here because that stop sits BETWEEN the build's rasters_current call
      # (:422) and its fp_prov_item call (:670).
      absent <- raster_paths[!file.exists(raster_paths)]
      if (length(absent)) {
        stop("Missing source raster: ", paste(absent, collapse = ", "),
             " — 01_stage.R stops the build on this.", call. = FALSE)
      }
      list(prov = fp_prov_item(wsg_prov, species, scenario, item_id, years),
           year_checked = isTRUE(checked))
    }, error = function(e) structure(conditionMessage(e), class = "fp_failed"))
    if (inherits(got, "fp_failed")) {
      failures <- c(failures, paste0(item_id, ": ", as.character(got)))
      n_failed <- n_failed + 1L
      next
    }

    staged <- c(staged, item_id)
    if (!got$year_checked) year_unchecked <- c(year_unchecked, item_id)
    carried <- !vapply(got$prov, function(v) length(v) == 1L && is.na(v), logical(1))
    counts <- counts + as.integer(carried)
    absences[[item_id]] <- PROV_FIELDS[!carried]
  }
}

# --- Refuse, rather than print a census that is short for any other reason --------------
# Not a heuristic that can be softened later. 01_stage.R has NO per-area tryCatch, so a reader
# raise on a would-stage target means THE BUILD STOPS — there is no build to take a census of,
# and a census over the survivors describes nothing that will ever be published. The tryCatch
# above is there to collect every failure in one pass, not to tolerate any.
if (length(no_region)) {
  failures <- c(failures, paste0("config/regions/", no_region,
                                 ": no `region:` field — 01_stage.R stops on this"))
}
if (length(failures)) {
  # "stops or skips the group", not "stops": 01_stage.R SKIPS a group whose bundle it cannot
  # READ (:265-275, above the target loop), and this script does not open the bundles — so a
  # target-level failure here can belong to a group the build would have skipped before
  # reaching it, and the refusal is then conservative rather than a description of the build.
  # Both halves are live states and they coincide during exactly the upstream-run-in-flight
  # condition this script carries a timestamp for, so the message must not claim the stronger
  # one. Refusing either way is right: the census would be of a set nobody can reconstruct.
  cat("\nNO CENSUS: ", length(failures), " read(s) failed. A build of this tree stops on the ",
      "first of them\nor skips its group, so any count printed here would describe nothing ",
      "that gets published.\n", sep = "")
  for (f in failures) cat("  - ", f, "\n", sep = "")
  cat("\nFix the record upstream (or this reader, if the producer's shape moved) and re-run.\n")
  quit(status = 1)
}

if (length(skips)) {
  cat("\nWARNING: ", length(skips), " rostered group(s)/target(s) would not stage:\n", sep = "")
  for (s in skips) cat("  ", s, "\n", sep = "")
  # ALLOW_SKIPPED waives the PARTIAL_STAGE marker and NOTHING ELSE. In particular it does not
  # waive release step 0's live-vs-build comparison, which refuses a build missing any live
  # item, nor `EXPECTED_DEPRECATED`. Saying "ALLOW_SKIPPED=1 makes this releasable" would be
  # an over-promise about the one interlock with no rollback behind it.
  cat("A full release from this tree is PARTIAL. ALLOW_SKIPPED=1 waives the PARTIAL_STAGE\n",
      "marker and nothing else — not step 0's refusal of a build missing a live item.\n",
      "Any census below is of the set a build of THIS tree stages.\n", sep = "")
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

# Every rostered target is accounted for exactly once before a number is printed. A group-level
# skip or failure contributes its whole target list, so this is the arm that would catch the
# accounting silently losing items the first time a group declares two targets again.
if (n_targets != length(staged) + n_skipped + n_failed) {
  cat("\nNO CENSUS: ", n_targets, " rostered target(s) but ", length(staged), " staged + ",
      n_skipped, " skipped + ", n_failed, " failed. This script lost track of an item, so ",
      "its\ncounts cannot be trusted.\n", sep = "")
  quit(status = 1)
}
# And no two of them are the same item. `absences` is keyed by item id, so two targets of one
# group declaring the same `scenario` would increment `counts` twice while overwriting one
# `absences` entry — the floor counting the item once and the census twice, with the identity
# above still satisfied. 01_stage.R would stage the second over the first in the same
# directory; neither is a state to publish a number from.
if (anyDuplicated(staged) || length(absences) != length(staged)) {
  cat("\nNO CENSUS: ", length(staged), " staged target(s) but ", length(absences),
      " distinct item id(s)", if (anyDuplicated(staged))
        paste0(" — repeated: ", paste(unique(staged[duplicated(staged)]), collapse = ", ")) else "",
      ".\nTwo targets of one group declare the same scenario, so the census counts an item ",
      "twice.\n", sep = "")
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
if (length(year_unchecked)) {
  # The same shape of number 01_stage.R prints for this state, and the reason
  # fp_years_reconcile() is called here at all: these items took their year set from the disk
  # with no record to assert it against.
  cat(length(year_unchecked), " of ", length(staged),
      " staged item(s) took their classified year set from disk, unchecked: ",
      paste(year_unchecked, collapse = ", "), "\n", sep = "")
}

# --- Paste-ready, naming every destination ---------------------------------------------
# All three, in one block, because they are re-taken together and nothing else joins them: the
# floor, the per-field census, and prov_fields-check.py's fixture populations. #75 found two of
# the three stale; a block printing only the one being asked for would leave the others exactly
# as findable as they were then.
#
# At column 0, because both destinations are read MECHANICALLY and an indented copy is broken
# in two different ways: catalogue_release-check.sh greps the floor with an anchored
# `^PROVENANCE_FLOOR=`, and prov_fields-check.py's `literal()` walks item_validate.py's
# module-level assignments, where an indented `PROV_CENSUS = {` is an IndentationError.
cat("\n--- paste these, in the one commit that gets tagged ---\n")
cat("# scripts/catalogue_release.sh\n")
cat("PROVENANCE_FLOOR=", n_any, "\n", sep = "")
cat("# scripts/item_validate.py\n")
cat("PROV_CENSUS = {\n")
for (f in PROV_FIELDS) cat('    "', f, '": ', counts[[f]], ",\n", sep = "")
cat("}\n")
# Byte-identical in format to item_validate.py's own `census:` line, so comparing this script's
# pre-flight against the build's output is a diff rather than two tables read side by side.
cat("# compare with item_validate.py's own line on the build:\n")
cat("census: ", paste(sprintf("%s %d", PROV_FIELDS, counts[PROV_FIELDS]), collapse = ", "),
    "\n", sep = "")
# The fixture's populations are the distinct ABSENCE PATTERNS, not the per-field counts: it
# builds items, and an item is either whole, short of a field, or short of a section. Grouped
# and named, so the fixture can be rewritten from this — the populations
# prov_fields-check.py carries are a fact about the catalogue, not a constant. It keeps an
# all-absent item whatever this says, because the NGE_PROVENANCE_NULL and conditional-extension
# arms live only in that population.
cat("# scripts/prov_fields-check.py — fixture populations\n")
patterns <- vapply(absences, function(a) if (length(a)) paste(a, collapse = "+") else "",
                   character(1))
for (p in unique(patterns)) {
  ids <- names(patterns)[patterns == p]
  label <- if (!nzchar(p)) paste0("with all ", length(PROV_FIELDS))
           else if (length(absences[[ids[1]]]) == length(PROV_FIELDS)) "with none at all"
           else paste0("missing ", gsub("+", " + ", p, fixed = TRUE))
  cat("#   ", length(ids), " item(s) ", label, ": ", paste(ids, collapse = ", "), "\n", sep = "")
}
quit(status = 0)
