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


# ---- the one call, and its guards --------------------------------------------------------

#' Fetch every item in the collection, refusing anything short of all of them
#'
#' Returns a list: `features` (the raw STAC features, geometry included), `version` (the
#' catalogue version the API serves) and `n_bucket` (the item count the bucket's collection.json
#' claims). The guards are the point — see the block comment on each.
fp_readme_fetch <- function(api_root = API_ROOT, collection = COLLECTION, s3_base = S3_BASE) {

  q <- rstac::stac(paste0(api_root, "/")) |>
    rstac::stac_search(collections = collection, limit = 1000) |>
    rstac::post_request()

  fp_readme_check_complete(q, s3_base = s3_base)

  version <- rstac::stac(paste0(api_root, "/")) |>
    rstac::collections(collection) |>
    rstac::get_request() |>
    (\(x) x$version %||% "MISSING")()

  list(features = q$features,
       version  = version,
       n_bucket = fp_readme_bucket_count(s3_base))
}

#' The item count the BUCKET's collection.json claims
#'
#' Deliberately not the API's copy. pgstac rebuilds a served collection's `links` through
#' `get_links()`, dropping every rel in `INFERRED_LINK_RELS` — `item` among them — so the served
#' collection carries no `rel: item` links to count (measured 2026-09-04: the API serves
#' `items/parent/root/self/license/derived_from/queryables`). The bucket copy is written by the
#' release from the same build, so it is the independent side of the comparison.
fp_readme_bucket_count <- function(s3_base = S3_BASE) {
  coll <- jsonlite::fromJSON(paste0(s3_base, "/collection.json"), simplifyVector = FALSE)
  sum(vapply(coll$links, \(l) identical(l$rel, "item"), logical(1)))
}

#' Refuse a page that is not the whole collection
#'
#' Three arms, in this order and for this reason:
#'
#' 1. A `next` link means the search paged. This API sends no `numberMatched` (measured
#'    2026-09-02: only `numberReturned`), so completeness is "no next link".
#' 2. Zero features, checked ABSOLUTELY and BEFORE the cross-check — `0 == 0` would otherwise
#'    pass and a caller would render a table with a bare header.
#' 3. The count against the bucket's own claim. Either side disagreeing is a refusal.
fp_readme_check_complete <- function(q, s3_base = S3_BASE) {
  rels <- vapply(q$links %||% list(), \(l) l$rel %||% "", character(1))
  if (any(rels == "next")) {
    stop("search paged at ", length(q$features), " features — raise the limit", call. = FALSE)
  }
  n <- length(q$features)
  if (n == 0L) {
    stop("search returned no items — refusing to build an empty table", call. = FALSE)
  }
  n_bucket <- fp_readme_bucket_count(s3_base)
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
      km2 = dplyr::if_else(.data$flood_factor == 4,
                           .data$floodplain_ff04_km2, .data$floodplain_ff06_km2),
      Species = unname(SPECIES[.data$species]),
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
fp_readme_caption <- function(props, version) {
  regions <- sort(unique(props$region))
  paste0("*Generated from the live API at render time: ", nrow(props), " items across ",
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
      wsg                 = p$wsg,
      region              = p$region,
      species             = p$species,
      scenario            = p$scenario,
      flood_factor        = p$flood_factor,
      floodplain_ff02_km2 = p$floodplain_ff02_km2,
      floodplain_ff04_km2 = p$floodplain_ff04_km2,
      floodplain_ff06_km2 = p$floodplain_ff06_km2,
      gross_loss_ha       = p$gross_loss_ha,
      gross_gain_ha       = p$gross_gain_ha,
      net_ha              = p$net_ha,
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
