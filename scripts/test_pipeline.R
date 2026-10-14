# test_pipeline.R — single-WSG smoke test of stage -> tag -> COG -> build -> validate.
#
# Runs ONE watershed group end-to-end: stages it, tags the staged rasters, builds COGs,
# builds the
# STAC JSON and validates it through the same gate a release uses. Use after changes
# to the scripts, the floodplains data layout, or the STAC schema.
#
# It cannot touch S3 or the live catalog — none of the scripts it calls make network
# writes; publishing is catalogue_release.sh alone. It also leaves data/raw/PARTIAL_STAGE
# behind (01_stage.R writes it for WSG_ONLY), which catalogue_release.sh refuses to
# publish past as a collection — the one-group tree can only go out one item at a time,
# via `catalogue_release.sh --only <item_id>`, which never touches collection.json (#36).
#
#   Rscript scripts/test_pipeline.R            # defaults to UFRA
#   WSG=necr Rscript scripts/test_pipeline.R   # any rostered WSG
#   WSG=bulk Rscript scripts/test_pipeline.R   # whole-network group: species `all`, 7-year span
#
# Requires: R (sf/yaml/jsonlite/drift), uv (Python env from pyproject.toml/uv.lock —
# `uv run` auto-syncs it), and the source data under $FLOODPLAINS_DATA. No AWS creds needed.

library(jsonlite)
library(yaml)
library(sf)   # explicit: the gpkg attribute checks below must not rely on 01_stage.R's attach

wsg <- tolower(Sys.getenv("WSG", unset = "ufra"))

message("=== SMOKE TEST: ", toupper(wsg), " (local only, no S3) ===\n")

# --- 01 STAGE (restricted to the one WSG) ---------------------------------
# Clear WSG_ONLY right after so a later interactive full-publish in the same session
# isn't silently restricted to this WSG.
Sys.setenv(WSG_ONLY = wsg)
source("scripts/01_stage.R")
Sys.unsetenv("WSG_ONLY")

# --- 02 TAG ---------------------------------------------------------------
# Before the COG conversion, not after (#33): tagging a finished COG in place moves
# its main IFD to the end of the file.
message("\n=== 02: TAG ===")
if (system("uv run python scripts/02_raster_tag.py") != 0) {
  stop("02_raster_tag.py failed")
}

# --- 03 COG ---------------------------------------------------------------
# Python since #34/#35: the class-label RAT only embeds in the .tif through a GDAL 3.12+
# CreateCopy, and terra links 3.8.5. system() returns a status rather than raising, so the
# check is explicit — without it a failed COG step would fall through to the STAC build.
message("\n=== 03: COG ===")
if (system("uv run python scripts/03_cog.py") != 0) {
  stop("03_cog.py failed")
}

# --- 04 STYLE -------------------------------------------------------------
# Embeds the layer_styles rows so the published GeoPackages open already styled.
# Before the STAC build: item_create.py hashes every asset, and a style written
# afterwards would publish a checksum over bytes that no longer match the file.
message("\n=== 04: STYLE ===")
if (system("uv run python scripts/04_gpkg_style.py") != 0) {
  stop("04_gpkg_style.py failed")
}

# --- BUILD ----------------------------------------------------------------
message("\n=== BUILD STAC JSON ===")
if (system("uv run python scripts/item_create.py") != 0) {
  stop("item_create.py failed")
}

# --- VALIDATE -------------------------------------------------------------
# The same gate catalogue_release.sh runs, so the smoke test exercises it rather
# than a separate code path. --expect defaults to the staged meta.json count, which
# is the number of targets the group's area.yml declares, so a partially-built group still fails.
message("\n=== VALIDATE ===")
# `--partial`, for the reason catalogue_release.sh passes it under --only (#26): the
# deprecation check's last arm asks about ids ABSENT from the tree, and a one-group tree
# not holding them is the normal state of a subset, not a defect.
#
# Without it this smoke test could not run for ANY group — not even mcgr or pine, since
# EXPECTED_DEPRECATED names two items and a one-group tree is always missing at least one
# of them. Measured on this branch and on main, where `WSG=ufra` fails identically.
#
# Every per-item arm still runs; #61's own unused-year-set arm is dropped for the same
# reason, and for the same reason it is safe to drop.
if (system("uv run python scripts/item_validate.py --partial") != 0) {
  stop("item_validate.py failed — the built STAC JSON is invalid")
}

# --- Assertions -----------------------------------------------------------
# A WSG may now stage one OR MORE items — one per declared (species, scenario) target in
# area.yml (fallback: a single {species, primary_scenario} item). Item dirs and asset paths
# are item-id-keyed: data/{raw,stac}/<item_id>/.
meta_paths <- list.files(file.path("data", "raw"), pattern = "^meta\\.json$",
                         recursive = TRUE, full.names = TRUE)
if (length(meta_paths) == 0L) stop("no items staged for ", toupper(wsg))

# Expected item count = number of declared targets for this WSG (1 via fallback).
fp_data <- Sys.getenv("FLOODPLAINS_DATA", unset = "../floodplains/data")
area <- yaml::read_yaml(file.path(dirname(fp_data), "config", wsg, "area.yml"))
# `[[`, never `$`: a `targets_retired:` block upstream is partial-matched by `$targets`, and
# this count and the assertion at the end of the file would then agree with 01_stage.R's own
# partial match rather than check it (#75 round 3).
n_expected <- if (!is.null(area[["targets"]])) length(area[["targets"]]) else 1L
stopifnot("staged item count != declared targets" = length(meta_paths) == n_expected)

# isTRUE() guards the ff-area checks: a missing key yields `NULL > 0` -> logical(0), which
# stopifnot passes vacuously — isTRUE(logical(0)) is FALSE, so the test stays red until the
# staging writes all three areas.
items <- list()
for (mp in meta_paths) {
  meta <- jsonlite::read_json(mp)
  item_dir <- file.path("data", "stac", meta$item_id)
  cogs <- list.files(item_dir, pattern = "\\.tif$")
  gpkgs <- list.files(item_dir, pattern = "\\.gpkg$")
  item_json <- file.path("data", "stac", paste0(meta$item_id, ".json"))
  stopifnot(
    "staging not item-id-keyed (raw dir != item_id)" = basename(dirname(mp)) == meta$item_id,
    # Per item since #61: the classified span is a property of the item, not a constant.
    # A count alone would pass for the right number of wrong names, so the SET is compared.
    "COGs do not match the item's own year set + transition" =
      setequal(cogs, c(sprintf("classified_%d.tif", unlist(meta$years)),
                       sprintf("transition_%d_%d.tif", meta$transition_span[[1]],
                               meta$transition_span[[2]]))),
    "expected 3 gpkgs (delineation + landcover + transition)" = length(gpkgs) == 3L,
    "floodplain.gpkg not staged" = "floodplain.gpkg" %in% gpkgs,
    "floodplain_landcover.gpkg not staged" = "floodplain_landcover.gpkg" %in% gpkgs,
    "transition_vector.gpkg not staged" = "transition_vector.gpkg" %in% gpkgs,
    "item JSON not written" = file.exists(item_json),
    "floodplain_ff02_km2 not positive" = isTRUE(meta$floodplain_ff02_km2 > 0),
    "floodplain_ff04_km2 not positive" = isTRUE(meta$floodplain_ff04_km2 > 0),
    "floodplain_ff06_km2 not positive" = isTRUE(meta$floodplain_ff06_km2 > 0),
    "old floodplain_km2 still present (schema break incomplete)" = is.null(meta$floodplain_km2),
    "gross_loss_ha missing" = !is.null(meta$gross_loss_ha)
  )

  # Item-key contract (#9): upstream documents wsg/species/scenario as each being BOTH a STAC
  # property (to select items) and a gpkg column (to separate merged rows). The gpkg half is
  # asserted below; this is the STAC half. `scenario` was missing from item properties for the
  # whole life of the collection precisely because nothing here read the item JSON — every other
  # assertion in this file works off meta.json or the gpkgs, so a property absent from the
  # published item passed green. Read the built item and check the properties that actually ship.
  props <- jsonlite::read_json(item_json)$properties
  for (key in c("wsg", "species", "scenario", "region")) {
    if (!identical(props[[key]], meta[[key]])) {
      stop("item JSON property '", key, "' is ",
           if (is.null(props[[key]])) "MISSING" else paste0("'", props[[key]], "'"),
           " but meta.json says '", meta[[key]], "'")
    }
  }
  # flood_factor is derived, so assert it against the scenario rather than against meta.
  ff_expected <- as.integer(sub("^.*_ff", "", meta$scenario))
  if (!identical(as.integer(props$flood_factor), ff_expected)) {
    stop("item JSON flood_factor is ",
         if (is.null(props$flood_factor)) "MISSING" else props$flood_factor,
         " but scenario '", meta$scenario, "' implies ", ff_expected)
  }

  # Run-provenance contract (#17), under the names #74 moved it to. The publish map is
  # declared here as well — the fourth copy, and the duplication is deliberate, since a guard
  # that imports the value it checks returns identical forever. `prov_fields-check.py` pins
  # the copies in item_create.py, item_validate.py and 02_raster_tag.py to each other
  # statically; what THIS one joins is the two halves of the ferry: 01_stage.R's staged field
  # names, and what item_create.py published from them. Until #74 the two differed by a
  # prefix and this was a `sub()`; the published shape is now nine keys from twelve fields.
  `%||%` <- function(a, b) if (is.null(a)) b else a
  prov_map <- c(
    link_run_uid         = "link:run_uid",
    link_config_sha256   = "link:config_sha256",
    produced_datetime    = "processing:datetime",
    landcover_source     = "landcover:source",
    landcover_collection = "landcover:collection",
    landcover_stac_url   = "landcover:stac_url",
    landcover_key        = "landcover:key",
    landcover_item_hash  = "landcover:item_hash")
  prov_software <- list(link = c("link_version", "link_sha"),
                        flooded = "flooded_version",
                        drift = "drift_version")
  prov_fields <- c(names(prov_map), unlist(prov_software, use.names = FALSE))

  # meta.json carries every field on every item, null where the producer had none —
  # 01_stage.R writes NA, which jsonlite renders as null and reads back as a NULL element
  # whose NAME survives. So a field never staged and a field staged with no value are
  # distinguishable here, and the first is a staging bug rather than an absence.
  #
  # BOTH directions, and the second one is the point: the staged set is derived from the DATA
  # (every meta.json name that is not one of the core fields below), so a thirteenth field
  # added to 01_stage.R and to nothing else fails here. Nothing else in the repo can see that
  # — `prov_fields-check.py` joins the three publish-side copies, and fp_provenance.R's
  # stopifnot joins two staging-side ones, so this is the only guard that reads 01_stage.R's
  # output against what gets published. A subset check alone would have silently dropped it.
  meta_core <- c("wsg", "wsg_lower", "species", "scenario", "region", "item_id", "years",
                 "transition_span", "epsg", "floodplain_ff02_km2", "floodplain_ff04_km2",
                 "floodplain_ff06_km2", "gross_loss_ha", "gross_gain_ha", "net_ha",
                 "bbox_wgs84", "geometry")
  staged_prov <- setdiff(names(meta), meta_core)
  if (!setequal(staged_prov, prov_fields)) {
    stop("meta.json and this test disagree on the staged provenance field set — staged but ",
         "not declared here: ", paste(setdiff(staged_prov, prov_fields), collapse = ", "),
         "; declared here but not staged: ",
         paste(setdiff(prov_fields, staged_prov), collapse = ", "),
         ". `meta_core` is the hardcoded complement, so the first list catches BOTH a new ",
         "provenance field (add it to the map in item_create.py, item_validate.py, this ",
         "list and 02_raster_tag.py) and a new NON-provenance meta.json field, which is ",
         "published already and belongs in meta_core above.")
  }
  staged_present <- Filter(function(f) !is.null(meta[[f]]), prov_fields)

  # Since #74 an absent value OMITS its key, so the expected published key set is a function
  # of what was staged. That is what keeps this two-sided without a table of counts: a field
  # staged with a value and published nowhere fails, and a key published for a field the
  # producer had nothing for fails too. (item_validate.py's census is the other half — it
  # asks how many items carry each field, which one group cannot answer.)
  want_keys <- c(
    unname(prov_map[intersect(names(prov_map), staged_present)]),
    if (any(unlist(prov_software, use.names = FALSE) %in% staged_present)) "processing:software")
  item_keys <- grep("^(processing|link|landcover):", names(props), value = TRUE)
  if (!setequal(want_keys, item_keys)) {
    stop("meta.json and the published item disagree on the provenance keys — staged but not ",
         "published: ", paste(setdiff(want_keys, item_keys), collapse = ", "),
         "; published but not staged: ",
         paste(setdiff(item_keys, want_keys), collapse = ", "))
  }
  # The software entries are where four of the twelve fields went, so the key check above
  # cannot see them: `processing:software` is one key whether it holds three entries or one.
  want_entries <- names(Filter(function(fs) any(fs %in% staged_present), prov_software))
  item_entries <- names(props[["processing:software"]] %||% list())
  if (!setequal(want_entries, item_entries)) {
    stop("meta.json and the published item disagree on the processing:software entries — ",
         "staged but not published: ", paste(setdiff(want_entries, item_entries), collapse = ", "),
         "; published but not staged: ",
         paste(setdiff(item_entries, want_entries), collapse = ", "))
  }
  # The extension is declared iff a processing: field is published — forced by the schema,
  # whose Item branch requires at least one such field, so an item carrying none would be
  # REFUSED rather than merely over-declared.
  item_exts <- unlist(jsonlite::read_json(item_json)$stac_extensions)
  has_proc_ext <- "https://stac-extensions.github.io/processing/v1.2.0/schema.json" %in% item_exts
  has_proc_field <- any(grepl("^processing:", item_keys))
  if (!identical(has_proc_ext, has_proc_field)) {
    stop(basename(item_json), " declares the processing extension = ", has_proc_ext,
         " but publishes a processing: field = ", has_proc_field, " — half-applied")
  }

  # Values, not just keys (#17 deferred this "once they land"; #32 lands it). Per TARGET, read
  # from the producer's raw JSON independently of the reader: one scalar from each upstream
  # section, compared with `identical()`. An absent file, an absent section (a MORR file with
  # only the coho sections when staging ch_ff06) and a JSON null all come out NULL on both
  # sides, so this is two-sided per section by construction — a reader that silently found
  # nothing in a record that exists fails on the section it lost, and a value invented
  # where the producer has none fails too. `[[` throughout: `$` partial-matches on a list.
  prov_file <- file.path(fp_data, wsg, "provenance.json")
  prov <- if (file.exists(prov_file) && file.size(prov_file) > 0)
    jsonlite::read_json(prov_file, simplifyVector = FALSE) else NULL
  net <- Filter(function(s) identical(as.character(s[["inputs"]][["species"]]), meta$species),
                prov[["network"]] %||% list())
  lv <- if (length(net)) net[[1]][["inputs"]][["link"]][["version"]]
  ls <- if (length(net)) net[[1]][["link_log"]][["link_sha"]]
  # The `link` entry is REASSEMBLED from the producer's two leaves rather than split out of
  # the published string: a version may itself carry build metadata, so only the last `+`
  # separates the two and a split is ambiguous where the join is not. Both halves NULL means
  # the entry is absent, which is the state three published items are in.
  want <- list(
    "processing:software$link"    = if (!is.null(lv) && !is.null(ls)) paste0(lv, "+", ls),
    "processing:software$flooded" =
      prov[["floodplain"]][[meta$scenario]][["inputs"]][["flooded"]][["version"]],
    "processing:datetime"        = prov[["landcover"]][[meta$scenario]][["run"]][["datetime_utc"]])
  got <- list(
    "processing:software$link"    = props[["processing:software"]][["link"]],
    "processing:software$flooded" = props[["processing:software"]][["flooded"]],
    "processing:datetime"        = props[["processing:datetime"]])
  message("  provenance.json ", if (is.null(prov)) "absent" else "present", " upstream for ",
          toupper(wsg), "; per-section expectation for ", meta$item_id, ": ",
          paste(names(want), "=",
                vapply(want, function(v) if (is.null(v)) "null" else as.character(v), ""),
                collapse = ", "))
  for (k in names(want)) {
    if (!identical(got[[k]], want[[k]])) {
      stop(basename(item_json), " publishes ", k, " = ", deparse(got[[k]]),
           " but the producer's record says ", deparse(want[[k]]),
           " — the reader and the record disagree for this target")
    }
  }

  # File-extension contract (#22): every asset carries file:checksum + file:size, so a
  # consumer can verify a download and tell one vintage of a regenerated asset from
  # another. Size is checked against disk here; item_validate.py re-hashes the bytes
  # (this test asserts the fields ship at all, which is the cheap half).
  item_assets <- jsonlite::read_json(item_json)$assets
  # 4 fixed data assets (transition + three GeoPackages) + 3 layer styles (#46) + one per
  # classified year. Since #61 the last term is per item — three-year and seven-year items
  # both exist — so the count is anchored on `meta$years`, which came from the staged
  # rasters and was reconciled against the producer's record before anything was written.
  #
  # Still not derived from the ITEM: `item_assets` is what is under test, and a count taken
  # from it would agree with itself however many assets went missing. `meta.json` is a
  # different artifact, written by a different script than the one that built this JSON.
  n_expected <- 7L + length(unlist(meta$years))
  if (length(item_assets) != n_expected) {
    stop("expected ", n_expected, " assets in ", basename(item_json), " (7 fixed + ",
         length(unlist(meta$years)), " classified years), found ", length(item_assets))
  }
  # The three styles must be present under their own keys and carry roles: ["style"].
  # `floodplain` and `transition_vector` are already asset keys, so a stem-keyed style
  # would replace a data asset and leave the count unchanged -- the same trap the
  # transition_vector comment below describes.
  for (skey in c("style_floodplain", "style_classified", "style_transition")) {
    if (is.null(item_assets[[skey]])) {
      stop("style asset '", skey, "' missing from ", basename(item_json))
    }
    if (!identical(unlist(item_assets[[skey]]$roles), "style")) {
      stop("asset '", skey, "' roles is ",
           paste(unlist(item_assets[[skey]]$roles), collapse = "/"), ", expected 'style'")
    }
  }
  # The transition COG and the transition gpkg must BOTH be present under distinct keys.
  # `transition_2017_2023` is the COG key and is also the stem of the gpkg's old proposed
  # filename, so keying the vector by its stem would silently replace the raster and still
  # leave 7 assets. Assert both survive.
  for (akey in c(paste0("transition_", meta$transition_span[[1]], "_",
                        meta$transition_span[[2]]), "transition_vector")) {
    if (is.null(item_assets[[akey]])) stop("asset '", akey, "' missing from ", basename(item_json))
  }
  for (akey in names(item_assets)) {
    a <- item_assets[[akey]]
    ck <- a$`file:checksum`
    if (is.null(ck) || is.null(a$`file:size`)) {
      stop("asset '", akey, "' is missing file:checksum or file:size")
    }
    # '1220' = sha2-256 multihash prefix; 4 + 64 hex chars. A bare digest passes the
    # STAC schema, so this shape has to be asserted rather than validated.
    if (nchar(ck) != 68L || substr(ck, 1, 4) != "1220") {
      stop("asset '", akey, "' file:checksum is not a sha256 multihash: ", ck)
    }
    on_disk <- file.path(item_dir, basename(a$href))
    if (!file.exists(on_disk)) stop("asset '", akey, "' not staged at ", on_disk)
    if (!identical(as.numeric(a$`file:size`), as.numeric(file.size(on_disk)))) {
      stop("asset '", akey, "' file:size ", a$`file:size`,
           " but staged file is ", file.size(on_disk), " bytes")
    }
  }

  # Attribute contract (floodplains#30): every layer of BOTH published GeoPackages carries the
  # area identifier, so downstream consumers can merge many items into one gpkg and separate
  # them by attribute. Upstream backfills both files (gpkg_backfill-wsg.R), so both are guarded
  # — checking only one would let a regression in the other pass green. Passes today.
  #
  # All THREE key columns are asserted, not `wsg` alone (#80). Until #80 the bundles were
  # copied whole, so a multi-target group shipped the other species' layers and a
  # whole-network group shipped its retired species' layers — `wsg` was the one key that
  # was item-invariant under that copy, and the stronger assertion was not available. It is
  # now: staging selects by the layer's own key, so every layer of every published
  # GeoPackage belongs to the item that ships it.
  #
  # `layer` is omitted deliberately: sf ignores it when `query` is supplied (the query names the
  # layer itself), and passing both emits a warning.
  #
  # `layer_styles` (04_gpkg_style.py) is a non-spatial table GDAL reports as a layer, so
  # `st_layers()` returns it alongside the real ones and an unfiltered loop would demand a
  # `wsg` column from it — restored the bug to confirm that. The filter is
  # `gpkg_contents.data_type`, NOT the geometry type it used to be, because the geometry
  # test excluded exactly the layers staging now SELECTS: `patch_watercourse_*` and
  # `composition_*` are `attributes` rows, the item's own, and they would go unchecked. Two
  # measurements make data_type the right discriminator: 04_gpkg_style.py deliberately
  # writes `layer_styles` with NO `gpkg_contents` row (registering it would add a second
  # churning timestamp), so selecting on data_type excludes it structurally rather than by
  # name — verified on a styled file here; and a `transition_*` layer is declared
  # `Unknown (any)` and reports an EMPTY geomtype rather than NA, so a geometry test gives a
  # different answer depending on which emptiness it checks.
  # The ff-set rule, in ONE place, used by the per-layer arm and the set arm alike.
  want_scen_for <- function(gp) {
    if (gp == "floodplain.gpkg") {
      unique(c(meta$scenario, paste0(sub("_ff.*$", "", meta$scenario),
                                     "_ff", c("02", "04", "06"))))
    } else {
      meta$scenario
    }
  }
  keyed_layers <- function(gpkg) {
    sf::st_read(gpkg, quiet = TRUE,
                query = paste("SELECT table_name FROM gpkg_contents",
                              "WHERE data_type IN ('features','attributes')",
                              "ORDER BY table_name"))$table_name
  }
  for (gp in c("floodplain_landcover.gpkg", "floodplain.gpkg", "transition_vector.gpkg")) {
    gpkg <- file.path(item_dir, gp)
    lyrs <- keyed_layers(gpkg)
    # A filter that removed everything would make every assertion below vacuous.
    if (!length(lyrs)) stop("no keyed layers found in ", gp, " — the layer filter is wrong")
    for (lyr in lyrs) {
      cols <- names(sf::st_read(gpkg, quiet = TRUE,
                                query = sprintf('SELECT * FROM "%s" LIMIT 0', lyr)))
      if (!all(c("wsg", "species", "scenario") %in% cols)) {
        stop("layer '", lyr, "' in ", gpkg, " is missing key column(s) ",
             paste(setdiff(c("wsg", "species", "scenario"), cols), collapse = "/"),
             " (upstream floodplains#30)")
      }
      k <- sf::st_read(gpkg, quiet = TRUE,
                       query = sprintf(
                         'SELECT DISTINCT wsg, species, scenario FROM "%s"', lyr))
      # Row count first: a zero-feature layer would otherwise report empty values, and a
      # layer carrying two items' features would compare only its first.
      if (nrow(k) != 1L) {
        stop("layer '", lyr, "' in ", gp, " has ", nrow(k),
             " distinct (wsg, species, scenario) rows, expected exactly 1")
      }
      # The scenario arm is a SET for floodplain.gpkg and a single value for the other two,
      # for the reason fp_gpkg.R's header gives: that file's ff02/ff06 delineations each
      # record their own flood factor and the item publishes all three. Asserted the same
      # way the stage selects, so this test cannot be weaker than the thing it checks — a
      # single-scenario assertion here would reject the ff02 layer the stage correctly keeps.
      #
      # `want_scen_for()` is defined once, above, and used by BOTH arms. It was written out
      # twice at first and the two copies had already drifted — this one compared `wsg`
      # case-sensitively while the other case-folded, which is the shape of defect that
      # "two lists that happen to agree" names. Case-folded here too, because the column
      # holds `MORR` and nothing guarantees `meta$wsg` always will.
      want_scen <- want_scen_for(gp)
      if (!identical(toupper(k$wsg[1]), toupper(meta$wsg)) ||
            !identical(k$species[1], meta$species) ||
            !k$scenario[1] %in% want_scen) {
        stop("layer '", lyr, "' in ", gp, " is keyed ",
             paste(k$wsg[1], k$species[1], k$scenario[1], sep = "/"),
             " but item ", meta$item_id, " is ",
             paste(meta$wsg, meta$species, paste(want_scen, collapse = "|"), sep = "/"),
             " — a published GeoPackage must hold only its own item's layers (#80)")
      }
    }
  }

  # Nothing outside the item's own set, counted against the SOURCE (#80). The per-layer key
  # arm above is satisfied by any subset, so it cannot see a layer that is missing; this arm
  # is the one that fails on the defect as it stood before #80, where the staged file held
  # every layer the source did.
  #
  # TWO arms, because the obvious single one cannot see a loss. The set comparison below asks
  # the SOURCE which layers are keyed to this item — and it must not ask through
  # `gpkg_own_layers()`, which is the function the stage selects with: a selector that dropped
  # a layer family would make the expectation drop it too and the arm would agree with the
  # defect. (It did, in the first version of this test.) So the expectation is re-derived here
  # in SQL, a second implementation of the same rule over the same bytes.
  lst <- function(x) if (length(x)) paste(x, collapse = ", ") else "<none>"
  for (gp in c("floodplain_landcover.gpkg", "floodplain.gpkg")) {
    src_gpkg <- file.path(fp_data, meta$wsg_lower, gp)
    # OUT LOUD. This is the one arm that can see a layer family the stage LOST, and a silent
    # `next` would retire it on any machine without the source tree while every other line of
    # this file still reads $FLOODPLAINS_DATA unguarded — so the skip would be invisible and
    # selective. Same idiom as gpkg_determinism-check.R's missing-source arm.
    if (!file.exists(src_gpkg)) {
      message("  NOT CHECKED: ", gp, " layer set for ", meta$item_id,
              " — no source at ", src_gpkg)
      next
    }
    src_lyrs <- sf::st_read(src_gpkg, quiet = TRUE,
                            query = paste("SELECT table_name FROM gpkg_contents",
                                          "WHERE data_type IN ('features','attributes')",
                                          "ORDER BY table_name"))$table_name
    want_scen <- want_scen_for(gp)
    expect <- character(0)
    for (lyr in src_lyrs) {
      k <- sf::st_read(src_gpkg, quiet = TRUE,
                       query = sprintf(
                         'SELECT DISTINCT wsg, species, scenario FROM "%s"', lyr))
      if (nrow(k) == 1L && identical(toupper(k$wsg[1]), toupper(meta$wsg)) &&
            identical(k$species[1], meta$species) && k$scenario[1] %in% want_scen) {
        expect <- c(expect, lyr)
      }
    }
    got <- keyed_layers(file.path(item_dir, gp))
    if (!setequal(got, expect)) {
      stop(gp, " for ", meta$item_id, " holds ", length(got), " layer(s) but the source's ",
           length(src_lyrs), " include exactly ", length(expect),
           " keyed to this item. Extra: ", lst(setdiff(got, expect)),
           "; missing: ", lst(setdiff(expect, got)))
    }
  }

  # The second arm: an absolute floor of layer NAMES built from meta.json and the item id,
  # which reach this test from a different script than the one that selected the layers. The
  # set arm above is the right shape but still reads the producer's file to decide what to
  # expect, so a loss that hits the SOURCE — upstream dropping a classified year, say — is
  # consistent on both of its sides. This one cannot be: the years come from `meta$years`,
  # which `01_stage.R` reconciled against the producer's record before anything was written,
  # and the ff names from the scenario. Absolute, for the same reason the style-asset and RAT
  # checks in item_validate.py are: a loss that hits every item identically is invisible to a
  # comparison between items or between artifacts that share an ancestor.
  floor_fp <- paste0(sub("_ff.*$", "", meta$scenario), "_ff", c("02", "04", "06"))
  floor_lc <- c(sprintf("classified_%s_%s", meta$scenario, unlist(meta$years)),
                sprintf("transition_%s_%s_%s", meta$scenario,
                        meta$transition_span[[1]], meta$transition_span[[2]]))
  for (f in list(list(gp = "floodplain.gpkg", want = floor_fp),
                 list(gp = "floodplain_landcover.gpkg", want = floor_lc))) {
    have <- keyed_layers(file.path(item_dir, f$gp))
    absent <- setdiff(f$want, have)
    if (length(absent)) {
      stop(f$gp, " for ", meta$item_id, " is missing layer(s) the item must publish: ",
           lst(absent), " (has: ", lst(have), ")")
    }
  }

  # --- The from->to decode, checked against an INDEPENDENT producer (#35) ------------
  # The published labels ("Trees -> Rangeland") are this repo's decode of drift's
  # `from * 1000 + to` encoding. Restating an upstream encoding here is the same class of
  # mistake as retyping the class table: if drift ever changes the multiplier or the codes,
  # this repo emits confidently wrong labels and NOTHING disagrees — the RAT and
  # classification:classes are built from the same classes.json, so they agree with each
  # other however wrong they are, checksums verify, and cog_validate passes.
  #
  # transition_vector.gpkg is the oracle, because upstream writes its `transition`,
  # `from_class` and `to_class` columns itself. Comparing our decoded labels against those
  # strings is not circular: the two sides have different producers.
  #
  # Compared as a SET over the codes actually present in the raster, not over the 81-row
  # scheme — the vector carries changed patches only, so the no-change diagonal is
  # legitimately absent from it and is excluded here rather than papered over.
  tr <- sf::st_read(file.path(item_dir, "transition_vector.gpkg"),
                    layer = "transition", quiet = TRUE)
  tr <- sf::st_drop_geometry(tr)
  # The oracle's own shape, checked BEFORE anything is derived from it. paste() recycles a
  # zero-length argument to "" when any other argument is non-zero-length, so an empty
  # layer — or one that lost these columns, where `tr$from_class` is NULL — yields the
  # single string " -> " rather than character(0). A length check on the RESULT therefore
  # cannot fire, and the mismatch below would blame drift's encoding for what is really an
  # empty or malformed oracle.
  stopifnot(
    "transition_vector.gpkg lost from_class/to_class" =
      all(c("from_class", "to_class") %in% names(tr)),
    "transition_vector.gpkg has no rows, so the label decode was not checked" = nrow(tr) > 0
  )
  upstream_pairs <- unique(paste(tr$from_class, "->", tr$to_class))
  # `item_doc`, not `item_json` — that name is bound to a PATH earlier in this loop and is
  # still read as one further up. Rebinding it here works today only because every path use
  # precedes this point, and the end of this loop is where the next check gets appended.
  item_doc <- jsonlite::read_json(file.path("data", "stac",
                                            paste0(meta$item_id, ".json")))
  # Anchored on the span, not just the prefix: `transition_vector` is an asset key too, so
  # a bare "^transition_" matches two assets and the length check below rejects both.
  tkey <- grep("^transition_[0-9]{4}_[0-9]{4}$", names(item_doc$assets), value = TRUE)
  stopifnot("no transition asset to check labels against" = length(tkey) == 1L)
  cls <- item_doc$assets[[tkey]]$`classification:classes`
  # Our decode, restricted to the changed pairs, rendered the way upstream renders them.
  ours <- vapply(cls, function(c) c$title, character(1))
  codes <- vapply(cls, function(c) as.integer(c$value), integer(1))
  changed <- codes %/% 1000L != codes %% 1000L
  ours_pairs <- gsub("\u2192", "->", ours[changed], fixed = TRUE)
  ours_pairs <- trimws(gsub("  +", " ", ours_pairs))
  # Upstream can only witness the pairs it actually observed, so the published scheme must
  # be a SUPERSET. A pair upstream saw that we cannot name is the real failure.
  unexplained <- setdiff(trimws(upstream_pairs), ours_pairs)
  if (length(unexplained)) {
    stop("transition labels disagree with transition_vector.gpkg — upstream reports ",
         length(unexplained), " pair(s) the published classes do not name: ",
         paste(utils::head(unexplained, 5), collapse = "; "),
         ". The from*1000+to decode may no longer match drift's encoding.")
  }
  message(sprintf("  labels: %d upstream from->to pair(s) all named by the published classes",
                  length(upstream_pairs)))

  items[[meta$item_id]] <- meta
}

# A group must stage exactly the targets its area.yml declares — every group, derived, not a
# literal naming one.
#
# This was `wsg == "morr"` asserting `morr_co_ff04 + morr_ch_ff06`, because MORR was the only
# multi-target group and those were its two items. Upstream retired MORR's `targets:` block
# under floodplains#125, so it now falls back to the single `all_ff04` item — and the literal
# failed a build that was correct, after item_validate.py had already passed it (#75). An
# expectation that names ids cannot be contradicted by the roster it is about; one derived from
# the roster can only be contradicted by the stage.
#
# It is read from area.yml here rather than taken from 01_stage.R's loop variable, which holds
# whichever group the loop saw last. A declared target that staged nothing (no rasters upstream)
# fails here by design: the stage prints SKIPPED and moves on, and a smoke test that accepted a
# silently smaller build would be checking only what was built.
area_cfg <- yaml::read_yaml(file.path(CONFIG_DIR, wsg, "area.yml"))
declared <- area_cfg[["targets"]]
if (is.null(declared)) {
  declared <- list(list(scenario = area_cfg[["primary_scenario"]]))
}
want <- paste0(wsg, "_", vapply(declared, function(t) t[["scenario"]], character(1)))
stopifnot("the group staged other than the targets its area.yml declares" =
            setequal(names(items), want))
message("targets: ", length(want), " declared in area.yml, all staged (",
        paste(want, collapse = ", "), ")")

# --- Summary --------------------------------------------------------------
message("\n=== SUMMARY ===")
message(toupper(wsg), ": ", length(items), " item(s)")
for (meta in items) {
  message("  ", meta$item_id, " (", meta$scenario, "): ",
          "ff02 ", meta$floodplain_ff02_km2, " / ff04 ", meta$floodplain_ff04_km2,
          " / ff06 ", meta$floodplain_ff06_km2, " km2 | loss/gain/net ",
          meta$gross_loss_ha, " / ", meta$gross_gain_ha, " / ", meta$net_ha, " ha")
}
message("\nPASS — ", toupper(wsg), " round-trips stage -> tag -> COG -> STAC locally.")
message("This tree is a PARTIAL stage: its collection.json cannot be published. Either:")
message("  bash scripts/catalogue_release.sh --only <item_id>   # republish this group's item(s), never the collection")
message("  bash scripts/run_pipeline.sh                         # or rebuild all rostered groups (no network writes)")
message("  bash scripts/catalogue_release.sh                    # then a full validate -> sync -> register -> verify")
