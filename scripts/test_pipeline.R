# test_pipeline.R — single-WSG smoke test of stage -> COG -> tag -> STAC.
#
# Runs ONE watershed group end-to-end WITHOUT touching S3 (no 04 sync, no JSON
# upload): stages it, builds COGs, tags them, and builds + validates the STAC item
# locally. Use to check the pipeline after changes to the scripts, the floodplains
# data layout, or the STAC schema — before a real all-8 publish.
#
#   Rscript scripts/test_pipeline.R            # defaults to UFRA
#   WSG=necr Rscript scripts/test_pipeline.R   # any Fraser WSG
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

# --- 05 REGISTER (build + validate locally, skip the S3 upload) -----------
message("\n=== 05: STAC REGISTER (SKIP_S3_UPLOAD) ===")
if (system("SKIP_S3_UPLOAD=1 uv run python scripts/05_stac_register.py") != 0) {
  stop("05_stac_register.py failed validation")
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
    "expected 2 gpkgs (floodplain delineation + landcover)" = length(gpkgs) == 2L,
    "floodplain.gpkg not staged" = "floodplain.gpkg" %in% gpkgs,
    "floodplain_landcover.gpkg not staged" = "floodplain_landcover.gpkg" %in% gpkgs,
    "item JSON not written" = file.exists(item_json),
    "floodplain_ff02_km2 not positive" = isTRUE(meta$floodplain_ff02_km2 > 0),
    "floodplain_ff04_km2 not positive" = isTRUE(meta$floodplain_ff04_km2 > 0),
    "floodplain_ff06_km2 not positive" = isTRUE(meta$floodplain_ff06_km2 > 0),
    "old floodplain_km2 still present (schema break incomplete)" = is.null(meta$floodplain_km2),
    "gross_loss_ha missing" = !is.null(meta$gross_loss_ha)
  )

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
  for (gp in c("floodplain_landcover.gpkg", "floodplain.gpkg")) {
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
message("Publish for real with: bash scripts/run_pipeline.sh (all rostered WSGs, writes to S3).")
