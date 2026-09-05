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
#
# Upstream stamps the CURRENT version on every read and write, so one step re-run under
# the v2 writer relabels an old file's untouched sections as v2. Such a file passes this
# pin and then STOPS at the leaf guard (a v1 landcover section has no
# classified_content_sha256), and 01_stage.R has no per-area tryCatch, so the whole stage
# stops until that area is re-run. Intended: the alternative is a skip that publishes nulls.
FP_PROV_SCHEMA_VERSION <- 2L

`%||%` <- function(a, b) if (is.null(a)) b else a

# The twelve published fields, and where each one lives upstream. `section` selects which
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
# The years are asserted against the ITEM's published span, not against whatever the map
# happens to hold: a map missing or adding a year would fold to a value describing a
# different set of rasters than the item claims, silently. That is a schema break, so it
# stops. Every value must already be a `sha256:<64 hex>` digest.
#
# That span is supplied BY THE CALLER and must stay that way (#61). 01_stage.R passes the
# set it discovered on disk, so the two sides of this comparison have two different
# producers. Reading `inputs$years` here instead — the obvious-looking simplification once
# fp_prov_span() exists — would compare one file's `years` against the same file's
# `classified_content_sha256`, written by one upstream step moments apart, and the guard
# would stop being about the rasters this item ships.
fp_fold_year_digests <- function(x, where, years) {
  if (length(years) == 0L) {
    stop("provenance.json ", where, ": the fold was given no published years — a caller ",
         "omitted the `years` argument.", call. = FALSE)
  }
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
    # A JSON null for one year (upstream writes NA when that year's raster was absent at
    # digest time) is NULL here. Named explicitly, and never `unlist()`ed: unlist drops a
    # null, and a fold over the survivors would describe two years as if they were three.
    if (is.null(v)) {
      stop("provenance.json ", where, ": classified_content_sha256[", y, "] is null — ",
           "that year's raster had no digest, so the span cannot be fingerprinted.",
           call. = FALSE)
    }
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

  # The file is read from <area>/, and it records which area it describes. Comparing them
  # costs one line and catches a file copied or written to the wrong directory, which would
  # otherwise publish another area's provenance on every field and be counted as traced.
  # `area` names the directory upstream (cfg$dir_out); `wsg` is the FWA group, which a
  # subset area shares with its parent (neexdzii declares wsg BULK). So the directory is
  # compared to `area`, and to `wsg` only for a record that carries no `area`.
  declared <- as.character(got[["area"]] %||% got[["wsg"]] %||% "")
  if (nzchar(declared) && !identical(tolower(declared), tolower(basename(src_wsg)))) {
    stop("provenance.json at ", path, " declares area '", declared,
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
  # A folded leaf: the fold asserts the input's shape and returns a scalar — and its result
  # still passes the scalar guard below, so a future fold cannot publish a list.
  if (!is.null(fold)) cur <- match.fun(fold)(cur, where, years)
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


# --- The item's temporal shape ----------------------------------------------------------
# The classified year set is a fact about the PRODUCER's run, not a contract this repo
# chose, so it is READ rather than declared (#61). Returns NULL when this target has no
# landcover section — the normal forward-only state — or a list of two integer vectors:
#
#   years           the classified span the producer says it built
#   change_interval the two-year window it cross-tabulated into the transition raster
#
# Same three-state discipline as fp_prov_leaf, and for a sharper reason here: a NULL that
# degraded from a schema break would silently route a PROVENANCED item onto the
# disk-discovery path, which has nothing to assert against — losing the one check this
# function exists to enable. So a present section with an absent or misshapen `years` stops.
#
# What this function must NOT become: the source of the year set 01_stage.R publishes.
# `landcover_key` is a fold over `classified_content_sha256`, asserted against the item's
# published years — if both sides came from here, that assertion would compare two adjacent
# keys of one file, written by one upstream step, against each other. 01_stage.R publishes
# the set discovered ON DISK and uses this one to check it, keeping two different producers
# on the two sides of the fold.
fp_prov_span <- function(prov, species, scenario, where = "") {
  lc <- fp_prov_sections(prov, species, scenario, where)[["landcover"]]
  if (is.null(lc)) return(NULL)
  inp <- lc[["inputs"]]

  # One reader for both fields: they are the same kind of thing (an integer year vector
  # upstream writes as a JSON array) and they fail the same ways.
  int_vec <- function(key, n_min) {
    if (!is.list(inp) || !(key %in% names(inp))) {
      stop("provenance.json ", where, ": the landcover section is present but has no ",
           "inputs$", key, ". This is a schema break, not an absence — degrading it to ",
           "NULL would take an unchecked year set for an item that has a record. Update ",
           "scripts/fp_provenance.R.", call. = FALSE)
    }
    v <- inp[[key]]
    # read_json(simplifyVector = FALSE) gives a LIST of scalars. Never unlist() it blind:
    # a JSON null reads as NULL and unlist DROPS it, so a record carrying a null year
    # would fold to a shorter span that looks entirely valid.
    if (!(is.list(v) || is.numeric(v))) {
      stop("provenance.json ", where, ": inputs$", key, " is ", class(v)[1],
           ", expected an array of years.", call. = FALSE)
    }
    ok <- vapply(v, function(e) is.numeric(e) && length(e) == 1L && !is.na(e) &&
                   e == round(e), logical(1), USE.NAMES = FALSE)
    if (!all(ok)) {
      stop("provenance.json ", where, ": inputs$", key, " member(s) ",
           paste(which(!ok), collapse = ", "), " are not whole numbers. A null or a ",
           "string year would otherwise be dropped or coerced silently.", call. = FALSE)
    }
    out <- sort(as.integer(unlist(v)))
    if (anyDuplicated(out)) {
      stop("provenance.json ", where, ": inputs$", key, " repeats year(s) ",
           paste(unique(out[duplicated(out)]), collapse = ", "), ".", call. = FALSE)
    }
    # The length floor is an absolute, and it replaces part of the refusal the old YEARS
    # constant used to give. A length-1 `years` is a latent CRASH rather than a refusal:
    # jsonlite's auto_unbox writes it as `{"years": 2017}`, and item_create.py's
    # `for yr in meta["years"]` then raises TypeError on an int, three steps downstream.
    if (length(out) < n_min) {
      stop("provenance.json ", where, ": inputs$", key, " has ", length(out),
           " year(s) (", paste(out, collapse = ", "), "), fewer than the ", n_min,
           " a published item needs.", call. = FALSE)
    }
    out
  }

  list(years = int_vec("years", 2L), change_interval = int_vec("change_interval", 2L))
}


# --- Are the staged rasters the ones the record describes? -----------------------------
# Upstream's step 3 writes its rasters first and stamps its landcover section last, so a
# raster NEWER than that stamp means a step in flight, or one that crashed between the two
# writes. In that state the item would publish landcover_key as a fingerprint of rasters
# other than the ones it ships, and nothing downstream could tell. Only meaningful when the
# landcover section for this target exists (no section, no fingerprint); absent rasters are
# 01_stage.R's own error. The strong form — recomputing the digest on the staged copies —
# is a follow-up (#40 review S4); this is the cheap half.
#
# The reference is the SECTION's `run$datetime_utc`, never provenance.json's mtime: every
# upstream step rewrites the whole file, so its mtime is the last writer's, and a step 1
# re-run after a crashed step 3 would have masked exactly the state this exists to catch
# (measured in review; a table of the three states is in the check script). The stamp is
# floored to the second, so the raster side is floored too — a raster written in the
# record's own second is the record's own raster.
fp_prov_rasters_current <- function(src_wsg, raster_paths, prov, species, scenario, where) {
  if (is.null(prov)) return(invisible(TRUE))
  lc <- fp_prov_sections(prov, species, scenario, where)[["landcover"]]
  if (is.null(lc)) return(invisible(TRUE))
  stamp <- lc[["run"]][["datetime_utc"]]
  rec <- if (is.character(stamp) && length(stamp) == 1L)
    as.POSIXct(stamp, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC") else NA
  if (is.na(rec)) {
    stop("provenance.json ", where, ": landcover section has no parseable run$datetime_utc ",
         "(", if (is.null(stamp)) "absent" else deparse(stamp)[1], "), so the staged rasters ",
         "cannot be checked against the record. Schema break, not an absence.", call. = FALSE)
  }
  paths <- raster_paths[file.exists(raster_paths)]
  late <- paths[floor(as.numeric(file.mtime(paths))) > as.numeric(rec)]
  if (length(late)) {
    stop("provenance.json ", where, ": ", length(late), " staged raster(s) are NEWER than the ",
         "provenance record that describes them (", paste(basename(late), collapse = ", "),
         ") — newer than the section's run stamp ", stamp, ". Either a landcover step is in ",
         "flight or crashed after writing its rasters — re-run it upstream — or this tree ",
         "was copied without preserving mtimes (rsync without -t, scp without -p, an S3 ",
         "sync), in which case copy it again with them. Not publishing a fingerprint of ",
         "bytes other than the ones shipped.", call. = FALSE)
  }
  invisible(TRUE)
}


# --- The published block ----------------------------------------------------------------
# Returns exactly PROV_FIELDS, in order, each a scalar or NA. Built with a plain list, not
# `[[<-` or modifyList: both DROP a NULL member, which would turn an intended null into an
# absent key — and absence is the one thing #17 forbids.
#
# `years` is the item's published span — the set 01_stage.R discovered on disk, never one
# read back out of `prov` (see the fold's comment above); only folds read it.
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
