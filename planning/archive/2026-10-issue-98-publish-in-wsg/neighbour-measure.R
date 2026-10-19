suppressMessages(library(sf))
items <- sub("[.]json$", "", basename(Sys.glob("data/stac/*_all_ff04.json")))
inw <- list(); out <- list()
for (it in items) {
  x <- st_read(file.path("data/stac", it, "floodplain.gpkg"), layer = "all_ff04", quiet = TRUE)
  x <- st_transform(x, 3005)
  f <- as.logical(x$in_wsg)
  inw[[it]] <- st_union(st_geometry(x[f, ]))
  o <- st_geometry(x[!f, ]); out[[it]] <- if (length(o)) st_union(o) else NULL
}
s_in <- sum(vapply(inw, function(g) as.numeric(st_area(g)), 0)) / 1e6
U <- st_union(do.call(c, inw))                      # one union, built once
u_in <- as.numeric(st_area(U)) / 1e6
cat(sprintf("CRS: BC Albers (EPSG:3005)\n"))
cat(sprintf("sum of in_wsg areas   %.2f km2\n", s_in))
cat(sprintf("UNION of in_wsg areas %.2f km2   -> items' own ground overlaps by %.2f km2\n", u_in, s_in - u_in))
tot <- 0; cov <- 0
for (it in items) {
  if (is.null(out[[it]])) next
  tot <- tot + as.numeric(st_area(out[[it]]))
  cv <- suppressWarnings(st_intersection(out[[it]], U))   # U includes this item's own inside,
  if (length(cv)) cov <- cov + as.numeric(sum(st_area(cv)))  # but they are disjoint by construction
}
cat(sprintf("\ntotal outside strip      %.2f km2\n", tot/1e6))
cat(sprintf("covered by some item     %.2f km2  (%.1f%%)\n", cov/1e6, 100*cov/tot))
cat(sprintf("published by NOBODY      %.2f km2  (%.1f%%)\n", (tot-cov)/1e6, 100*(tot-cov)/tot))
