# 01_stage.R — stage the floodplains ff04 outputs for the publish pipeline.
#
# Discovers the watershed groups (WSGs) listed in any config/regions/*.yml that carry an
# `ff04` floodplain, copies their classified/transition rasters + landcover GeoPackage into
# `data/`, and derives the per-WSG publish metrics (floodplain area, tree loss/gain/net)
# from the upstream transition layer. Each WSG's `region` is the region roster that lists it.
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

# This script WRITES a GeoPackage (the extracted transition layer, #23), so GDAL's
# wall-clock `gpkg_contents.last_change` stamp has to be pinned or that asset's
# published file:checksum churns on every rebuild while every other asset's stays
# stable. Sourced rather than inlined so gpkg_determinism-check.R exercises the same
# writer. See scripts/fp_gpkg.R for the bound on the guarantee.
source(file.path("scripts", "fp_gpkg.R"))
gpkg_pin_date()

FLOODPLAINS_DATA <- Sys.getenv("FLOODPLAINS_DATA", unset = "../floodplains/data")
CONFIG_DIR <- file.path(dirname(FLOODPLAINS_DATA), "config")
YEARS <- c(2017, 2020, 2023)
TRANSITION_SPAN <- c(2017, 2023)

raw_dir <- file.path("data", "raw")
stac_dir <- file.path("data", "stac")

# Clean rebuild: drop prior staging so a WSG dropped from the region (or a changed
# scenario/span) can't leave stale artifacts that 03/04/05 would silently re-publish.
# The wipe also clears any prior PARTIAL_STAGE marker — a full run leaves none.
unlink(raw_dir, recursive = TRUE)
unlink(stac_dir, recursive = TRUE)
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

# --- Resolve watershed groups across all region configs -------------------
# The region config is the source of truth: every config/regions/*.yml contributes
# its watershed_groups, and a group's `region` property is the region that lists it.
# Groups absent from every roster (e.g. coho co_ff04) are not published.

region_files <- list.files(file.path(CONFIG_DIR, "regions"),
                           pattern = "\\.yml$", full.names = TRUE)
wsg_region <- list()
for (rf in region_files) {
  rc <- yaml::read_yaml(rf)
  # A missing `region:` would make `wsg_region[[g]] <- NULL` silently drop the group.
  if (is.null(rc$region) || !nzchar(rc$region)) {
    stop("Region config ", rf, " has no `region:` field")
  }
  for (g in tolower(rc$watershed_groups)) {
    if (!is.null(wsg_region[[g]]) && wsg_region[[g]] != rc$region) {
      warning("WSG '", g, "' listed in regions '", wsg_region[[g]], "' and '",
              rc$region, "' — keeping '", wsg_region[[g]], "'")
    } else {
      wsg_region[[g]] <- rc$region
    }
  }
}
wsgs <- names(wsg_region)

# WSG_ONLY restricts staging to a single group (used by the smoke test). A partial
# stage must never be published over the live collection: we drop a PARTIAL_STAGE
# marker that catalogue_release.sh refuses to publish past. See the skipped-target
# check at the end of this script, which drops the same marker.
wsg_only <- tolower(Sys.getenv("WSG_ONLY", unset = ""))
if (nzchar(wsg_only)) {
  if (!wsg_only %in% wsgs) {
    stop("WSG_ONLY='", wsg_only, "' is not in any region roster (",
         paste(wsgs, collapse = ", "), ")")
  }
  wsgs <- wsg_only
  writeLines(wsg_only, file.path(raw_dir, "PARTIAL_STAGE"))
}
message(length(wsgs), " WSG(s) to stage across ",
        length(unique(unlist(wsg_region[wsgs]))), " region(s): ",
        paste(wsgs, collapse = ", "))

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

  # Publish targets: one item per declared (species, scenario). Areas without an explicit
  # `targets` list fall back to a single {species, primary_scenario} item (unchanged behaviour).
  targets <- area$targets
  if (is.null(targets)) {
    targets <- list(list(species = area$species, scenario = area$primary_scenario))
  }

  src_wsg <- file.path(FLOODPLAINS_DATA, wsg)

  for (tgt in targets) {
    scenario <- tgt$scenario                        # e.g. co_ff04, ch_ff06
    species <- tgt$species
    item_id <- paste0(wsg, "_", scenario)

    src_rasters <- file.path(src_wsg, "rasters", scenario)
    if (!dir.exists(src_rasters)) {
      message("SKIPPED ", item_id, " — no rasters at ", src_rasters)
      skipped <- c(skipped, item_id)
      next
    }

    # Staging dirs + assets are item-id-keyed so multiple items per WSG never collide.
    dst_raw <- file.path(raw_dir, item_id)
    dst_stac <- file.path(stac_dir, item_id)
    dir.create(dst_raw, recursive = TRUE, showWarnings = FALSE)
    dir.create(dst_stac, recursive = TRUE, showWarnings = FALSE)

    # Rasters → data/raw/<item_id>/ with self-describing published basenames.
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

    # Vector assets → data/stac/<item_id>/ (publish-ready, no COG conversion). The two
    # bundles are copied whole; their layers are species-prefixed, so a gpkg shared by two
    # species' items is self-describing per item.
    # file.copy() returns FALSE on failure rather than erroring, and a short or missing
    # copy would be hashed and published with a checksum that verifies against the corrupt
    # bytes — item_validate.py re-hashes the same file, so it cannot catch it.
    stopifnot(
      "floodplain_landcover.gpkg copy failed" =
        file.copy(file.path(src_wsg, "floodplain_landcover.gpkg"),
                  file.path(dst_stac, "floodplain_landcover.gpkg"), overwrite = TRUE),
      "floodplain.gpkg copy failed" =
        file.copy(file.path(src_wsg, "floodplain.gpkg"),
                  file.path(dst_stac, "floodplain.gpkg"), overwrite = TRUE)
    )

    # The third vector asset is WRITTEN here, not copied (#23): the transition layer alone,
    # so a consumer can take the change layer without the three dissolved classified epochs
    # that carry most of the geometry — measured 0.73 MB against a 6.25 MB bundle for SLOC.
    # That matters against the ~550 MB Mergin finalize ceiling.
    #
    # Because this repo now writes a GeoPackage, the OGR_CURRENT_DATE pin at the top of this
    # file is load-bearing: without it this asset's file:checksum would churn every rebuild
    # while every other asset's stayed stable.
    #
    # The destination layer is named `transition`, deliberately dropping the producer's
    # species/scenario/span. QGIS styles bind to `path|layername=`, and the span is expected
    # to move (2017-2023 -> 2017-2025 -> possibly 2010-2025 on satellite data). Identity is
    # carried by the item id and the layer's own wsg/species/scenario columns.
    # Read from the STAGED copy, not from src_wsg: that makes this asset structurally
    # guaranteed to be the transition layer of the bundle we publish alongside it. Reading
    # upstream would be equivalent in a clean run but could diverge if upstream moved
    # between the copy above and this line.
    transition_layer <- paste0("transition_", scenario, "_",
                               TRANSITION_SPAN[1], "_", TRANSITION_SPAN[2])
    gpkg_extract_layer(
      src = file.path(dst_stac, "floodplain_landcover.gpkg"),
      layer = transition_layer,
      dst = file.path(dst_stac, "transition_vector.gpkg"),
      dst_layer = "transition"
    )

    # Areas from the three run=TRUE flood-factor delineations. Sibling layer names derive from
    # the item's scenario by species prefix (co_/ch_/bt_ + ff0N) — selected by prefix, never
    # positionally, so a second species' layers in the same gpkg are correctly ignored.
    fp_gpkg <- file.path(src_wsg, "floodplain.gpkg")
    sp_prefix <- sub("_ff.*$", "", scenario)
    ff_layers <- setNames(paste0(sp_prefix, "_ff", c("02", "04", "06")),
                          c("ff02", "ff04", "ff06"))
    # The item's own headline-scenario layer is the footprint (may be ff06, e.g. chinook, not
    # necessarily ff04); it plus the three ff layers must all exist.
    needed <- unique(c(scenario, ff_layers))
    missing_layers <- setdiff(needed, sf::st_layers(fp_gpkg)$name)
    if (length(missing_layers)) {
      stop("floodplain.gpkg for ", item_id, " missing layer(s): ",
           paste(missing_layers, collapse = ", "))
    }
    read_area_km2 <- function(layer) {
      poly <- sf::st_read(fp_gpkg, layer = layer, quiet = TRUE)
      round(as.numeric(sum(sf::st_area(poly))) / 1e6, 2)
    }
    floodplain_ff02_km2 <- read_area_km2(ff_layers[["ff02"]])
    floodplain_ff04_km2 <- read_area_km2(ff_layers[["ff04"]])
    floodplain_ff06_km2 <- read_area_km2(ff_layers[["ff06"]])

    # Footprint geometry from the item's OWN headline-scenario layer (not necessarily ff04).
    fp <- sf::st_read(fp_gpkg, layer = scenario, quiet = TRUE)
    epsg <- sf::st_crs(fp)$epsg
    fp_wgs <- sf::st_transform(sf::st_union(fp), 4326)
    bbox <- as.numeric(sf::st_bbox(fp_wgs))
    # Emit GeoJSON via the GDAL GeoJSON driver (no geojsonsf dependency), then read
    # it back as a nested list so meta.json carries a ready-to-use STAC geometry.
    geojson_tmp <- tempfile(fileext = ".geojson")
    sf::st_write(sf::st_sf(geometry = fp_wgs), geojson_tmp,
                 driver = "GeoJSON", quiet = TRUE)
    geometry <- jsonlite::fromJSON(geojson_tmp, simplifyVector = FALSE)$features[[1]]$geometry
    unlink(geojson_tmp)

    # Loss/gain/net from the item's transition layer. Reads the STAGED copy, the same file
    # the vector asset was extracted from — so the published metrics and the published
    # transition_vector.gpkg are guaranteed to describe the same bytes, not merely the same
    # layer name. Reading upstream here would reintroduce exactly the divergence the
    # extraction above avoids.
    metrics <- tree_transition_metrics(
      file.path(dst_stac, "floodplain_landcover.gpkg"),
      transition_layer
    )

    meta <- list(
      wsg = toupper(wsg),
      wsg_lower = wsg,
      species = species,
      scenario = scenario,
      region = wsg_region[[wsg]],
      item_id = item_id,
      years = YEARS,
      transition_span = TRANSITION_SPAN,
      epsg = epsg,
      floodplain_ff02_km2 = floodplain_ff02_km2,
      floodplain_ff04_km2 = floodplain_ff04_km2,
      floodplain_ff06_km2 = floodplain_ff06_km2,
      gross_loss_ha = metrics$gross_loss_ha,
      gross_gain_ha = metrics$gross_gain_ha,
      net_ha = metrics$net_ha,
      bbox_wgs84 = bbox,
      geometry = geometry
    )
    jsonlite::write_json(meta, file.path(dst_raw, "meta.json"),
                         auto_unbox = TRUE, pretty = TRUE, digits = 10)

    message(sprintf(
      "STAGED %s (%s): ff02 %.2f / ff04 %.2f / ff06 %.2f km2, loss %.1f ha, gain %.1f ha, net %.1f ha",
      item_id, scenario, floodplain_ff02_km2, floodplain_ff04_km2, floodplain_ff06_km2,
      metrics$gross_loss_ha, metrics$gross_gain_ha, metrics$net_ha))
    staged <- c(staged, item_id)
  }
}

message("\n", length(staged), " staged, ", length(skipped), " skipped")
if (length(skipped)) message("Skipped: ", paste(toupper(skipped), collapse = ", "))

# A skip is just as partial as WSG_ONLY: an upstream gap (no area.yml, or no rasters
# because $FLOODPLAINS_DATA is stale or mid-recompute) silently drops a group, and
# without a marker the pipeline would sync assets and publish a short collection.json
# over the live one — unrecoverable, since bucket versioning is Suspended. Mark it so
# run_pipeline.sh refuses to sync. ALLOW_SKIPPED=1 is the deliberate escape hatch for
# rostered groups that are not modelled yet.
partial_marker <- file.path(raw_dir, "PARTIAL_STAGE")
if (length(skipped) && !file.exists(partial_marker)) {
  # Strict truthiness: nzchar() would treat ALLOW_SKIPPED=0 as "enabled", so an
  # operator trying to turn the override OFF would turn it on.
  if (tolower(Sys.getenv("ALLOW_SKIPPED", unset = "")) %in% c("1", "true", "yes")) {
    message("ALLOW_SKIPPED set — publishing without ", length(skipped), " skipped target(s)")
  } else {
    writeLines(paste(skipped, collapse = ", "), partial_marker)
    message("PARTIAL_STAGE written — ", length(skipped), " target(s) skipped. ",
            "Fix upstream, or set ALLOW_SKIPPED=1 to publish anyway.")
  }
}
