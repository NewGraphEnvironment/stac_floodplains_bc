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
# The classified year set is NOT a constant (#61). It is a fact about the producer's run —
# some areas are three-year, some annual since floodplains#79 — so it is read per item, from
# the rasters on disk, and checked against the record. See the block in the target loop.
#
# TRANSITION_SPAN stays a literal, and the split is the point: the year set is data, the
# span is a contract this repo chose. It is what the derived year set is anchored against
# (both endpoints must be classified), and what the record's own `change_interval` is
# compared to. Removing it too would leave nothing hardcoded at stage at all.
TRANSITION_SPAN <- c(2017L, 2023L)

raw_dir <- file.path("data", "raw")
stac_dir <- file.path("data", "stac")

# --- Run provenance (#17) -------------------------------------------------
# Ferried from the producer, never derived here. The names are the STAC property names
# minus the `nge:` prefix, so item_create.py maps them mechanically and this vector
# is the single place the set is declared.
#
# `link_config_sha256` is link's OWN stored `config_hash` — a hash over 17 config files
# plus the config name and species list, not a SHA of config.yaml. Recomputing one here
# would produce a value that joins to nothing in link's log (floodplains#33).
#
# `link_sha` is not in #17's original list. It is carried because `config_hash` alone is
# not resolvable: floodplains#33 verified that `link_sha` + `config_hash` together are
# what recover the exact 17 files a network was built from.
#
# `landcover_key` is a fingerprint of the landcover PRODUCED: the producer's per-year
# content digests (cell values + geometry, floodplains#64) folded to one scalar — see
# fp_provenance.R for the rule. `landcover_item_hash` is the identity of what was READ, a
# hash over the resolved STAC item ids; it was published as landcover_key until #40, and
# cannot detect an in-place upstream re-derivation, which is why both are carried.
PROV_FIELDS <- c(
  "link_run_uid", "link_config_sha256", "link_sha", "link_version",
  "flooded_version", "drift_version", "produced_datetime",
  "landcover_source", "landcover_collection", "landcover_stac_url", "landcover_key",
  "landcover_item_hash"
)

# Absent provenance is the NORMAL state, not an error: floodplains#33 is forward-only, so
# every area modelled before it lands carries none until it is re-run. Every field is
# published as an explicit JSON null rather than omitted — an absent property reads as
# "not implemented", a null one as "we looked and there was not one", and only the second
# is true.
#
# The reader is the ONLY part of this repo that knows the producer's file shape. Sourced
# after PROV_FIELDS because it asserts against it.
source(file.path("scripts", "fp_provenance.R"))

# Clean rebuild: drop prior staging so a WSG dropped from the region (or a changed
# scenario/span) can't leave stale artifacts that 03 / item_create.py would silently re-publish.
# The wipe also clears any prior PARTIAL_STAGE marker — a full run leaves none.
unlink(raw_dir, recursive = TRUE)
unlink(stac_dir, recursive = TRUE)
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

# --- Class table (#34/#35) ------------------------------------------------
# The land-cover code -> label -> colour mapping, ferried from `drift` rather than retyped.
# Planetary Computer labels the source io-lulc items, drift consumes those labels, and
# until now this repo dropped them on republish.
#
# Written ONCE at collection level, not into each meta.json: the table is identical for
# every item, so seventeen copies would be seventeen chances to disagree. It lives under
# data/raw for two reasons — the wipe above guarantees a rebuild cannot inherit a stale
# table, and `data/stac` is off limits because catalogue_release.sh builds its item-id
# list from `$STAC_DIR/*.json`, which would register a phantom item called `classes`.
#
# Code 0 is dropped. It is the SOURCE scheme's "No Data" marker, not a land cover: the
# published rasters declare nodata natively (255 on the classified, -2147483648 on the
# transition) and never contain 0. Keeping it would put a class in the legend that cannot
# occur, and would make the transition cross product 100 rows of which 19 are unreachable.
classes <- drift::dft_class_table("io-lulc")
classes <- classes[classes$code != 0, c("code", "class_name", "color", "description")]

# Absolute floors, not derived from what we just read. A short or empty table is exactly
# the uniform defect a cross-item check cannot see: every item would lose the same labels,
# every asset count would still be right, and the STAC classification extension validates
# an item carrying ZERO classes (measured). So the expectation is named here.
stopifnot(
  "drift class table is empty" = nrow(classes) > 0,
  "drift class table lost codes — expected the io-lulc 9" =
    setequal(classes$code, c(1, 2, 4, 5, 7, 8, 9, 10, 11)),
  "drift class table has a non-#RRGGBB colour" =
    all(grepl("^#[0-9A-Fa-f]{6}$", classes$color)),
  "drift class table has a blank class_name" = all(nzchar(trimws(classes$class_name)))
)

jsonlite::write_json(
  list(source = "drift::dft_class_table(\"io-lulc\")",
       drift_version = as.character(utils::packageVersion("drift")),
       classes = classes),
  file.path(raw_dir, "classes.json"),
  auto_unbox = TRUE, pretty = TRUE, na = "null", null = "null"
)
message("classes.json: ", nrow(classes), " land-cover classes from drift ",
        as.character(utils::packageVersion("drift")))

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
traced <- character(0)   # items carrying at least one non-null provenance field
drift_untraced <- character(0)  # items whose producer drift version is unknown (#34)
year_untraced <- character(0)   # items whose year set had no record to check against (#61)

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

  # One provenance file per WSG upstream, but one item per (wsg, species, scenario) here —
  # so read once and select per target. NULL when the area predates floodplains#33.
  wsg_prov <- fp_prov_read(src_wsg)

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
    # --- The item's classified year set (#61) ------------------------------------------
    # Two independent sources, and the assertion between them is the whole point.
    # `years_disk` is what is actually there; `span_rec` is what upstream says it built.
    # The DISK set is what gets published and what the landcover_key fold is handed, so
    # that fold keeps two different producers on its two sides — sourcing both from
    # provenance would reduce it to one file's `years` agreeing with the same file's
    # `classified_content_sha256`.
    #
    # fp_prov_sections() now runs three times per target (here, in
    # fp_prov_rasters_current, and in fp_prov_item). It is a pure read whose only side
    # effect is stopping earlier on a schema break, so the repetition is harmless.
    span_rec <- fp_prov_span(wsg_prov, species, scenario, item_id)

    # ANCHORED. list.files(pattern = ) is an unanchored regex and every source raster dir
    # carries a `classified_<yyyy>.tif.aux.xml` sidecar beside each `.tif`, so an
    # unanchored `classified_[0-9]{4}\\.tif` would match both and stage the sidecar's year
    # twice.
    classified_files <- list.files(src_rasters, pattern = "^classified_[0-9]{4}\\.tif$")
    years <- sort(as.integer(sub("^classified_([0-9]{4})\\.tif$", "\\1",
                                 classified_files)))

    # The guard lives in fp_provenance.R so it can be fired against both known answers
    # without staging an area. Returns FALSE for the forward-only state (no landcover
    # section, nothing to check the disk against) — only mcgr_ch_ff04 and pine_bt_ff04 are
    # still in it, and both already publish `deprecated: true`.
    if (!fp_years_reconcile(years, span_rec, TRANSITION_SPAN, item_id)) {
      message(item_id, ": no landcover provenance — year set taken from the ", length(years),
              " staged raster(s) (", paste(years, collapse = ", "),
              "). No record to assert it against.")
      year_untraced <- c(year_untraced, item_id)
    }

    # Rasters newer than the record that describes them stop the stage (#40): the item
    # would otherwise publish landcover_key as a fingerprint of bytes it does not ship.
    # The DISCOVERED paths are passed, plus the transition: the function filters to files
    # that exist, so anything upstream wrote that the old constant did not name was never
    # mtime-checked at all.
    fp_prov_rasters_current(src_wsg,
                            file.path(src_rasters,
                                      c(sprintf("classified_%d.tif", years),
                                        "transition.tif")),
                            wsg_prov, species, scenario, item_id)

    # Staging dirs + assets are item-id-keyed so multiple items per WSG never collide.
    dst_raw <- file.path(raw_dir, item_id)
    dst_stac <- file.path(stac_dir, item_id)
    dir.create(dst_raw, recursive = TRUE, showWarnings = FALSE)
    dir.create(dst_stac, recursive = TRUE, showWarnings = FALSE)

    # Rasters → data/raw/<item_id>/ with self-describing published basenames.
    raster_map <- c(
      setNames(sprintf("classified_%d.tif", years), sprintf("classified_%d.tif", years)),
      setNames("transition.tif",
               sprintf("transition_%d_%d.tif", TRANSITION_SPAN[1], TRANSITION_SPAN[2]))
    )
    for (i in seq_along(raster_map)) {
      src <- file.path(src_rasters, raster_map[[i]])
      dst <- file.path(dst_raw, names(raster_map)[i])
      if (!file.exists(src)) stop("Missing source raster: ", src)
      # Checked, for the same reason the GeoPackage copies below are: file.copy() signals
      # failure by RETURNING FALSE, not by erroring, so a short copy would be hashed by item_create.py
      # and published with a file:checksum that verifies against the truncated bytes.
      # item_validate.py re-hashes the same file, so it cannot catch it.
      stopifnot("raster copy failed" = file.copy(src, dst, overwrite = TRUE))
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
      years = years,
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
    # Provenance last so the modelled figures stay at the top of the file where they are
    # read by eye. c() on two lists appends; PROV_FIELDS shares no name with the block
    # above, so nothing is overwritten.
    #
    # `species` here is the TARGET's species, never `area$species`: MORR's area.yml
    # declares `species: co` at the top level and then two targets, co and ch. Reading the
    # area-level value would give MORR's chinook item coho's network provenance —
    # silently, since both are valid strings.
    meta <- c(meta, fp_prov_item(wsg_prov, species, scenario, item_id, years))

    # The class table above comes from THIS machine's drift, while the rasters were built
    # by the producer's. A drift that renamed a class between the two would publish labels
    # describing a scheme the pixels were not classified under — silently, since both are
    # valid strings. Reconcile rather than assume.
    #
    # A null is the expected reading until floodplains#33 has been re-run everywhere
    # (forward-only), so it warns; a version that is present and DIFFERENT is a real
    # mismatch and stops. `drift_class_version_stop = FALSE` exercises the warn path
    # without needing a second drift installed.
    produced_drift <- meta[["drift_version"]]
    if (length(produced_drift) == 1L && !is.na(produced_drift) &&
        produced_drift != as.character(utils::packageVersion("drift"))) {
      msg <- paste0(item_id, ": rasters produced with drift ", produced_drift,
                    " but classes.json was written from drift ",
                    as.character(utils::packageVersion("drift")),
                    " — the published labels may not describe these pixels")
      if (tolower(Sys.getenv("ALLOW_DRIFT_SKEW", unset = "")) %in% c("1", "true", "yes")) {
        warning(msg)
      } else {
        stop(msg, ". Set ALLOW_DRIFT_SKEW=1 to publish anyway.")
      }
    } else if (length(produced_drift) != 1L || is.na(produced_drift)) {
      drift_untraced <- c(drift_untraced, item_id)
    }

    # Both null arguments are load-bearing, not tidiness — jsonlite has two separate
    # defaults that each turn an intended null into something else, silently:
    #
    #   na = "null"    without it, NA_real_ serialises as the STRING "NA"
    #   null = "null"  without it (default "list"), an R NULL serialises as {}
    #
    # Neither `"NA"` nor `{}` is a null. Both read as a real value to a consumer, both
    # pass every schema check, and `{}` additionally passes Python's `is not None`. The
    # NULL case is the one that bites the provenance reader: indexing a missing key in a
    # nested list yields NULL, so a leaf that upstream renamed would publish as `{}`.
    # Measured; both are byte-inert on the seventeen fields above.
    jsonlite::write_json(meta, file.path(dst_raw, "meta.json"),
                         auto_unbox = TRUE, pretty = TRUE, digits = 10,
                         na = "null", null = "null")

    has_prov <- any(!vapply(meta[PROV_FIELDS], function(v) length(v) == 1L && is.na(v),
                            logical(1)))
    if (has_prov) traced <- c(traced, item_id)
    message(sprintf(
      "STAGED %s (%s): ff02 %.2f / ff04 %.2f / ff06 %.2f km2, loss %.1f ha, gain %.1f ha, net %.1f ha%s",
      item_id, scenario, floodplain_ff02_km2, floodplain_ff04_km2, floodplain_ff06_km2,
      metrics$gross_loss_ha, metrics$gross_gain_ha, metrics$net_ha,
      if (has_prov) "" else " [no provenance]"))
    staged <- c(staged, item_id)
  }
}

message("\n", length(staged), " staged, ", length(skipped), " skipped")
if (length(skipped)) message("Skipped: ", paste(toupper(skipped), collapse = ", "))
# A number on screen, not a silence (#17). Zero is the expected reading until
# floodplains#33 lands and areas are re-modelled, and it climbs from there — so this line
# is the progress signal as well as the alarm.
message(length(traced), " of ", length(staged), " staged item(s) carry run provenance")
if (length(year_untraced)) {
  # A number on screen rather than a silence, the same shape as the two counts above. These
  # items took their year set from the rasters with no record to check it against, so
  # "the item publishes the years it was built from" is unverified for them, not verified.
  message(length(year_untraced), " of ", length(staged),
          " staged item(s) took their classified year set from disk, unchecked: ",
          paste(year_untraced, collapse = ", "))
}
if (length(drift_untraced)) {
  # A number on screen rather than a silence, same as the provenance count above: until the
  # producer records drift_version, "the labels match the pixels" is unverified, not verified.
  message(length(drift_untraced), " of ", length(staged),
          " staged item(s) could not be checked against the producer's drift version")
}

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
