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
meta_path <- file.path("data", "raw", wsg, "meta.json")
if (!file.exists(meta_path)) stop("meta.json not written for ", toupper(wsg))
meta <- jsonlite::read_json(meta_path)

cogs <- list.files(file.path("data", "stac", wsg), pattern = "\\.tif$")
item_json <- file.path("data", "stac", paste0(meta$item_id, ".json"))

stopifnot(
  "expected 4 COGs (3 classified + transition)" = length(cogs) == 4L,
  "item JSON not written" = file.exists(item_json),
  "floodplain_km2 not positive" = meta$floodplain_km2 > 0,
  "gross_loss_ha missing" = !is.null(meta$gross_loss_ha)
)

# --- Summary --------------------------------------------------------------
message("\n=== SUMMARY ===")
message("WSG:          ", meta$wsg, " (", meta$scenario, ")")
message("Floodplain:   ", meta$floodplain_km2, " km2")
message("Loss/gain/net: ", meta$gross_loss_ha, " / ", meta$gross_gain_ha,
        " / ", meta$net_ha, " ha")
message("COGs:         ", length(cogs), " (", paste(cogs, collapse = ", "), ")")
message("Item:         ", basename(item_json), " — validated")
message("\nPASS — ", toupper(wsg), " round-trips stage -> COG -> tag -> STAC locally.")
message("Publish for real with: bash scripts/run_pipeline.sh (all 8 WSGs, writes to S3).")
