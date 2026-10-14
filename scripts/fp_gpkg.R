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
#
# A MULTI-LAYER file is inside the guarantee, measured 2026-10-14 for #80: one
# `vectortranslate` call writing five UFRA layers (one of them aspatial) into an
# absent file gave md5 048bd83e… on two builds 1.3 s apart, and DIFFERED with the
# pin unset. That is the same "absent file" case as above, not the excluded one —
# gpkg_copy_layers() passes every layer to a SINGLE call, so there is no append
# into an existing file at any point. A looped `-append` per layer also measured
# reproducible, but it is a second route to the same bytes-by-a-different-path and
# is not used; if it is ever reintroduced, its bytes differ from the one-call form.

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

# --- Item-scoped bundles (#80) ---------------------------------------------------------
# The two upstream bundles (`floodplain.gpkg`, `floodplain_landcover.gpkg`) hold every
# target a group has ever been modelled for, and upstream keeps the retired ones on disk
# until NewGraphEnvironment/floodplains#131 prunes them. Copying such a bundle whole
# publishes another target's floodplain inside this item's own assets — BULK's coho
# floodplain and coho transition inside `bulk_all_ff04` — which is what #76 exists to
# prevent at the catalogue level, happening inside a single item. So staging WRITES these
# two, selecting by the layer's own item key rather than by its name.

# The columns floodplains#30 backfills onto every layer of both bundles. Measured
# 2026-10-14 over all 24 upstream area dirs: all 276 layers carry all three, each with
# exactly ONE distinct value, no NULLs and no zero-row layers (246 `features` + 30
# `attributes`). So both refusing statuses below are defensive rather than live — which is
# why they refuse instead of reporting: a silent loss of the key would make every layer
# unattributable and every own set empty, and a build that published that outcome as a
# census line is the one direction with no rollback.
GPKG_ITEM_KEY <- c("wsg", "species", "scenario")

#' Read the item key of every layer in a GeoPackage.
#'
#' One row per layer, in `st_layers()` order, with `status`:
#'   "ok"     — all three key columns present, exactly one distinct value each
#'   "nokey"  — at least one key column absent
#'   "multi"  — 0 or >1 distinct key rows, so no single item can claim the layer
#' A zero-row layer lands in "multi" deliberately: it carries no evidence of whose it is,
#' and the alternative is to drop it, which is the direction that ships.
#'
#' Read once per GROUP, not once per target: the bundles are group-level files, and the
#' per-group census ("which layers match no target at all") needs every target's verdict
#' against one reading of the same table.
gpkg_layer_keys <- function(src) {
  layers <- sf::st_layers(src)$name
  # Named explicitly, because the data.frame() below would otherwise raise "arguments imply
  # differing number of rows: 0, 1" — R recycles a length-1 column against a length-0 one
  # rather than yielding a 0-row frame (code-check-r.md) — and that message names neither the
  # file nor the condition. The message says st_layers() and not gpkg_contents, because that
  # is where this list came from and the two differ: GDAL lists tables gpkg_contents does not
  # register (`layer_styles` is one, verified on a styled file). This arm has NOT been fired —
  # dropping the last table makes GDAL refuse to open the file at all — so it is a cheap
  # precondition that refuses rather than passes, not a tested guard.
  if (!length(layers)) {
    stop("gpkg_layer_keys: st_layers() reports no layers in ", src, call. = FALSE)
  }
  # `data_type` from gpkg_contents, not from the geometry type sf reports. Two reasons, both
  # measured. A `transition_*` layer is declared `Unknown (any)` and reports an EMPTY
  # geomtype, not NA, so a geometry test calls it aspatial or not depending on which of the
  # two emptinesses it checks; and `layer_styles` (04_gpkg_style.py) gets no gpkg_contents
  # row at all, so selecting on data_type excludes it without naming it. GDAL serves the
  # table through st_read(query=) — checked.
  dt <- sf::st_read(src, quiet = TRUE,
                    query = "SELECT table_name, data_type FROM gpkg_contents")
  out <- data.frame(layer = layers, wsg = NA_character_, species = NA_character_,
                    scenario = NA_character_, status = NA_character_,
                    data_type = dt$data_type[match(layers, dt$table_name)],
                    stringsAsFactors = FALSE)
  for (i in seq_along(layers)) {
    lyr <- layers[i]
    # Two reads rather than one in a tryCatch: a missing column and a failed read are
    # different findings, and catching both as one would report a GDAL failure as an
    # unattributed layer. `layer =` is omitted because sf ignores it when `query` is given
    # and warns if both are passed. Interpolated layer names are double-quoted, as
    # test_pipeline.R already does.
    cols <- names(sf::st_read(src, quiet = TRUE,
                              query = sprintf('SELECT * FROM "%s" LIMIT 0', lyr)))
    if (!all(GPKG_ITEM_KEY %in% cols)) {
      out$status[i] <- "nokey"
      out$scenario[i] <- paste("absent:", paste(setdiff(GPKG_ITEM_KEY, cols), collapse = "/"))
      next
    }
    k <- sf::st_read(src, quiet = TRUE,
                     query = sprintf('SELECT DISTINCT wsg, species, scenario FROM "%s"', lyr))
    if (nrow(k) != 1L) {
      out$status[i] <- "multi"
      out$scenario[i] <- paste0(nrow(k), " distinct key row(s)")
      next
    }
    out$wsg[i] <- k$wsg[1]
    out$species[i] <- k$species[1]
    out$scenario[i] <- k$scenario[1]
    out$status[i] <- "ok"
  }
  out
}

#' Which layers of a read key table belong to one item.
#'
#' `scenarios` is the SET of scenario values the item publishes, not a single value, and
#' that is a property of the data rather than a looseness. `floodplain.gpkg` holds two
#' families with different scenario semantics: the `<sp>_ff02/04/06` delineations each
#' record their own flood factor (measured — layer `all_ff02` carries
#' `scenario = "all_ff02"`) and the item publishes all three, while
#' `<sp>_ff0N_by_blue_line_key` and `<sp>_ff04_by_gnis_name` are derived from ONE scenario
#' and record which. So the caller passes `c(<sp>_ff02, <sp>_ff04, <sp>_ff06, <item
#' scenario>)` there — the vector 01_stage.R already builds as `needed` — and the single
#' item scenario for `floodplain_landcover.gpkg`, every own layer of which carries the
#' item's scenario.
#'
#' Matching on species alone would be identical on today's roster (measured: the same keep
#' set in all 24 areas) and is still wrong, because every retirement so far happened to
#' change the species too. The day a group's headline moves between flood factors with the
#' species unchanged — `ch_ff04` -> `ch_ff06`, MORR's old chinook shape — a species-only
#' rule republishes the retired scenario's attributed layer. This issue, one axis down.
#'
#' `wsg` is compared case-folded: the column holds `BULK` while the roster and the item id
#' hold `bulk`. Not cosmetic — a case-sensitive compare makes every layer in the catalogue
#' foreign and every own set empty.
gpkg_own_layers <- function(keys, wsg, species, scenarios) {
  ok <- keys$status == "ok"
  hit <- ok & toupper(keys$wsg) == toupper(wsg) & keys$species == species &
    keys$scenario %in% scenarios
  keys$layer[hit]
}

#' Copy a selected set of layers from one GeoPackage into a fresh one.
#'
#' `dst` is UNLINKED, so never pass a path you still need — `stage_years-check.R` hands
#' 01_stage.R symlinks to the producer's real `.gpkg` files, and a caller that swapped the
#' arguments would delete upstream data.
#'
#' One `vectortranslate` call with the layer names as trailing positional arguments, into
#' an absent file — the case the timestamp pin makes byte-reproducible (see SCOPE above).
#' GDAL is the copier rather than an st_read/st_write round trip because it carries what a
#' round trip would have to reconstruct, all verified identical to the source 2026-10-14:
#' `gpkg_contents.data_type='attributes'` for the aspatial tables (`patch_watercourse_*`,
#' `composition_*`, which sf cannot write as such at all), the exact field types, the `fid`
#' values (1..6929 both sides on UFRA's transition layer, so a consumer joining on fid is
#' unaffected), `gpkg_extensions` and the rtree indexes.
gpkg_copy_layers <- function(src, dst, layers) {
  if (!length(layers)) {
    stop("gpkg_copy_layers: no layers requested for ", dst, call. = FALSE)
  }
  # SORTED, and this is load-bearing rather than tidiness: measured 2026-10-14, writing BULK's
  # four floodplain layers in reverse order gives a file of identical SIZE and a different md5.
  # Unsorted, every published `file:checksum` would depend on `st_layers()` order — a GDAL
  # implementation detail nothing here pins — and `gpkg_determinism-check.R`, which takes its
  # layer set from `gpkg_contents ORDER BY table_name`, would have been proving the
  # reproducibility of a file the stage does not produce.
  #
  # `method = "radix"` for the C-locale byte order: the default collates by LC_COLLATE
  # (code-check-r.md), which would make a published checksum a function of the operator's
  # locale — the same class of defect one layer down.
  layers <- sort(unique(layers), method = "radix")
  unlink(dst)
  # `-f GPKG` explicitly, and every switch BEFORE the positional layer names: GDAL 3.9+
  # parses these options with argparse, where trailing positional args are the reliable
  # place for the remainder. Guessing the driver from the extension would also work and
  # says less.
  #
  # Both conditions are captured, and BOTH have to be, because GDAL splits one failure across
  # two of them. Measured 2026-10-14: given a layer name the source does not hold,
  # `gdal_utils()` emits `GDAL Error 1: Couldn't fetch requested layer 'x'!` as an R warning
  # AND raises `gdal_utils vectortranslate: an error occured` on the non-zero
  # GDALVectorTranslate return. The raise is the useless half — it names nothing — and the
  # warning is the half that names the layer.
  #
  # So the handler must not merely muffle. A first version of this guard captured the warning,
  # muffled it, and raised AFTER the call: the raise from inside `gdal_utils()` unwound
  # `withCallingHandlers()` before that line could run, so the captured text was discarded and
  # the muffle suppressed the one place it would have printed. The operator got
  # "an error occured" and nothing else — strictly WORSE than having no handler, since R
  # otherwise prints the warning beside the error. Both halves are joined into one message
  # here instead.
  #
  # Flag-then-raise rather than a stop() inside the handler: the warning comes up through sf's
  # C++ frames, and aborting from the handler longjmps past their destructors. The nesting of
  # the two handlers does NOT matter — measured both ways, `withCallingHandlers(tryCatch(…))`
  # and `tryCatch(withCallingHandlers(…))` each capture the warning and the error. What
  # matters is that the warning is taken by a CALLING handler: a `tryCatch(warning =)` would
  # take the warning and return instead, discarding the call (code-check-r.md,
  # "tryCatch(warning = ) DISCARDS the value the expression produced"), which is the trap an
  # earlier probe in this branch actually fell into.
  gdal_warning <- NULL
  gdal_error <- NULL
  withCallingHandlers(
    tryCatch(
      sf::gdal_utils("vectortranslate", source = src, destination = dst,
                     options = c("-f", "GPKG", layers), quiet = TRUE),
      error = function(e) gdal_error <<- conditionMessage(e)),
    warning = function(w) {
      gdal_warning <<- conditionMessage(w)
      invokeRestart("muffleWarning")
    }
  )
  if (!is.null(gdal_error) || !is.null(gdal_warning)) {
    stop("gpkg_copy_layers: writing ", basename(dst), " from ", src, " failed",
         if (!is.null(gdal_error)) paste0(" — ", gdal_error),
         if (!is.null(gdal_warning)) paste0(" — ", gdal_warning),
         call. = FALSE)
  }
  # The written FILE, not the call's return value. The backstop: both signals above are
  # GDAL's own, and the 65,536-byte carcass a failed call leaves behind is what the next step
  # would hash and publish if either signal were ever downgraded. setequal() in both
  # directions — a short write and a write that gained a layer are both failures.
  written <- sf::st_layers(dst)$name
  if (!setequal(written, layers)) {
    stop("gpkg_copy_layers: ", basename(dst), " holds ", length(written), " layer(s) (",
         paste(sort(written), collapse = ", "), ") but ", length(layers),
         " were requested (", paste(sort(layers), collapse = ", "), ")", call. = FALSE)
  }
  invisible(dst)
}
