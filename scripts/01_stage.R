# 01_stage.R — stage the floodplains ff04 outputs for the publish pipeline.
#
# Discovers the watershed groups (WSGs) in the Fraser region that carry an `ff04`
# floodplain, copies their classified/transition rasters + landcover GeoPackage into
# `data/`, and derives the per-WSG publish metrics (floodplain area, tree loss/gain/net)
# from the upstream transition layer.
#
# No modelling here: loss/gain/net are aggregations of the transition patches already
# produced by the `floodplains` driver. They are computed once, at staging, and written
# to `data/raw/<wsg>/meta.json` so the Python tag + register steps consume identical
# figures without needing a vector reader.
#
# Source: $FLOODPLAINS_DATA (default ../floodplains/data), config alongside it.

library(sf)
library(yaml)
library(jsonlite)

FLOODPLAINS_DATA <- Sys.getenv("FLOODPLAINS_DATA", unset = "../floodplains/data")
CONFIG_DIR <- file.path(dirname(FLOODPLAINS_DATA), "config")
REGION <- "fraser"
YEARS <- c(2017, 2020, 2023)
TRANSITION_SPAN <- c(2017, 2023)

raw_dir <- file.path("data", "raw")
stac_dir <- file.path("data", "stac")

# Clean rebuild: drop prior staging so a WSG dropped from the region (or a changed
# scenario/span) can't leave stale artifacts that 03/04/05 would silently re-publish.
unlink(raw_dir, recursive = TRUE)
unlink(stac_dir, recursive = TRUE)

# --- Resolve the region's watershed groups --------------------------------

region_cfg <- yaml::read_yaml(file.path(CONFIG_DIR, "regions", paste0(REGION, ".yml")))
wsgs <- tolower(region_cfg$watershed_groups)
message(length(wsgs), " WSGs in region '", REGION, "': ", paste(wsgs, collapse = ", "))

# --- Metrics from the transition layer ------------------------------------
# Gross loss  = tree-covered in 2017, something else in 2023.
# Gross gain  = non-tree in 2017, tree-covered in 2023.
# Net         = gain - loss (negative = net tree loss).

tree_transition_metrics <- function(gpkg, layer) {
  tr <- sf::st_read(gpkg, layer = layer, quiet = TRUE)
  tr <- sf::st_drop_geometry(tr)
  loss <- sum(tr$area_ha[tr$from_class == "Trees" & tr$to_class != "Trees"], na.rm = TRUE)
  gain <- sum(tr$area_ha[tr$to_class == "Trees" & tr$from_class != "Trees"], na.rm = TRUE)
  list(gross_loss_ha = round(loss, 1),
       gross_gain_ha = round(gain, 1),
       net_ha = round(gain - loss, 1))
}

# --- Stage each WSG -------------------------------------------------------

staged <- character(0)
skipped <- character(0)

for (wsg in wsgs) {
  area_yml <- file.path(CONFIG_DIR, wsg, "area.yml")
  if (!file.exists(area_yml)) {
    message("SKIPPED ", toupper(wsg), " — no area.yml at ", area_yml)
    skipped <- c(skipped, wsg)
    next
  }
  area <- yaml::read_yaml(area_yml)
  scenario <- area$primary_scenario                 # e.g. ch_ff04
  species <- area$species

  src_wsg <- file.path(FLOODPLAINS_DATA, wsg)
  src_rasters <- file.path(src_wsg, "rasters", scenario)
  if (!dir.exists(src_rasters)) {
    message("SKIPPED ", toupper(wsg), " — no rasters at ", src_rasters)
    skipped <- c(skipped, wsg)
    next
  }

  dst_raw <- file.path(raw_dir, wsg)
  dst_stac <- file.path(stac_dir, wsg)
  dir.create(dst_raw, recursive = TRUE, showWarnings = FALSE)
  dir.create(dst_stac, recursive = TRUE, showWarnings = FALSE)

  # Rasters → data/raw/<wsg>/ with self-describing published basenames.
  raster_map <- c(
    setNames(sprintf("classified_%d.tif", YEARS), sprintf("classified_%d.tif", YEARS)),
    setNames("transition.tif",
             sprintf("transition_%d_%d.tif", TRANSITION_SPAN[1], TRANSITION_SPAN[2]))
  )
  for (i in seq_along(raster_map)) {
    src <- file.path(src_rasters, raster_map[[i]])
    dst <- file.path(dst_raw, names(raster_map)[i])
    if (!file.exists(src)) stop("Missing source raster: ", src)
    file.copy(src, dst, overwrite = TRUE)
  }

  # Vector asset → data/stac/<wsg>/ (publish-ready, no COG conversion).
  file.copy(file.path(src_wsg, "floodplain_landcover.gpkg"),
            file.path(dst_stac, "floodplain_landcover.gpkg"), overwrite = TRUE)

  # Footprint geometry + area from the floodplain polygon.
  fp <- sf::st_read(file.path(src_wsg, "floodplain.gpkg"), layer = scenario, quiet = TRUE)
  epsg <- sf::st_crs(fp)$epsg
  floodplain_km2 <- round(as.numeric(sum(sf::st_area(fp))) / 1e6, 2)
  fp_wgs <- sf::st_transform(sf::st_union(fp), 4326)
  bbox <- as.numeric(sf::st_bbox(fp_wgs))
  # Emit GeoJSON via the GDAL GeoJSON driver (no geojsonsf dependency), then read
  # it back as a nested list so meta.json carries a ready-to-use STAC geometry.
  geojson_tmp <- tempfile(fileext = ".geojson")
  sf::st_write(sf::st_sf(geometry = fp_wgs), geojson_tmp,
               driver = "GeoJSON", quiet = TRUE)
  geometry <- jsonlite::fromJSON(geojson_tmp, simplifyVector = FALSE)$features[[1]]$geometry
  unlink(geojson_tmp)

  # Loss/gain/net from the transition layer.
  metrics <- tree_transition_metrics(
    file.path(src_wsg, "floodplain_landcover.gpkg"),
    paste0("transition_", scenario, "_", TRANSITION_SPAN[1], "_", TRANSITION_SPAN[2])
  )

  meta <- list(
    wsg = toupper(wsg),
    wsg_lower = wsg,
    species = species,
    scenario = scenario,
    region = REGION,
    item_id = paste0(wsg, "_", scenario),
    years = YEARS,
    transition_span = TRANSITION_SPAN,
    epsg = epsg,
    floodplain_km2 = floodplain_km2,
    gross_loss_ha = metrics$gross_loss_ha,
    gross_gain_ha = metrics$gross_gain_ha,
    net_ha = metrics$net_ha,
    bbox_wgs84 = bbox,
    geometry = geometry
  )
  jsonlite::write_json(meta, file.path(dst_raw, "meta.json"),
                       auto_unbox = TRUE, pretty = TRUE, digits = 10)

  message(sprintf("STAGED %s (%s): %.2f km2, loss %.1f ha, gain %.1f ha, net %.1f ha",
                  toupper(wsg), scenario, floodplain_km2,
                  metrics$gross_loss_ha, metrics$gross_gain_ha, metrics$net_ha))
  staged <- c(staged, wsg)
}

message("\n", length(staged), " staged, ", length(skipped), " skipped")
if (length(skipped)) message("Skipped: ", paste(toupper(skipped), collapse = ", "))
