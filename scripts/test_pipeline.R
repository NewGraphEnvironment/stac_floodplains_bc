# test_pipeline.R — single-WSG smoke test of stage -> COG -> tag -> build -> validate.
#
# Runs ONE watershed group end-to-end: stages it, builds COGs, tags them, builds the
# STAC JSON and validates it through the same gate a release uses. Use after changes
# to the scripts, the floodplains data layout, or the STAC schema.
#
# It cannot touch S3 or the live catalog — none of the scripts it calls make network
# writes; publishing is catalogue_release.sh alone. It also leaves data/raw/PARTIAL_STAGE
# behind (01_stage.R writes it for WSG_ONLY), which catalogue_release.sh refuses to
# publish past, so a one-group tree cannot be released by mistake either.
#
#   Rscript scripts/test_pipeline.R            # defaults to UFRA
#   WSG=necr Rscript scripts/test_pipeline.R   # any rostered WSG
#   WSG=morr Rscript scripts/test_pipeline.R   # multi-target group: stages 2 items
#
# Requires: R (sf/terra/yaml/jsonlite), uv (Python env from pyproject.toml/uv.lock —
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

# --- 02 COG ---------------------------------------------------------------
source("scripts/02_cog.R")

# --- 03 TAG ---------------------------------------------------------------
message("\n=== 03: TAG ===")
if (system("uv run python scripts/03_cog_tag.py") != 0) {
  stop("03_cog_tag.py failed")
}

# --- 05 BUILD -------------------------------------------------------------
message("\n=== 05: BUILD STAC JSON ===")
if (system("uv run python scripts/05_stac_register.py") != 0) {
  stop("05_stac_register.py failed")
}

# --- VALIDATE -------------------------------------------------------------
# The same gate catalogue_release.sh runs, so the smoke test exercises it rather
# than a separate code path. --expect defaults to the staged meta.json count, which
# is 1 here (2 for MORR), so a partially-built group still fails.
message("\n=== VALIDATE ===")
if (system("uv run python scripts/item_validate.py") != 0) {
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
n_expected <- if (!is.null(area$targets)) length(area$targets) else 1L
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
    "expected 4 COGs (3 classified + transition)" = length(cogs) == 4L,
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

  # Run-provenance contract (#17). Tested on NAMES, never on values: `read_json` maps a
  # JSON null to a NULL list element, so `props[["nge:x"]]` is NULL for a null value AND
  # for an absent key — the one distinction this assertion exists to make. Measured.
  #
  # A null value is expected and correct today (floodplains#33 is forward-only, so an
  # area modelled before it lands carries no provenance). Only an absent KEY fails.
  # Upgrade to non-null once #33 has landed and areas have been re-modelled.
  prov_keys <- paste0("nge:", c(
    "link_run_uid", "link_config_sha256", "link_sha", "link_version",
    "flooded_version", "drift_version", "produced_datetime",
    "landcover_source", "landcover_collection", "landcover_stac_url", "landcover_key"))
  prov_missing <- setdiff(prov_keys, names(props))
  if (length(prov_missing)) {
    stop("item JSON is missing provenance propert(ies): ",
         paste(prov_missing, collapse = ", "))
  }
  # Also assert meta.json carries the unprefixed half, so a break between the two halves
  # of the ferry is attributed to the right script rather than surfacing only as a
  # missing STAC property.
  meta_prov_missing <- setdiff(sub("^nge:", "", prov_keys), names(meta))
  if (length(meta_prov_missing)) {
    stop("meta.json is missing provenance field(s): ",
         paste(meta_prov_missing, collapse = ", "))
  }
  # Tie the two halves to EACH OTHER, not just each to this file's literal. Six copies of
  # the field set exist across the repo; every other pair is guarded, but 01_stage.R's
  # PROV_FIELDS and 05_stac_register.py's were joined only through this list — so a twelfth
  # field added to 01 (and to fp_provenance.R, which its stopifnot forces) would be staged
  # into meta.json, published nowhere, and leave every guard green.
  #
  # Derived from the data on both sides, so it cannot drift from what actually shipped.
  meta_core <- c("wsg", "wsg_lower", "species", "scenario", "region", "item_id", "years",
                 "transition_span", "epsg", "floodplain_ff02_km2", "floodplain_ff04_km2",
                 "floodplain_ff06_km2", "gross_loss_ha", "gross_gain_ha", "net_ha",
                 "bbox_wgs84", "geometry")
  staged_prov <- setdiff(names(meta), meta_core)
  item_prov <- sub("^nge:", "", grep("^nge:", names(props), value = TRUE))
  if (!setequal(staged_prov, item_prov)) {
    stop("meta.json and the published item disagree on the provenance field set — ",
         "staged but not published: ",
         paste(setdiff(staged_prov, item_prov), collapse = ", ") , "; published but not ",
         "staged: ", paste(setdiff(item_prov, staged_prov), collapse = ", "))
  }

  # File-extension contract (#22): every asset carries file:checksum + file:size, so a
  # consumer can verify a download and tell one vintage of a regenerated asset from
  # another. Size is checked against disk here; item_validate.py re-hashes the bytes
  # (this test asserts the fields ship at all, which is the cheap half).
  item_assets <- jsonlite::read_json(item_json)$assets
  if (length(item_assets) != 7L) {
    stop("expected 7 assets in ", basename(item_json), ", found ", length(item_assets))
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
  # Only `wsg` is asserted, not `species`/`scenario`: 01_stage.R copies the whole-WSG gpkgs into
  # EACH item dir, so a multi-target group (MORR) ships the other species' layers too — `wsg` is
  # the one key that is item-invariant under that copy.
  #
  # `layer` is omitted deliberately: sf ignores it when `query` is supplied (the query names the
  # layer itself), and passing both emits a warning.
  for (gp in c("floodplain_landcover.gpkg", "floodplain.gpkg", "transition_vector.gpkg")) {
    gpkg <- file.path(item_dir, gp)
    for (lyr in sf::st_layers(gpkg)$name) {
      cols <- names(sf::st_read(gpkg, quiet = TRUE,
                                query = sprintf('SELECT * FROM "%s" LIMIT 0', lyr)))
      if (!"wsg" %in% cols) {
        stop("layer '", lyr, "' in ", gpkg, " has no `wsg` column (upstream floodplains#30)")
      }
      vals <- unique(sf::st_read(gpkg, quiet = TRUE,
                                 query = sprintf('SELECT DISTINCT wsg FROM "%s"', lyr))$wsg)
      # length check first: a zero-feature layer would otherwise report an empty value.
      if (length(vals) != 1L || !identical(vals, meta$wsg)) {
        stop("layer '", lyr, "' in ", gp, " has wsg = ",
             if (length(vals)) paste(vals, collapse = "/") else "<no rows>",
             " but item is ", meta$wsg)
      }
    }
  }

  items[[meta$item_id]] <- meta
}

# MORR is the multi-species fixture: it must stage exactly its two declared items.
if (wsg == "morr") {
  stopifnot("morr must stage morr_co_ff04 + morr_ch_ff06" =
              setequal(names(items), c("morr_co_ff04", "morr_ch_ff06")))
}

# --- Summary --------------------------------------------------------------
message("\n=== SUMMARY ===")
message(toupper(wsg), ": ", length(items), " item(s)")
for (meta in items) {
  message("  ", meta$item_id, " (", meta$scenario, "): ",
          "ff02 ", meta$floodplain_ff02_km2, " / ff04 ", meta$floodplain_ff04_km2,
          " / ff06 ", meta$floodplain_ff06_km2, " km2 | loss/gain/net ",
          meta$gross_loss_ha, " / ", meta$gross_gain_ha, " / ", meta$net_ha, " ha")
}
message("\nPASS — ", toupper(wsg), " round-trips stage -> COG -> tag -> STAC locally.")
message("This tree is a PARTIAL stage and cannot be published. For a real publish:")
message("  bash scripts/run_pipeline.sh        # rebuild all rostered groups (no network writes)")
message("  bash scripts/catalogue_release.sh   # validate -> sync -> register -> verify")
