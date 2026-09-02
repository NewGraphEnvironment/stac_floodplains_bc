# fp_provenance.R — read the producer's run-provenance record (#17).
#
# The ONLY place in this repo that knows the shape of `floodplains`' provenance.json
# (NewGraphEnvironment/floodplains#33). Everything downstream — meta.json's field names,
# the `nge:` STAC properties, the NGE_ GDAL tags, the validators — uses this repo's own
# names, so an upstream rename lands here and nowhere else.
#
# Sourced by 01_stage.R alongside fp_gpkg.R.
#
# Upstream shape (floodplains/scripts/floodplain_lcc/fp_provenance.R):
#
#   { "area", "wsg", "schema_version",
#     "network":    { "<sp><order>": { inputs, link_log, link_log_note, run } },
#     "floodplain": { "<scenario>":  { inputs, run } },
#     "landcover":  { "<scenario>":  { inputs, run } } }
#
# The three sections are written independently by three steps that may run separately
# (`run_area.R morr 3` is normal upstream), so any of them can legitimately be absent.

# 2 since floodplains#65 phase 1 (2026-09-02): every section gained `inputs_hash`, `outputs`
# and `outputs_hash` siblings, `sha_source` became a closed vocabulary, and the landcover
# digest was renamed `classified_sha256` -> `classified_content_sha256`. The map below walks
# explicit paths, so the new siblings are inert; the rename is what `landcover_key` reads.
FP_PROV_SCHEMA_VERSION <- 2L

`%||%` <- function(a, b) if (is.null(a)) b else a

# The eleven published fields, and where each one lives upstream. `section` selects which
# of the three blocks to look in; `path` is the key path within it.
#
# `link_version` comes from inputs$link$version (fp_pkg_stamp's shape), NOT from
# link_log — the log records the run, the stamp records the code that ran.
#
# `produced_datetime` is the LANDCOVER step's run timestamp. Steps run independently and
# each stamps its own, so there is no single "the run"; landcover is step 3, the last one
# to touch the transition layer the published figures are aggregated from, so its
# timestamp is the one that describes what was published.
#
# `landcover_key` is the FOLD of inputs$classified_content_sha256 (#40): the producer's
# per-year content digests over cell values plus geometry (floodplains#64), invariant to
# the writing toolchain, so one changed cell moves it and a re-written identical file does
# not. A fingerprint of what was PRODUCED. Folded to one scalar by fp_fold_year_digests()
# below, whose rule is reproducible from the published record.
#
# `landcover_item_hash` is inputs$item_hash — a hash over the RESOLVED STAC item ids. An
# identity of what was READ: io-lulc ids are <tile>-<year> with no created/updated stamp,
# so an in-place upstream re-derivation leaves it unchanged. #17 published it AS
# landcover_key until #40 measured that it cannot fail; it stays, under its own name.
#
# `fold`, where present, receives the raw leaf (never a JSON null — that is NA before the
# fold is reached) and must return a scalar or stop. It is the ONE route by which a
# non-scalar leaf is published, so the fold owns the shape assertions the scalar guard in
# fp_prov_leaf would otherwise apply.
FP_PROV_MAP <- list(
  link_run_uid         = list(section = "network",    path = c("link_log", "run_uid")),
  link_config_sha256   = list(section = "network",    path = c("link_log", "config_hash")),
  link_sha             = list(section = "network",    path = c("link_log", "link_sha")),
  link_version         = list(section = "network",    path = c("inputs", "link", "version")),
  flooded_version      = list(section = "floodplain", path = c("inputs", "flooded", "version")),
  drift_version        = list(section = "landcover",  path = c("inputs", "drift", "version")),
  produced_datetime    = list(section = "landcover",  path = c("run", "datetime_utc")),
  landcover_source     = list(section = "landcover",  path = c("inputs", "source")),
  landcover_collection = list(section = "landcover",  path = c("inputs", "collection")),
  landcover_stac_url   = list(section = "landcover",  path = c("inputs", "stac_url")),
  landcover_key        = list(section = "landcover",  path = c("inputs", "classified_content_sha256"),
                              fold = "fp_fold_year_digests"),
  landcover_item_hash  = list(section = "landcover",  path = c("inputs", "item_hash"))
)

# --- The landcover fold -----------------------------------------------------------------
# One scalar from the per-year map, by the same construction upstream uses for item_hash
# (floodplains fp_prov_stac_items): `<year>=<digest>` lines, years ascending, joined by
# "\n", then `sha256:` + sha256 of that text. So a consumer holding the producer's file
# can recompute the published value, and the value cannot be mistaken for a single year's
# digest by anyone who reads this.
#
# The years are asserted against the ITEM's published span (01_stage.R's YEARS), not
# against whatever the map happens to hold: a map missing or adding a year would fold to
# a value describing a different set of rasters than the item claims, silently. That is a
# schema break, so it stops. Every value must already be a `sha256:<64 hex>` digest.
fp_fold_year_digests <- function(x, where, years) {
  years <- sort(as.character(years))
  if (!is.list(x) || is.null(names(x)) || any(!nzchar(names(x)))) {
    stop("provenance.json ", where, ": classified_content_sha256 must be an object keyed ",
         "by year, got ", if (is.list(x)) "an unnamed list" else class(x)[1], ". A scalar ",
         "here would be a single year's digest published as the whole span's.", call. = FALSE)
  }
  got <- sort(names(x))
  if (!identical(got, years)) {
    stop("provenance.json ", where, ": classified_content_sha256 covers year(s) ",
         paste(got, collapse = ", "), " but the item publishes ", paste(years, collapse = ", "),
         ". Folding would describe a different set of rasters than the item claims.",
         call. = FALSE)
  }
  vals <- vapply(years, function(y) {
    v <- x[[y]]
    if (!is.character(v) || length(v) != 1L || !grepl("^sha256:[0-9a-f]{64}$", v)) {
      stop("provenance.json ", where, ": classified_content_sha256[", y, "] is not a ",
           "sha256:<64 hex> digest.", call. = FALSE)
    }
    v
  }, character(1))
  payload <- paste(paste0(years, "=", vals), collapse = "\n")
  paste0("sha256:", digest::digest(payload, algo = "sha256", serialize = FALSE))
}

# Sanity: the map must cover exactly the fields 01_stage.R publishes. Cheap, and it is
# what stops the two lists drifting apart silently.
stopifnot("FP_PROV_MAP does not match PROV_FIELDS" =
            setequal(names(FP_PROV_MAP), PROV_FIELDS))


# --- Read ------------------------------------------------------------------------------
# Returns NULL when the area has no provenance. That is the NORMAL state, not an error:
# floodplains#33 is forward-only, so every area modelled before it lands has none until
# it is re-run.
#
# Guards on non-empty rather than existence, mirroring the producer's own reader: a
# crashed writer can leave a zero-byte file, and an existence check would bless it.
fp_prov_read <- function(src_wsg) {
  path <- file.path(src_wsg, "provenance.json")
  if (!file.exists(path) || file.size(path) == 0) return(NULL)

  got <- tryCatch(
    jsonlite::read_json(path, simplifyVector = FALSE),
    error = function(e) stop("provenance.json at ", path, " is unreadable (",
                             conditionMessage(e), "). Refusing to publish an item whose ",
                             "provenance silently degraded to null.", call. = FALSE))

  # Pin the schema. Without this, every future upstream rename degrades to a published
  # null — which is indistinguishable from "upstream genuinely had no value", the one
  # failure this whole feature exists to make visible. One line converts that silence
  # into a refusal.
  ver <- got[["schema_version"]]
  if (!identical(as.integer(ver %||% NA_integer_), FP_PROV_SCHEMA_VERSION)) {
    stop("provenance.json at ", path, " declares schema_version ",
         if (is.null(ver)) "<absent>" else ver,
         " but this reader implements ", FP_PROV_SCHEMA_VERSION,
         ". Update scripts/fp_provenance.R rather than publishing nulls.", call. = FALSE)
  }
  # A rename leaves TWO signals: an expected key missing (ambiguous with a legitimate
  # absence) and an unrecognised sibling (never ambiguous). Everything below reads only
  # the first, which is sufficient at depth >= 2 because the parent section's presence is
  # itself evidence — but at the document root there is no parent, so `floodplain` ->
  # `floodplain_v2` would simply look like a step that had not run. Reading the second
  # signal closes that, and it is the axis the depth-based guards structurally cannot.
  known <- c("area", "wsg", "schema_version", "network", "floodplain", "landcover")
  unknown <- setdiff(names(got), known)
  if (length(unknown)) {
    stop("provenance.json at ", path, " has unrecognised top-level key(s): ",
         paste(unknown, collapse = ", "), ". A renamed section would otherwise read as ",
         "a step that had not run. Update scripts/fp_provenance.R.", call. = FALSE)
  }

  # The file is read from <wsg>/, but it also records which area it describes. Comparing
  # them costs one line and catches a file copied or written to the wrong directory, which
  # would otherwise publish another area's provenance on all eleven fields and be counted
  # as traced.
  declared <- as.character(got[["wsg"]] %||% "")
  if (nzchar(declared) && !identical(toupper(declared), toupper(basename(src_wsg)))) {
    stop("provenance.json at ", path, " declares wsg '", declared,
         "' but was read from '", basename(src_wsg), "'.", call. = FALSE)
  }
  got
}


# --- Select the sections for one published target ---------------------------------------
# This repo publishes one item per (wsg, species, scenario); upstream writes one file per
# WSG. MORR's two targets share a file, so the sections must be SELECTED, never assumed.
#
# The network section is matched on its own recorded `inputs$species`, not by rebuilding
# its key from `paste0(species, min_order)`. Two reasons, and the second is why it
# matters: the producer already states the join, so re-deriving it duplicates a fact; and
# every config/<wsg>/area.yml on disk today has min_order 3, so a derivation and a
# hardcoded "3" are indistinguishable — a test of it could not fail.
fp_prov_sections <- function(prov, species, scenario, where = "") {
  if (is.null(prov)) return(list(network = NULL, floodplain = NULL, landcover = NULL))

  # `[[` throughout, never `$`: `$` PARTIAL-matches on a list, so an upstream `inputs_v2`
  # would silently satisfy `$inputs` — in the one file whose job is making a rename loud.
  netall <- prov[["network"]] %||% list()

  # Check the SHAPE of every present section BEFORE matching on it. Without this, a
  # renamed `inputs` makes the filter match nothing, and "matched nothing" is returned as
  # NULL — which publishes four silent nulls indistinguishable from the normal
  # forward-only absence. That is the same defect the leaf-level guard below exists to
  # prevent, one level up: filtering on a key that has been renamed cannot distinguish
  # "no section for this species" from "every section has an unrecognised shape".
  #
  # After this loop, an empty match can ONLY mean step 1 has not been run for this
  # species, which is a legitimate partial state (the producer's three steps run
  # independently) and correctly yields nulls.
  for (nm in names(netall)) {
    s <- netall[[nm]]
    if (!is.list(s) || !("inputs" %in% names(s)) ||
        !is.list(s[["inputs"]]) || !("species" %in% names(s[["inputs"]]))) {
      stop("provenance.json ", where, ": network section '", nm, "' has no ",
           "inputs$species. This is a schema break, not an absence — matching on a ",
           "renamed key would publish nulls that read exactly like 'this species was ",
           "not modelled'. Update scripts/fp_provenance.R.", call. = FALSE)
    }
  }
  net <- Filter(function(s) identical(as.character(s[["inputs"]][["species"]]), species),
                netall)
  if (length(net) > 1L) {
    stop("provenance.json has ", length(net), " network sections for species '", species,
         "' (", paste(names(net), collapse = ", "), "). Cannot choose; refusing to guess.",
         call. = FALSE)
  }
  # floodplain/landcover are keyed by scenario_id directly, which is this repo's own
  # `scenario` (e.g. ch_ff04) — the same string both sides already agree on.
  #
  # Those keys are DATA, so unknown-key rejection cannot close them the way it closes the
  # document root: any string is a possible scenario. What is pinned is their documented
  # SHAPE. Without this, re-formatting the key (`ch_ff04` -> `ff04`) makes both lookups
  # miss and publishes seven nulls on every item at once — a uniform loss, which is
  # exactly what a cross-item check cannot see.
  #
  # A key that matches the shape but names a scenario this repo does not publish is fine
  # and must stay fine: upstream may model scenarios we never emit an item for.
  for (sect in c("floodplain", "landcover")) {
    bad <- grep("^[a-z]{2}_ff[0-9]{2}$", names(prov[[sect]] %||% list()),
                value = TRUE, invert = TRUE)
    if (length(bad)) {
      stop("provenance.json ", where, ": ", sect, " section key(s) ",
           paste(sQuote(bad), collapse = ", "), " are not scenario ids of the form ",
           "<species>_ff<NN>. A re-keyed section would otherwise publish nulls that read ",
           "like a step that had not run. Update scripts/fp_provenance.R.", call. = FALSE)
    }
  }

  list(
    network    = if (length(net)) net[[1]] else NULL,
    floodplain = (prov[["floodplain"]] %||% list())[[scenario]],
    landcover  = (prov[["landcover"]] %||% list())[[scenario]]
  )
}


# --- Pull one leaf ----------------------------------------------------------------------
# Three states, deliberately not two:
#
#   section absent                     -> NA. A legitimate absence; publish the null.
#   section present, leaf present      -> the value (or NA if it is JSON null).
#   section present, leaf ABSENT       -> stop().
#
# The third is the load-bearing one. A present section whose shape we do not recognise is
# a schema break, and letting it degrade to NA would publish a null that reads exactly
# like "upstream had no value" — so an upstream rename would be invisible for as long as
# nobody happened to compare a published property against the producer's own file.
#
# `link_log` is the documented exception: the producer sets it NULL when there is no log
# row for the area or the log is unreadable, recording why in `link_log_note`. That is a
# modelled absence, not a schema break.
fp_prov_leaf <- function(section, path, where, fold = NULL, years = NULL) {
  if (is.null(section)) return(NA)
  cur <- section
  for (i in seq_along(path)) {
    key <- path[[i]]
    # The `link_log` exception must test PRESENCE before nullity. `is.null(cur[["link_log"]])`
    # alone is TRUE for a modelled null AND for an absent or renamed key, so without the
    # `%in% names()` half it swallows the schema break it is surrounded by code to catch —
    # and the three link_log fields would publish as null, indistinguishable from the normal
    # forward-only state. Caught in review; verified against a positive control.
    if (i == 1L && identical(key, "link_log") &&
        "link_log" %in% names(cur) && is.null(cur[["link_log"]])) {
      # Modelled absence — the producer could not read link's log for this area.
      return(NA)
    }
    if (!is.list(cur) || !(key %in% names(cur))) {
      stop("provenance.json ", where, ": section is present but key '",
           paste(path, collapse = "$"), "' is missing (stopped at '", key,
           "'). This is a schema break, not an absence — publishing it as null would ",
           "be indistinguishable from upstream having no value. Update ",
           "scripts/fp_provenance.R.", call. = FALSE)
    }
    cur <- cur[[key]]
  }
  # A JSON null read back is NULL with its name retained, so it reaches here rather than
  # tripping the check above.
  if (is.null(cur)) return(NA)
  # A folded leaf: the fold owns the shape assertions from here, and returns a scalar.
  if (!is.null(fold)) return(match.fun(fold)(cur, where, years))
  # `length(cur) != 1L` alone is a PROXY for "scalar", and a single-key object satisfies
  # it: a leaf that became {"algorithm": "sha256"} would publish "sha256" as the value.
  # That is the only route in this file that publishes a WRONG value rather than a null,
  # which is strictly worse — every other guard fails toward an absence a reader can see,
  # and this one produces something that looks like a real answer and is counted as
  # traced. Reject a list outright.
  if (is.list(cur) || length(cur) != 1L) {
    stop("provenance.json ", where, ": key '", paste(path, collapse = "$"),
         "' is ", if (is.list(cur)) "an object/array" else paste0("length ", length(cur)),
         "; a published STAC property must be an atomic scalar. Publishing its sole ",
         "member would be a wrong value, not an absence.", call. = FALSE)
  }
  cur[[1]]
}


# --- The published block ----------------------------------------------------------------
# Returns exactly PROV_FIELDS, in order, each a scalar or NA. Built with a plain list, not
# `[[<-` or modifyList: both DROP a NULL member, which would turn an intended null into an
# absent key — and absence is the one thing #17 forbids.
#
# `years` is the item's published span (01_stage.R's YEARS); only folds read it.
fp_prov_item <- function(prov, species, scenario, where, years) {
  sec <- fp_prov_sections(prov, species, scenario, where)
  out <- lapply(PROV_FIELDS, function(f) {
    spec <- FP_PROV_MAP[[f]]
    v <- fp_prov_leaf(sec[[spec[["section"]]]], spec[["path"]],
                      paste0(where, " [", f, "]"), fold = spec[["fold"]], years = years)
    # NA of any type serialises to JSON null once `na = "null"` is set; normalise so the
    # emitted type cannot vary with which branch produced it.
    if (length(v) == 1L && is.na(v)) NA else v
  })
  setNames(out, PROV_FIELDS)
}
