# 2026-09 — issue #59: publish all seven classified years for bulk, necr, lnth, kotl

Published the four areas `floodplains#79` re-ran onto the full annual land-cover span.
`bulk_co_ff04`, `necr_ch_ff04`, `lnth_ch_ff04` and `kotl_bt_ff04` now serve
`classified_2017` … `classified_2023` — 10 assets each → 14 — via four
`catalogue_release.sh --only` runs, one at a time, from a clean tree. The other nineteen items
did not move. No code changed: #61 had already made the year set a property of the item. The
served collection version stays `1.1.0`, because `--only` never publishes `collection.json`;
the next full release folds this in.

The substance of the issue turned out to be that **its headline acceptance criterion was
unsatisfiable**. It asked for the rebuilt `transition_2017_2023` to carry a `file:checksum`
equal to the published one. `02_raster_tag.py` stamps the item's provenance block into every
COG's TIFF tags, so widening the year set moves four of them and with them the bytes of files
whose pixels nobody touched — the checksum could not answer "did the values change" even in
principle. Replaced by two assertions that hold and were measured before every publish.

Closed by the PR opened from `59-publish-all-seven-classified-years-for-b`.

## Measurement

**`nge:landcover_key` reproduces exactly.** Folding only 2017/2020/2023 out of today's producer
`provenance.json` reproduces the value each of the four was serving *before* the re-run —
exact, 4 of 4, and re-derived independently in Python by a reviewer. Since the live value
predates the re-run, this is non-circular: it is this repo's own confirmation of
floodplains#79's element-wise claim, and it is what let the seven-year folds be *predicted*
before any build ran.

**Every pre-existing raster is pixel-, geometry- and RAT-identical** to the bytes S3 was
serving: decoded-band sha256, CRS, transform, shape, dtype, nodata, block shape, overviews,
compression, and the RAT read from TIFF tag 42112. `transition_vector.gpkg` is byte-identical
on all four, which is content equality of the transition layer.

**The other nineteen did not move**: identical on every property, `bbox`, geometry digest and
every asset's checksum/size/href/type; and in the bucket, 210 objects outside the four with
unchanged ETags, none added, none removed, `collection.json` never written.

**`floodplain_landcover.gpkg` grew 27–105%** (41.7→53.0, 30.8→49.6, 11.4→23.3, 21.3→42.5 MB),
carrying a polygon layer per year instead of three.

One defect found and filed rather than worked around: **floodplains#83** — `necr` and `kotl`
ship 30 stray gdalcubes/NetCDF tags per classified COG, two of which (`data#type='float64'`,
`data#_FillValue='nan'`) contradict a `uint8`/255 raster. Published anyway; they clear on the
next republish.

## Wrong turns, kept

- **The gate was built on the wrong property and refused its first item.** Byte equality was
  the plan's assertion; it can never hold. Rewritten to pixel/geometry/RAT identity.
- **The gate then refused twice more** on tags nobody had predicted — which is what found
  floodplains#83. It was widened *by name*, so an unnamed tag still fails; widening it to
  ignore tags would have hidden the defect it existed to catch.
- **The first baseline was too thin, and one item's window had already closed.** It captured
  assets and `nge:` only, so `bulk`'s pre-publish properties were unrecoverable from the API
  after its republish. Recovered from `data/readme_items.rds`, the git-tracked README render
  cache fetched 2026-09-04. The read-back now *refuses* a baseline that post-dates the
  republish rather than comparing an item to itself.
- **Thirteen false or imprecise statements in the release notes**, across three `/code-check`
  rounds — every one about the record, none about the data, which every round re-derived as
  correct. The worst two: a version-history claim wrong in three documents from one ancestor,
  and "nothing else changed" written while the largest asset in each bundle had doubled. Round
  3 named the mechanism (a summary sentence composed from the memory of a per-item measurement
  rather than re-derived from it) and closed the set by enumerating all 41 quantified claims.
- **A conformance probe that reported 16 of 16 failing** — it compared against `255` where
  `gdalinfo -json` emits `255.0`. The probe was broken, not the world; a 100% failure rate on
  freshly verified assets is the tell.

## Evidence

`planning/archive/2026-09-issue-59-publish-seven-years/` — `findings.md` carries every
measurement with its date; `review-round{1,2,3}.md` the reviewer rounds; `baseline_live.json`,
`baseline_full.json` and `baseline_rds_20260904.json` the pre-publish state the whole
verification is measured against.
