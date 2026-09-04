# readme_functions.R — sourced by README.Rmd.
#
# One rstac call feeds both the coverage figure and the coverage table (#53). It replaces
# `readme_coverage-table.py` (#41), whose completeness guard and version-naming caption are
# ported here rather than dropped: the table describes what the API SERVES, and a short page
# would otherwise read as a smaller collection.
#
# The 45 MB of item geometry the call returns is consumed in-process to draw fig/coverage.png
# and never cached — see planning findings for the measurement. What IS cached is the
# geometry-stripped properties plus the watershed-group polygons, which is what the table and
# the interactive map need.

API_ROOT <- "https://images.a11s.one"
COLLECTION <- "stac-floodplains-bc"
S3_BASE <- "https://stac-floodplains-bc.s3.us-west-2.amazonaws.com"
CACHE <- "data/readme_items.rds"

# `wsg` is a code; the items publish the code, not the label.
SPECIES <- c(bt = "bull trout", ch = "chinook", co = "coho")

#' A property that must be there, or the render stops
#'
#' `tibble(x = NULL)` silently DROPS the column rather than erroring, `map_dfr` then back-fills
#' `NA`, and every downstream guard passes on it: `n_distinct(c(NA, NA))` is 1, so the
#' agreement check below sees one value and agrees with itself, and `fp_readme_int(NA)` renders
#' the string "NANA" straight into a committed table. Python could not reach any of that --
#' `p["floodplain_ff04_km2"]` raised KeyError. This restores the raise.
fp_req <- function(p, key, id) {
  v <- p[[key]]
  if (is.null(v) || length(v) != 1L || is.na(v)) {
    stop(id, ": property `", key, "` is missing or null — refusing to build a table from it",
         call. = FALSE)
  }
  v
}

#' The item's OWN scenario extent, picked by its flood factor
#'
#' A two-branch `if_else(ff == 4, ff04, ff06)` sends every non-4 factor to ff06, so an `ff02`
#' item would print `Scenario = ff02` beside its ff06 area -- a row that looks right and is
#' wrong. Python indexed the column name dynamically and raised on anything else; so does this.
fp_readme_km2 <- function(props) {
  ff <- props$flood_factor
  bad <- setdiff(ff, c(2, 4, 6))
  if (length(bad) > 0) {
    stop("flood_factor ", paste(sort(bad), collapse = ", "),
         " has no floodplain_ff0N_km2 column — the collection publishes ff02/ff04/ff06",
         call. = FALSE)
  }
  cols <- paste0("floodplain_ff0", ff, "_km2")
  vapply(seq_along(ff), \(i) props[[cols[i]]][i], numeric(1))
}


# ---- the one call, and its guards --------------------------------------------------------

#' Fetch every item in the collection, refusing anything short of all of them
#'
#' Returns a list: `features` (the raw STAC features, geometry included), `version` (the
#' catalogue version the API serves) and `n_bucket` (the item count the bucket's collection.json
#' claims). The guards are the point — see the block comment on each.
fp_readme_fetch <- function(api_root = API_ROOT, collection = COLLECTION, s3_base = S3_BASE) {

  # NOT `items_fetch()`. That follows `next` links, which would make the paging arm below
  # vacuous while the code kept reading as if it were guarded. `rstac::items_matched()` is the
  # other tempting idiom and is worse: this API sends no `numberMatched`, so it returns a
  # ZERO-LENGTH value and every comparison against it is FALSE (measured 2026-09-04).
  q <- rstac::stac(paste0(api_root, "/")) |>
    rstac::stac_search(collections = collection, limit = 1000) |>
    rstac::post_request()

  bucket <- fp_readme_bucket(s3_base)
  fp_readme_check_complete(q, n_bucket = bucket$n_items)

  version <- rstac::stac(paste0(api_root, "/")) |>
    rstac::collections(collection) |>
    rstac::get_request() |>
    (\(x) x$version)()

  # A version sentinel that renders is worse here than in the Python script it replaces: that
  # one printed to stdout, this one commits. Cross-check it against the bucket's own copy --
  # the same independent side the item count uses -- and refuse rather than publish a README
  # saying "catalogue version MISSING".
  if (is.null(version) || !nzchar(version)) {
    stop("the API serves no `version` on ", collection,
         " — a release stamps it; registering collection.json by hand un-versions it",
         call. = FALSE)
  }
  if (!identical(version, bucket$version)) {
    stop("the API serves version ", version, " but the bucket's collection.json says ",
         bucket$version %||% "none", " — they are written by the same release and must agree",
         call. = FALSE)
  }

  list(features   = q$features,
       version    = version,
       n_bucket   = bucket$n_items,
       fetched_at = Sys.Date())
}

#' The item count the BUCKET's collection.json claims
#'
#' Deliberately not the API's copy. pgstac rebuilds a served collection's `links` through
#' `get_links()`, dropping every rel in `INFERRED_LINK_RELS` — `item` among them — so the served
#' collection carries no `rel: item` links to count (measured 2026-09-04: the API serves
#' `items/parent/root/self/license/derived_from/queryables`). The bucket copy is written by the
#' release from the same build, so it is the independent side of the comparison.
#' `simplifyVector = FALSE` is load-bearing: with the default, `links` comes back as a
#' data.frame and `vapply` over it walks COLUMNS, so `l$rel` errors on a document that is
#' perfectly well formed.
fp_readme_bucket <- function(s3_base = S3_BASE) {
  coll <- jsonlite::fromJSON(paste0(s3_base, "/collection.json"), simplifyVector = FALSE)
  list(n_items = sum(vapply(coll$links, \(l) identical(l$rel, "item"), logical(1))),
       version = coll$version)
}

#' Refuse a page that is not the whole collection
#'
#' Three arms, in this order and for this reason:
#'
#' 1. Zero features, checked ABSOLUTELY and FIRST — `0 == 0` would otherwise pass the
#'    cross-check below and a caller would render a table with a bare header.
#' 2. A `next` link means the search paged. This API sends no `numberMatched` (measured
#'    2026-09-02: only `numberReturned`), so completeness is "no next link".
#' 3. The count against the bucket's own claim. Either side disagreeing is a refusal.
fp_readme_check_complete <- function(q, n_bucket) {
  n <- length(q$features)
  # Empty FIRST. `any(character(0) == "next")` is FALSE, so a stripped response would pass the
  # paging arm vacuously; checking empty first makes that unreachable rather than survivable.
  if (n == 0L) {
    stop("search returned no items — refusing to build an empty table", call. = FALSE)
  }
  rels <- vapply(q$links %||% list(), \(l) l$rel %||% "", character(1))
  if (any(rels == "next")) {
    stop("search paged at ", n, " features — raise the limit", call. = FALSE)
  }
  if (!identical(as.integer(n), as.integer(n_bucket))) {
    stop("search returned ", n, " items but the bucket collection links ", n_bucket,
         call. = FALSE)
  }
  invisible(TRUE)
}


# ---- the table -----------------------------------------------------------------------------

#' One row per item, plus a total row
#'
#' `Floodplain (km²)` is the item's OWN scenario extent — ff04 for most, ff06 for `morr_ch_ff06`
#' — so the `Scenario` column is load-bearing: the collection mixes flood factors, and a reader
#' summing the column across scenarios would be summing different extents. The total therefore
#' counts each watershed group's ff04 extent ONCE (MORR's two items share one physical
#' floodplain) while the tree-change totals sum every item.
fp_readme_table <- function(props) {
  rows <- props |>
    dplyr::mutate(
      km2 = fp_readme_km2(props),
      # A lookup miss is NA; Python's `SPECIES.get(sp, sp)` printed the raw code. A new species
      # must not ship an empty cell in a committed table.
      Species = dplyr::coalesce(unname(SPECIES[.data$species]), .data$species),
      Scenario = paste0("ff0", .data$flood_factor)
    ) |>
    dplyr::arrange(.data$region, .data$wsg, .data$flood_factor, .data$species)

  # Asserted, not assumed: the search has no sortby, so if a group's items ever disagreed on
  # ff04 the once-per-group total would depend on response order and the render would stop
  # being idempotent.
  disagree <- rows |>
    dplyr::summarise(n = dplyr::n_distinct(.data$floodplain_ff04_km2), .by = "wsg") |>
    dplyr::filter(.data$n > 1)
  if (nrow(disagree) > 0) {
    stop(paste(disagree$wsg, collapse = ", "),
         ": items disagree on floodplain_ff04_km2 — the once-per-group total needs a rule",
         call. = FALSE)
  }

  total_km2 <- rows |>
    dplyr::distinct(.data$wsg, .keep_all = TRUE) |>
    (\(x) sum(x$floodplain_ff04_km2))()

  tab <- tibble::tibble(
    WSG = rows$wsg,
    Region = tools::toTitleCase(rows$region),
    Species = rows$Species,
    Scenario = rows$Scenario,
    `Floodplain (km²)` = fp_readme_int(rows$km2),
    `Gross loss (ha)` = fp_readme_int(rows$gross_loss_ha),
    `Gross gain (ha)` = fp_readme_int(rows$gross_gain_ha),
    `Net (ha)` = fp_readme_int(rows$net_ha, signed = TRUE)
  )

  dplyr::bind_rows(tab, tibble::tibble(
    WSG = "**Total**", Region = "", Species = "", Scenario = "",
    `Floodplain (km²)` = paste0("**", fp_readme_int(total_km2), "**"),
    `Gross loss (ha)` = paste0("**", fp_readme_int(sum(rows$gross_loss_ha)), "**"),
    `Gross gain (ha)` = paste0("**", fp_readme_int(sum(rows$gross_gain_ha)), "**"),
    `Net (ha)` = paste0("**", fp_readme_int(sum(rows$net_ha), signed = TRUE), "**")
  ))
}

#' Round to whole units with a thousands separator; `signed` always shows a sign
fp_readme_int <- function(x, signed = FALSE) {
  v <- round(x)
  s <- formatC(abs(v), format = "d", big.mark = ",")
  if (signed) paste0(ifelse(v >= 0, "+", "-"), s) else paste0(ifelse(v < 0, "-", ""), s)
}

#' The caption, carrying every number the prose would otherwise hardcode
#'
#' Item count, group count, region list and the live catalogue version, so a re-render cannot
#' leave the words above the table contradicting it.
#' A render reads the cache by default, so a caption claiming "at render time" would state a
#' possibly-superseded catalogue version with full confidence. The Python generator had no
#' cache and could not lie this way; naming the fetch date is what restores that.
fp_readme_caption <- function(props, version, fetched_at) {
  regions <- sort(unique(props$region))
  paste0("*Generated from the live API on ", format(fetched_at, "%Y-%m-%d"), ": ",
         nrow(props), " items across ",
         dplyr::n_distinct(props$wsg), " watershed groups in ", length(regions), " regions (",
         paste(tools::toTitleCase(regions), collapse = ", "),
         "), catalogue version ", version, ".*")
}


# ---- properties, geometry, watershed groups ------------------------------------------------

#' Flatten the item properties this README uses into one row per item
fp_readme_props <- function(features) {
  purrr::map_dfr(features, \(f) {
    p <- f$properties
    tibble::tibble(
      id                  = f$id,
      wsg                 = fp_req(p, "wsg", f$id),
      region              = fp_req(p, "region", f$id),
      species             = fp_req(p, "species", f$id),
      scenario            = fp_req(p, "scenario", f$id),
      flood_factor        = fp_req(p, "flood_factor", f$id),
      floodplain_ff02_km2 = fp_req(p, "floodplain_ff02_km2", f$id),
      floodplain_ff04_km2 = fp_req(p, "floodplain_ff04_km2", f$id),
      floodplain_ff06_km2 = fp_req(p, "floodplain_ff06_km2", f$id),
      gross_loss_ha       = fp_req(p, "gross_loss_ha", f$id),
      gross_gain_ha       = fp_req(p, "gross_gain_ha", f$id),
      net_ha              = fp_req(p, "net_ha", f$id),
      # `deprecated` is absent on 21 of 23 items -- absence IS the answer here, unlike above.
      deprecated          = isTRUE(p$deprecated)
    )
  })
}

#' The item footprints as sf, in BC Albers
fp_readme_geom <- function(features) {
  geoms <- purrr::map(features, \(f) {
    sf::st_geometry(geojsonsf::geojson_sf(
      jsonlite::toJSON(f$geometry, auto_unbox = TRUE, digits = NA)
    ))[[1]]
  })
  sf::st_sf(
    id = vapply(features, \(f) f$id, character(1)),
    wsg = vapply(features, \(f) f$properties$wsg, character(1)),
    region = vapply(features, \(f) f$properties$region, character(1)),
    geometry = sf::st_sfc(geoms, crs = 4326)
  ) |>
    sf::st_transform(3005)
}

#' Watershed-group polygons for exactly the groups the collection publishes
#'
#' `bcdata` + `bcmaps` only — no `fwapgr` dependency (airvine, 2026-09-04). Simplified, because
#' the unsimplified 22 groups are ~6 MB and this is both a committed cache and an embedded map
#' layer. The SET of groups comes from the API call, so the map cannot show a group the
#' collection does not publish.
fp_readme_wsg <- function(wsg_codes, dTolerance = 200) {
  codes <- unique(wsg_codes)
  # The permanent id of `freshwater-atlas-watershed-groups`, used rather than the name so a
  # record rename cannot silently return nothing.
  out <- bcdata::bcdc_query_geodata("51f20b1a-ab75-42de-809d-bf415a0f9c62") |>
    bcdata::filter(WATERSHED_GROUP_CODE %in% codes) |>
    bcdata::collect() |>
    dplyr::select(wsg_code = "WATERSHED_GROUP_CODE", wsg_name = "WATERSHED_GROUP_NAME") |>
    sf::st_transform(3005) |>
    sf::st_simplify(dTolerance = dTolerance, preserveTopology = TRUE)

  # A filter that matches nothing returns zero rows, not an error, and the map would then draw
  # a bare province with every group silently missing -- the fail-toward-empty shape. Assert the
  # join is complete instead: the API publishes `wsg` uppercase and the FWA code is uppercase,
  # so a case change on either side has to be loud.
  missing <- setdiff(codes, out$wsg_code)
  if (length(missing) > 0) {
    stop("no watershed-group polygon for ", paste(missing, collapse = ", "),
         " — the collection publishes ", length(codes), " groups and bcdata returned ",
         nrow(out), call. = FALSE)
  }
  out
}


# ---- helpers ported from stac_dem_bc --------------------------------------------------------

`%||%` <- function(x, y) if (is.null(x)) y else x

my_tab_caption_rmd <- function(
    caption_text = my_caption,
    tip_flag = TRUE,
    tip_text = " <b>NOTE: To view all columns in the table - please click on one of the sort arrows within column headers before scrolling to the right.</b>") {

  cat(
    '<div style="text-align: center; font-weight: bold; margin-bottom: 10px;">',
    caption_text,
    if (tip_flag) tip_text,
    '</div>',
    sep = "\n"
  )
}

my_dt_table <- function(dat,
                        cols_freeze_left = 3,
                        page_length = 10,
                        col_align = 'dt-center',
                        font_size = '11px',
                        ...) {
  dat |>
    DT::datatable(
      ...,
      class = 'cell-border stripe',
      filter = 'top',
      extensions = c("Buttons", "FixedColumns", "ColReorder"),
      rownames = FALSE,
      options = list(
        scrollX = TRUE,
        columnDefs = list(list(className = col_align, targets = "_all")),
        pageLength = page_length,
        dom = 'lrtipB',
        buttons = c('excel', 'csv'),
        fixedColumns = list(leftColumns = cols_freeze_left),
        lengthMenu = list(c(5, 10, 25, 50, -1), c(5, 10, 25, 50, "All")),
        colReorder = TRUE,
        initComplete = htmlwidgets::JS(glue::glue(
          "function(settings, json) {{ $(this.api().table().container()).css({{'font-size': '{font_size}'}}); }}"
        ))
      )
    )
}


# ---- the figure and the map -----------------------------------------------------------------

# One colour per region, and the same four values feed the static figure and the interactive
# map, so the two cannot disagree about what Fraser looks like.
# Skeena is gold rather than blue: at 0.55 alpha a blue group fill sits too close to
# FLOODPLAIN_INK below, and the ribbons -- the thing the figure exists to show -- stop
# separating from the group they are drawn on. Measured by looking at the render.
REGION_COLS <- c(columbia = "#7570b3", fraser = "#1b9e77", peace = "#d95f02", skeena = "#e6ab02")

# Floodplain ribbons are drawn in one dark ink rather than by region: at 7,273 km2 over a
# ~950,000 km2 province they read as threads, and a thread carrying its own hue on top of a
# coloured group fill is less legible, not more. The group fill is what carries region.
FLOODPLAIN_INK <- "#08306b"

#' A region has a colour, or the map lies about it
#'
#' The static map assigns `REGION_COLS` to the data's SORTED levels while the legend labels are
#' hardcoded from `REGION_COLS`, so a region outside the set shifts the mapping with no way for
#' the legend to report it; the interactive map draws it `#999999` with no legend entry at all.
#' `!anyNA(region)` proves the join found a region, not that a colour exists for it.
fp_readme_check_regions <- function(props) {
  missing <- setdiff(unique(props$region), names(REGION_COLS))
  if (length(missing) > 0) {
    stop("no colour for region ", paste(sort(missing), collapse = ", "),
         " — add it to REGION_COLS, which the map and its legend both read", call. = FALSE)
  }
  invisible(TRUE)
}

#' The provincial coverage figure
#'
#' Watershed groups filled by region with the item floodplains stroked over them. The groups
#' are the layer that answers "what have we got" at this scale -- 7,273 km2 of floodplain over a
#' ~950,000 km2 province is ~1.2 km/px on a 1000 px-wide map, so a 500 m-wide ribbon is
#' sub-pixel and cannot carry the answer on its own. The ribbons are drawn anyway, as fill AND
#' stroke in the same ink, because they are the actual published extent.
fp_readme_fig <- function(fp, wsg, props, path = "fig/coverage.png", width = 9, dpi = 200) {

  fp_readme_check_regions(props)
  regions <- props |>
    dplyr::distinct(.data$wsg, .data$region) |>
    dplyr::rename(wsg_code = "wsg")
  w <- dplyr::left_join(wsg, regions, by = "wsg_code")
  stopifnot(!anyNA(w$region))

  bc <- bcmaps::bc_bound() |> sf::st_transform(3005)

  # Simplifying only what is DRAWN, not what is published. At 200 dpi and 9 in wide the map is
  # ~0.8 km/px, so a 100 m tolerance is a quarter-pixel and invisible -- it just keeps tmap from
  # walking 1.4 million vertices.
  fp_draw <- sf::st_simplify(fp, dTolerance = 100, preserveTopology = TRUE)

  lbl <- w |>
    sf::st_point_on_surface() |>
    suppressWarnings()

  # Canvas aspect must match the geographic extent or tmap centres the data and pads the rest
  # with white (cartography skill). BC Albers is metric, so the ratio is the bbox's directly.
  bb <- sf::st_bbox(bc)
  asp <- as.numeric((bb["xmax"] - bb["xmin"]) / (bb["ymax"] - bb["ymin"]))

  m <- tmap::tm_shape(bc, bbox = bb) +
    tmap::tm_polygons(fill = "grey96", col = "grey75", lwd = 0.4) +
    tmap::tm_shape(w) +
    tmap::tm_polygons(
      fill = "region",
      fill.scale = tmap::tm_scale_categorical(values = unname(REGION_COLS[sort(names(REGION_COLS))])),
      fill_alpha = 0.55, col = "white", lwd = 0.6,
      fill.legend = tmap::tm_legend(show = FALSE)
    ) +
    tmap::tm_shape(fp_draw) +
    tmap::tm_polygons(fill = FLOODPLAIN_INK, col = FLOODPLAIN_INK, lwd = 0.5) +
    tmap::tm_shape(lbl) +
    # `remove_overlap = FALSE` on purpose: the Fraser groups crowd, and a label tmap drops to
    # tidy the map reads as a group the collection does not publish. Crowding is the lesser lie.
    tmap::tm_text("wsg_code", size = 0.5, fontface = "bold", col = "grey10",
                  # A halo here draws the string again at each offset rather than blurring it,
                  # so 22 labels came out as 110 smeared copies. A white shadow is one extra
                  # draw and legible over both the group fills and the dark ribbons.
                  options = tmap::opt_tm_text(remove_overlap = FALSE, shadow = TRUE,
                                              shadow.col = "white")) +
    tmap::tm_add_legend(
      type = "polygons", title = "Region",
      labels = tools::toTitleCase(sort(names(REGION_COLS))),
      fill = unname(REGION_COLS[sort(names(REGION_COLS))]),
      fill_alpha = 0.55, col = "white"
    ) +
    tmap::tm_add_legend(
      type = "polygons", title = "", labels = "Published floodplain",
      fill = FLOODPLAIN_INK, col = FLOODPLAIN_INK
    ) +
    tmap::tm_scalebar(position = c("right", "bottom"), text.size = 0.5) +
    tmap::tm_layout(
      frame = TRUE,
      legend.position = tmap::tm_pos_in("left", "bottom"),
      legend.frame = TRUE, legend.bg.color = "white", legend.bg.alpha = 0.85,
      legend.text.size = 0.55, legend.title.size = 0.65,
      inner.margins = c(0.005, 0.005, 0.005, 0.005),
      outer.margins = c(0.002, 0.002, 0.002, 0.002)
    )

  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  tmap::tmap_save(m, path, width = width, height = round(width / asp, 2), dpi = dpi)
  # tmap writes 72 dpi into the PNG header whatever `dpi` says, and macOS/Safari size the image
  # from that header (cartography skill).
  if (nzchar(Sys.which("sips"))) {
    system2("sips", c("-s", "dpiWidth", dpi, "-s", "dpiHeight", dpi, shQuote(path)),
            stdout = FALSE, stderr = FALSE)
  }
  path
}

#' The interactive coverage map, for `index.html` only
#'
#' Watershed groups rather than floodplains, and the reason is measured rather than aesthetic:
#' the item geometry is 1.4 million vertices, and simplifying it to 222 m still leaves 11 MB of
#' GeoJSON -- which a `self_contained: true` page would have to embed. The groups carry the
#' region colouring and the popups carry every item's published figures; `fig/coverage.png` is
#' where the floodplain outlines themselves are drawn.
fp_readme_map <- function(wsg, props) {

  fp_readme_check_regions(props)
  # One popup per group, listing every item it publishes -- MORR has two, and a popup that
  # showed one of them would silently drop half a watershed group's catalogue.
  pop <- props |>
    # `fp_readme_km2()` is positional -- it indexes the frame it is HANDED. Mutating before the
    # arrange is therefore load-bearing, not stylistic: reversed, every km2 lands on the wrong
    # row and the map publishes one group's area under another's name. Caught by reading the
    # rendered popup (LARL showed SLOC's 117 km2), not by reading the code.
    dplyr::mutate(km2 = fp_readme_km2(props)) |>
    # Sorted, because `index.html` is a committed multi-megabyte artifact and the search has no
    # `sortby` -- unsorted input churns the file between otherwise identical renders.
    dplyr::arrange(.data$wsg, .data$flood_factor, .data$species) |>
    dplyr::mutate(
      line = glue::glue(
        "<b>{id}</b><br>{dplyr::coalesce(unname(SPECIES[species]), species)}, ",
        "ff0{flood_factor} &middot; ",
        "{fp_readme_int(km2)} km<sup>2</sup><br>",
        "loss {fp_readme_int(gross_loss_ha)} ha &middot; ",
        "gain {fp_readme_int(gross_gain_ha)} ha &middot; ",
        "net {fp_readme_int(net_ha, signed = TRUE)} ha",
        "{ifelse(deprecated, '<br><i>published deprecated — over-mapped</i>', '')}"
      )
    ) |>
    dplyr::summarise(
      popup = paste(.data$line, collapse = "<hr style='margin:4px 0'>"),
      region = dplyr::first(.data$region),
      .by = "wsg"
    )

  w <- wsg |>
    dplyr::left_join(pop, by = c("wsg_code" = "wsg")) |>
    dplyr::mutate(popup = paste0("<h4 style='margin:0 0 4px'>", .data$wsg_name, "</h4>",
                                 .data$popup)) |>
    sf::st_transform(4326)
  stopifnot(!anyNA(w$region))

  fill <- c(list("match", list("get", "region")),
            unlist(purrr::imap(REGION_COLS, \(col, reg) list(reg, col)), use.names = FALSE),
            list("#999999"))

  mapgl::maplibre(style = mapgl::carto_style("positron"),
                  bounds = sf::st_bbox(w) |> as.numeric()) |>
    mapgl::add_fill_layer(id = "wsg", source = w, fill_color = fill,
                          fill_opacity = 0.55, popup = "popup") |>
    mapgl::add_line_layer(id = "wsg-border", source = w, line_color = "#ffffff",
                          line_width = 1) |>
    mapgl::add_navigation_control(position = "top-right") |>
    mapgl::add_scale_control(position = "bottom-left", unit = "metric") |>
    mapgl::add_categorical_legend(
      legend_title = "Region",
      values = tools::toTitleCase(names(REGION_COLS)),
      colors = unname(REGION_COLS),
      patch_shape = "square", position = "top-left",
      style = mapgl::legend_style(padding = 4)
    )
}
