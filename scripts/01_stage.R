# 01_stage.R — stage the floodplains ff04 outputs for the publish pipeline.
#
# Discovers the watershed groups (WSGs) listed in any config/regions/*.yml that carry an
# `ff04` floodplain, copies their classified/transition rasters into `data/`, WRITES each
# item's three GeoPackages holding only that item's own layers (#80), and derives the per-WSG
# publish metrics (floodplain area, tree loss/gain/net) from the upstream transition layer.
# Each WSG's `region` is the region roster that lists it.
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
# Ferried from the producer, never derived here. These are the STAGED names, and since #74
# they are NOT the published property names: item_create.py carries the map from each of
# these to `processing:datetime`, a `processing:software` entry, `link:*` or `landcover:*`.
# They are still the names 02_raster_tag.py writes into every COG as NGE_<FIELD>, which is
# why renaming the published properties moved no raster bytes. This vector is the single
# place the staged set is declared.
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
# every area modelled before it lands carries none until it is re-run. Every field is staged
# as NA, so meta.json carries the key with a null on every item — and that is where the
# distinction now ends: since #74 item_create.py OMITS the key on the published item, because
# the processing extension admits no null. The "we looked and there was not one" statement
# survives on the COGs, as NGE_PROVENANCE_NULL, and nowhere else.
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
# Code 0 is KEPT, and used to be dropped. The premise for dropping it was that the
# published rasters declare nodata natively (255 on the classified, -2147483648 on the
# transition) and "never contain 0" — true while every item was one species' ACCESSIBLE
# floodplain, and false since the whole-network cutover (#89). Measured on that build:
# `kisp/rasters/all_ff04/classified_2020.tif` holds 58,540 cells of 0 among 3,555,686 valid
# ones, and the species raster for the same group and year holds none — the whole network
# reaches ground the accessible one did not, and io-lulc's 2020 composite has a gap there.
# 0 is a value the data holds, so it is a value the labels have to describe.
#
# It was this repo's own guard that found it, not a consumer: `check_layer_styles` refused
# the staged GeoPackage because one feature of `classified_all_ff04_2020` carries
# class_name "No Data" and the style had no category for it, so it would have drawn with no
# symbol. The raster side was worse and quieter — 58,540 cells with no RAT row at all.
#
# The dropped premise's second half does not survive either: "a transition cross product of
# 100 rows of which 19 are unreachable" is the same objection that already applies to the
# 81, of which KISP reaches 45. The transition RAT documents drift's ENCODING, not any
# item's data (`02_raster_tag.transition_rat`), and item_validate.py checks the direction
# that matters — every code present in a raster has a row — not the converse.
classes <- drift::dft_class_table("io-lulc")
classes <- classes[, c("code", "class_name", "color", "description")]

# Absolute floors, not derived from what we just read. A short or empty table is exactly
# the uniform defect a cross-item check cannot see: every item would lose the same labels,
# every asset count would still be right, and the STAC classification extension validates
# an item carrying ZERO classes (measured). So the expectation is named here.
stopifnot(
  "drift class table is empty" = nrow(classes) > 0,
  "drift class table lost codes — expected the io-lulc 10, code 0 included" =
    setequal(classes$code, c(0, 1, 2, 4, 5, 7, 8, 9, 10, 11)),
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
# `[[` here too, and this is the level with the LARGER blast radius: `$watershed_groups`
# partial-matches a retired roster key. Measured — a region file carrying
# `watershed_groups_retired: [MORR, KISP]` and no live `watershed_groups:` returns those two
# from `rc$watershed_groups` and NULL from `rc[["watershed_groups"]]`, so the `$` form would
# stage whole RETIRED watershed groups, and `wsgs <- names(wsg_region)` below carries them
# into every downstream gate. Found one round after the same fix was applied to area.yml and
# missed here, because that round enumerated the hazard by VARIABLE NAME rather than by what
# the variable holds: a parsed file this repo does not own.
for (rf in region_files) {
  rc <- yaml::read_yaml(rf)
  # A missing `region:` would make `wsg_region[[g]] <- NULL` silently drop the group.
  if (is.null(rc[["region"]]) || !nzchar(rc[["region"]])) {
    stop("Region config ", rf, " has no `region:` field")
  }
  for (g in tolower(rc[["watershed_groups"]])) {
    if (!is.null(wsg_region[[g]]) && wsg_region[[g]] != rc[["region"]]) {
      warning("WSG '", g, "' listed in regions '", wsg_region[[g]], "' and '",
              rc[["region"]], "' — keeping '", wsg_region[[g]], "'")
    } else {
      wsg_region[[g]] <- rc[["region"]]
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
unclaimed_groups <- character(0) # groups carrying layers no target claims (#80)
family_unknown <- character(0)   # items staging a layer in no known family (#80)

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
  # `[[` throughout, never `$`: `$` partial-matches on a list, and the producer is MID-WAY
  # through retiring target blocks — config/morr/area.yml says so in prose today. Measured: an
  # `area.yml` carrying `targets_retired:` and no live `targets:` makes `area$targets` return
  # the RETIRED block, so this build would stage `morr_co_ff04` + `morr_ch_ff06` — the two
  # items #76 exists to remove — and `test_pipeline.R`'s target assertion would CONFIRM them,
  # because it read the same partial match. Two gates agreeing because they share one defect.
  # `area[["targets"]]` is NULL for that file, which is the answer the fallback below wants.
  targets <- area[["targets"]]
  if (is.null(targets)) {
    targets <- list(list(species = area[["species"]],
                         scenario = area[["primary_scenario"]]))
  }

  src_wsg <- file.path(FLOODPLAINS_DATA, wsg)

  # One provenance file per WSG upstream, but one item per (wsg, species, scenario) here —
  # so read once and select per target. NULL when the area predates floodplains#33.
  wsg_prov <- fp_prov_read(src_wsg)

  # --- The group's two bundles, keyed once (#80) -------------------------------------
  # Read ONCE PER GROUP, not once per target. Both files are group-level, and the census
  # below asks "which layers match no target of this group" — a question that needs every
  # target's verdict against one reading of one table. Computed per target instead, a
  # two-target group would double-count and could name a layer foreign that its sibling
  # target owns. Dormant today, since no area.yml carries a `targets:` block — which is
  # exactly the shape #75 spent four rounds on.
  gpkg_src <- c(floodplain = file.path(src_wsg, "floodplain.gpkg"),
                landcover = file.path(src_wsg, "floodplain_landcover.gpkg"))
  # SKIPPED, not stopped. A rostered group with no upstream outputs is the state
  # `PARTIAL_STAGE` and `ALLOW_SKIPPED` exist for ("$FLOODPLAINS_DATA is stale or
  # mid-recompute", below), and before #80 these two files were only touched inside the target
  # loop, after the no-rasters skip — so a hard stop here would sit UPSTREAM of both and make
  # that documented escape hatch unreachable. The skip is recorded, so the interlock still
  # refuses to publish a short collection; it is a louder outcome than it looks.
  missing_gpkg <- names(gpkg_src)[!file.exists(gpkg_src)]
  if (length(missing_gpkg)) {
    message("SKIPPED ", toupper(wsg), " — no ",
            paste(basename(gpkg_src[missing_gpkg]), collapse = " / "), " at ", src_wsg)
    skipped <- c(skipped, wsg)
    next
  }
  # A bundle that cannot be READ is a group SKIP, for the same reason a missing one is: a
  # truncated, locked or mid-write file is the "$FLOODPLAINS_DATA is stale or mid-recompute"
  # state, and a raise here would sit upstream of `ALLOW_SKIPPED` exactly as the existence
  # check used to. Round 1 fixed the existence arm and left this one in the same position.
  #
  # Only the READ is skippable. What the keys SAY is a different question and still refuses
  # below: a file we could read, whose layers carry no usable key or another group's, is a
  # contract break rather than a gap, and the two must not share a disposition.
  keys <- lapply(gpkg_src, function(p) {
    tryCatch(gpkg_layer_keys(p), error = function(e) conditionMessage(e))
  })
  unreadable <- vapply(keys, is.character, logical(1))
  if (any(unreadable)) {
    message("SKIPPED ", toupper(wsg), " — could not read ",
            paste(basename(gpkg_src[unreadable]), collapse = " / "), ": ",
            paste(unlist(keys[unreadable]), collapse = "; "))
    skipped <- c(skipped, wsg)
    next
  }
  keys_fp <- keys[["floodplain"]]
  keys_lc <- keys[["landcover"]]

  # REFUSED, not reported, and the two arms refuse for different reasons.
  #
  # A layer that cannot be attributed at all — a key column gone, or more than one key row —
  # makes "belongs to this item" undecidable, and the only other disposition is to drop it,
  # which is the direction that publishes. Measured 2026-10-14: 0 of 276 layers across all
  # 24 upstream areas are in either state, so this arm is defensive. That is why it refuses:
  # a backfill regression that stripped the key would make EVERY layer unattributable and
  # every own set empty, and a build that published that as a census line cannot be rolled
  # back (bucket versioning is Suspended).
  #
  # A foreign WSG is the separate one. A retired species or scenario is a known upstream
  # state — three groups carry one today — but a layer of another GROUP inside
  # $FLOODPLAINS_DATA/<wsg>/ has never been seen and would mean the producer merged two
  # groups into one area dir, which breaks the premise `src_wsg` and `meta$wsg` rest on.
  # test_pipeline.R's per-layer `wsg` assertion is the repo's only guard in that direction,
  # and it reads the STAGED copy — so after this filter it could never see such a layer
  # again. Refusing here keeps the guard rather than trading it for a line in a census the
  # operator has been taught to expect.
  for (nm in names(gpkg_src)) {
    k <- if (nm == "floodplain") keys_fp else keys_lc
    bad <- k$status != "ok"
    if (any(bad)) {
      stop(toupper(wsg), "/", basename(gpkg_src[[nm]]), ": ", sum(bad),
           " layer(s) carry no usable item key (floodplains#30): ",
           paste(paste0(k$layer[bad], " [", k$scenario[bad], "]"), collapse = ", "),
           call. = FALSE)
    }
    off <- toupper(k$wsg) != toupper(wsg)
    if (any(off)) {
      stop(toupper(wsg), "/", basename(gpkg_src[[nm]]), ": ", sum(off),
           " layer(s) belong to another watershed group (",
           paste(unique(k$wsg[off]), collapse = ", "), "): ",
           paste(k$layer[off], collapse = ", "),
           ". Staging would drop them and test_pipeline.R's per-layer wsg assertion reads ",
           "the staged copy, so nothing downstream would ever see this.", call. = FALSE)
    }
  }

  # Accumulated across the group's targets, so the census below is the complement of what
  # every target claimed — not of what the last one claimed.
  claimed_fp <- character(0)
  claimed_lc <- character(0)

  for (tgt_i in seq_along(targets)) {
    tgt <- targets[[tgt_i]]
    # The guard runs BEFORE the two extractions, so it is first in fact and not only in its
    # comment: a bare-scalar target entry (`targets:\n  - co_ff04`, parsed as character) makes
    # `tgt[["scenario"]]` raise "subscript out of bounds" with no file, wsg or index, and the
    # named stop() below would never print.
    if (!is.list(tgt)) {
      stop("config/", wsg, "/area.yml: target ", tgt_i, " is ", class(tgt)[1],
           ", not a mapping of `species:` and `scenario:`.", call. = FALSE)
    }
    # Asserted here, where the roster is read, because every downstream symptom is quiet.
    # `paste0(wsg, "_", NULL)` is "bulk_", not an error, and `file.path(src, "rasters", NULL)`
    # is the area's `rasters/` parent — which EXISTS, so the "no rasters, skip" branch below
    # does not fire either. This runs before every fp_prov_* call for every area, including
    # the two rostered ones that carry no provenance.json at all (measured 2026-10-14: mcgr,
    # pine), so it is the only guard on this path — fp_prov_sections() keeps its own copy for
    # the check scripts and any other direct caller, not for the stage. (An earlier version of
    # this comment counted four, naming `lit` and `logs`. Neither is an area: `lit` holds two
    # reference PDFs and `logs` holds run logs, and neither has a config/<wsg>/ directory, so
    # neither was ever walked by this loop.)
    for (f in c("species", "scenario")) {
      v <- tgt[[f]]  # already `[[`, and the loop below reads only these two names
      if (!is.character(v) || length(v) != 1L || is.na(v) || !nzchar(v)) {
        # The loop index, not `which(vapply(targets, identical, ...))`: two byte-identical
        # `targets:` entries make that `which` length 2, and stop() concatenates with no
        # separator — measured "target 12", a plausible wrong pointer into area.yml.
        stop("config/", wsg, "/area.yml: target ", tgt_i,
             " declares no usable `", f, "` (", deparse(v)[1], "). With no `targets:` block ",
             "that means a missing `", if (f == "scenario") "primary_scenario" else f,
             "`.", call. = FALSE)
      }
    }
    scenario <- tgt[["scenario"]]                   # e.g. co_ff04, ch_ff06, all_ff04
    species <- tgt[["species"]]
    item_id <- paste0(wsg, "_", scenario)

    # The item's own layers, and the group's claim on them, computed BEFORE the raster skip
    # below. The claim set has to come from the group's DECLARED targets, not from the ones
    # that happen to stage: computed after the skip, a target with no rasters contributed
    # nothing, so the per-group census would report every layer of its own live target as
    # matching no target of the group — and then label them "upstream's retired targets,
    # pruned by floodplains#131", which is false in both directions and invites deleting
    # upstream data belonging to a target that is simply mid-recompute.
    #
    # The ff set, not the item's single scenario, for floodplain.gpkg: its ff02/ff06
    # delineations each record their OWN flood factor in `scenario` and the item publishes
    # all three. `needed` is the same vector the layer-name assertion further down uses, so
    # the selection and that assertion cannot part company.
    sp_prefix <- sub("_ff.*$", "", scenario)
    ff_layers <- setNames(paste0(sp_prefix, "_ff", c("02", "04", "06")),
                          c("ff02", "ff04", "ff06"))
    needed <- unique(c(scenario, ff_layers))
    own_fp <- gpkg_own_layers(keys_fp, wsg, species, needed)
    own_lc <- gpkg_own_layers(keys_lc, wsg, species, scenario)
    claimed_fp <- union(claimed_fp, own_fp)
    claimed_lc <- union(claimed_lc, own_lc)

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
      # Checked because file.copy() signals failure by RETURNING FALSE, not by erroring, so
      # a short copy would be hashed by item_create.py and published with a file:checksum
      # that verifies against the truncated bytes. item_validate.py re-hashes the same
      # file, so it cannot catch it. The GeoPackages below are no longer copies, and
      # sf::gdal_utils() is the opposite case — see the note there.
      stopifnot("raster copy failed" = file.copy(src, dst, overwrite = TRUE))
    }

    # Vector assets → data/stac/<item_id>/ (publish-ready, no COG conversion). WRITTEN, not
    # copied (#80): the upstream bundles hold every target the group has ever been modelled
    # for, and upstream keeps the retired ones until floodplains#131 prunes them, so a whole
    # copy publishes another target's floodplain inside this item's own assets. See the
    # header of fp_gpkg.R for the selection rule and the asymmetry between the two files.
    #
    # Both refusals BEFORE the census, so a group whose target has no landcover at all stops
    # here rather than printing twenty "matches no item" lines and then stopping anyway.
    #
    # Two arms per file, and the second is not the first restated.
    #
    # An empty own set makes every assertion below vacuous. Its LIVE shape is a species or
    # scenario the bundle does not carry — an upstream re-key, or an `area.yml` naming a
    # target that was never modelled — which is what the mutation testing for this arm
    # actually used (`species='xx'` on every floodplain layer). Not a foreign `wsg`, although
    # an earlier version of this comment said so and cited NEEXDZII: that case cannot reach
    # here, because the group-level `wsg` refusal above fires before the target loop runs at
    # all, and NEEXDZII is excluded from every roster by config/regions/skeena.yml besides.
    # A guard's recorded instance has to be one that can actually reach it.
    #
    # A set holding only ASPATIAL tables passes that first arm and then dies three
    # steps later inside 04_gpkg_style.py ("declares no feature layers in gpkg_contents"),
    # under a message about styling for a cause that is here.
    for (sel in list(list(f = "floodplain.gpkg", own = own_fp, keys = keys_fp,
                          want = paste(needed, collapse = ", ")),
                     list(f = "floodplain_landcover.gpkg", own = own_lc, keys = keys_lc,
                          want = scenario))) {
      if (!length(sel$own)) {
        stop(item_id, ": no layer of ", sel$f, " carries this item's key (wsg ",
             toupper(wsg), ", species ", species, ", scenario ", sel$want,
             "). Keys present: ",
             paste(unique(paste(sel$keys$wsg, sel$keys$species, sel$keys$scenario,
                                sep = "/")), collapse = "; "), call. = FALSE)
      }
      # `%in% "features"`, never `== "features"`: `gpkg_layer_keys()` fills `data_type` by
      # `match()` against gpkg_contents, so a layer GDAL lists that the table does not
      # register gives NA — and `x[c(TRUE, NA)]` yields an NA ELEMENT, so `length(feat)` would
      # be non-zero and this refusal would pass vacuously on exactly the file it is for.
      feat <- sel$keys$layer[sel$keys$layer %in% sel$own &
                               sel$keys$data_type %in% "features"]
      if (!length(feat)) {
        stop(item_id, ": this item's ", length(sel$own), " layer(s) of ", sel$f,
             " are all aspatial (", paste(sel$own, collapse = ", "),
             ") — 04_gpkg_style.py would refuse the staged file for having no feature ",
             "layers, three steps from the cause.", call. = FALSE)
      }
    }

    gpkg_copy_layers(file.path(src_wsg, "floodplain_landcover.gpkg"),
                     file.path(dst_stac, "floodplain_landcover.gpkg"), own_lc)
    gpkg_copy_layers(file.path(src_wsg, "floodplain.gpkg"),
                     file.path(dst_stac, "floodplain.gpkg"), own_fp)

    # The aspatial tables this item ships, named on screen because nothing else names them.
    # They belong to the item and must ship (#75's decision), but `composition_<scen>_*` and
    # `patch_watercourse_<scen>_*` are described nowhere in this repo (#65, #70) and nothing
    # can catch a NEW one: 04_gpkg_style.py's "matches no style rule" refusal runs after a
    # filter to feature layers, so an aspatial family never reaches it. A line per item is
    # what makes that hole legible until #65 closes it.
    #
    # BOTH bundles, not just the landcover one. Every `attributes` layer upstream is in the
    # landcover bundle today (measured: 30 of 30), so scanning only that one was right about
    # the data and wrong about the question — `floodplain.gpkg` is a file this repo now
    # SELECTS layers into, and it is the bundle with no cover at all, because
    # 04_gpkg_style.py maps every layer of it to one style unconditionally.
    #
    # `%in%`, not `==`, for the same NA reason as the features filter above: `==` would print
    # a phantom NA in the report.
    aspatial <- c(
      keys_fp$layer[keys_fp$layer %in% own_fp & keys_fp$data_type %in% "attributes"],
      keys_lc$layer[keys_lc$layer %in% own_lc & keys_lc$data_type %in% "attributes"])
    if (length(aspatial)) {
      message("  ", item_id, ": ", length(aspatial),
              " aspatial table(s) staged, undescribed here (#65): ",
              paste(aspatial, collapse = ", "))
    }
    # The name-vs-key cross-check, in the opposite direction from the layer assertion below.
    # That one asks whether a NAME we expect carries the key; this asks whether a layer the
    # KEY selected has a name we recognise. It is the only cover floodplain.gpkg has, because
    # 04_gpkg_style.py maps every layer of that file to one style unconditionally — a
    # catch-all that was sound while the layers were inherited from upstream and is a
    # selection we make now.
    # ANCHORED AT BOTH ENDS. `^<sp>_ff[0-9]{2}` alone matches `bt_ff04_reach_summary`, so a
    # new upstream family in floodplain.gpkg would read as a known one and this report —
    # the only cover that file has — would stay silent on exactly what it is for. The
    # optional `_by_<something>` tail is the producer's two existing breakdowns
    # (`_by_blue_line_key` on 18 of 23 groups, `_by_gnis_name` upstream on MORR's coho).
    # Same at the other end for the landcover families, whose names carry a year or a span.
    unfamiliar <- c(
      grep(paste0("^", sp_prefix, "_ff[0-9]{2}(_by_[a-z0-9_]+)?$"), own_fp,
           value = TRUE, invert = TRUE),
      grep("^(classified|transition|patch_watercourse|composition)_[a-z0-9_]+_[0-9]{4}(_[0-9]{4})?(_patches)?$",
           own_lc, value = TRUE, invert = TRUE)
    )
    if (length(unfamiliar)) {
      message("  ", item_id, ": ", length(unfamiliar), " staged layer(s) match this item's ",
              "key but no known family — new upstream shape, and nothing here describes it: ",
              paste(unfamiliar, collapse = ", "))
      family_unknown <- c(family_unknown, item_id)
    }

    # The third vector asset is WRITTEN here, not copied (#23): the transition layer alone,
    # so a consumer can take the change layer without the dissolved classified epochs
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
    # the item's scenario by species prefix (co_/ch_/bt_ + ff0N) — `sp_prefix`, `ff_layers`
    # and `needed` were built above, where the write needed them, so the layers asserted here
    # are exactly the ones the selection asked for.
    #
    # Read from the STAGED copy, not from src_wsg (#80). Two reasons, and the second is the
    # stronger one.
    #
    # The published figures then describe the published bytes, which is the same argument
    # already written for the transition extraction above and for the metrics below.
    #
    # And this assertion becomes a NAME-VS-KEY CROSS-CHECK. Selection is by the layer's key
    # columns; this is by name. A layer named `ch_ff02` whose `species` column says `co` is
    # dropped by the selection and then stops the stage here, by name — the two readings
    # disagreeing is the finding. Left on the source, the same disagreement would publish a
    # floodplain.gpkg missing a layer whose area the item reports.
    fp_gpkg <- file.path(dst_stac, "floodplain.gpkg")
    # The item's own headline-scenario layer is the footprint (may be ff06, e.g. chinook, not
    # necessarily ff04); it plus the three ff layers must all exist.
    missing_layers <- setdiff(needed, sf::st_layers(fp_gpkg)$name)
    if (length(missing_layers)) {
      # Which side lost it, named: upstream never had it, or it carried a key that is not
      # this item's. Without the split the operator looks in the wrong repo.
      upstream <- setdiff(missing_layers, keys_fp$layer)
      stop("staged floodplain.gpkg for ", item_id, " missing layer(s): ",
           paste(missing_layers, collapse = ", "),
           if (length(upstream)) paste0(" — absent upstream: ",
                                        paste(upstream, collapse = ", ")),
           if (length(setdiff(missing_layers, upstream)))
             paste0(" — present upstream but not keyed to this item: ",
                    paste(setdiff(missing_layers, upstream), collapse = ", ")),
           call. = FALSE)
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

  # --- Layers this group's targets did not claim (#80) -------------------------------
  # Reported, not refused, and deliberately so. These are upstream's retired targets —
  # BULK's coho, KISP's chinook, MORR's coho and chinook — which stay on disk until
  # floodplains#131 prunes them, so three of the rostered groups carry some on every run
  # today. A refusal would be overridden on every release of those three, and an override
  # that is always set stops being read: a guard failing toward pass.
  #
  # But not a silence either. #75's decision is explicit that a layer matching no item
  # surfaces as a decision rather than as an omission, so a NEW upstream family shows up
  # here the first time it is written, with the key it carries printed beside it.
  #
  # Outside the target loop (see the keying block above): the complement of what every
  # target claimed, not of what the last one claimed.
  for (nm in names(gpkg_src)) {
    k <- if (nm == "floodplain") keys_fp else keys_lc
    unclaimed <- setdiff(k$layer, if (nm == "floodplain") claimed_fp else claimed_lc)
    if (length(unclaimed)) {
      key_of <- paste0(k$species[match(unclaimed, k$layer)], "/",
                       k$scenario[match(unclaimed, k$layer)])
      message("  ", toupper(wsg), "/", basename(gpkg_src[[nm]]), ": ", length(unclaimed),
              " layer(s) match no target of this group, not staged: ",
              paste0(unclaimed, " [", key_of, "]", collapse = ", "))
      unclaimed_groups <- union(unclaimed_groups, toupper(wsg))
    }
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
# Two numbers on screen rather than silences, the same shape as the three counts above
# (#80). The first is upstream's retired targets, which three rostered groups carry today
# and floodplains#131 will prune — a count that should fall to zero and is not an error
# while it does not. The second is the one to act on: a layer that matches an item's key but
# no family this repo knows is a new upstream shape, published undescribed, and for
# floodplain.gpkg nothing downstream can catch it (04_gpkg_style.py maps every layer of that
# file to one style unconditionally).
if (length(unclaimed_groups)) {
  message(length(unclaimed_groups), " group(s) carry layers no target claims (named above): ",
          paste(unclaimed_groups, collapse = ", "),
          " — upstream's retired targets, pruned by floodplains#131")
}
if (length(family_unknown)) {
  message(length(family_unknown), " of ", length(staged),
          " staged item(s) hold a layer in no known family: ",
          paste(family_unknown, collapse = ", "))
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
