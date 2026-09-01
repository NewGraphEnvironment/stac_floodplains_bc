## Outcome

Every item now publishes `transition_vector` — the transition patches alone, without the three
dissolved classified epochs that carry nearly all of the bundle's geometry. Measured across all 20
items: **515 MB of bundles yields 70.2 MB of transition layers, 13.6%**. MORR is the extreme at
79 MB → 2 MB, because its bundle holds 18 layers for two species. Verified end to end: BULK's asset
downloads from S3 at 6,098,944 bytes against a 41,672,704 byte bundle, its checksum verifies, and it
contains a single layer named `transition`.

**A near-miss is the most valuable thing here.** The issue proposed `transition_2017_2023.gpkg`,
whose stem is *exactly* the transition COG's existing asset key. Keying the new asset by its stem
would have overwritten the COG in the assets dict — the item still shows the right asset count, the
raster silently disappears from the catalogue, and `item_validate.py`'s uniform-key-set check passes
because every item loses the same key. Nothing in the release path could have caught it: the probe
samples the largest asset, which is the bundle. Caught in exploration, before any code; the asset is
keyed `transition_vector`, and `test_pipeline.R` now asserts both transition keys survive.

**Naming is year-free at all three levels** — asset key, filename, and the layer inside the file —
on the user's reasoning that the span will move (2017-2023 → 2017-2025 → possibly 2010-2025 on
satellite data) and that QGIS styles bind to `path|layername=`. A span in any of those names breaks
every downstream style at the next re-model. Generic layer naming is safe *here* specifically
because the file is per-item and single-layer; identity rides on the item id and the layer's own
`wsg`/`species`/`scenario` columns. That reasoning reached one level deeper than the question asked
— the layer name inside the file is what symbology actually binds to, and it is the level most
easily missed.

**This is the first GeoPackage the repo writes rather than copies**, so `scripts/fp_gpkg.R` ports
floodplains#45's `OGR_CURRENT_DATE` pin. Without it GDAL stamps wall-clock time into
`gpkg_contents.last_change`, and this one asset's `file:checksum` would churn on every rebuild while
every other asset's stayed stable — a symptom that reads as "checksums are unreliable" and whose
cause is a single unpinned writer. The published bytes now carry `2000-01-01T00:00:00.000Z`, so the
pin is observable from outside. The guarantee is bounded to writes into an *absent* file, hence the
`unlink()` in `gpkg_write_layer()`.

The premise was **measured before any code was written**, because upstream had only proven it on a
different operation (18-layer replay, not a 1-layer extract): unpinned rebuilds `5429357d…` vs
`c2bfa94b…`; pinned, `ea0ac66f…` twice. `gpkg_determinism-check.R` sources the real writer rather
than reimplementing it, and its `NO_PIN=1` cold path asserts the rebuilds *differ* — if they matched
unpinned, the warm pass would be measuring nothing.

Code-check found five issues. The one worth remembering is that **a comment I wrote in this same
change claimed a guarantee the code did not provide**: I moved the extraction to read the staged copy
and then asserted metrics and vector "cannot describe different layers", while the metrics still read
upstream. Also: `file.copy()` returns `FALSE` rather than erroring, so a short copy would be hashed
and published with a checksum that *verifies against the corrupt bytes* — `item_validate.py` re-hashes
the same file and structurally cannot catch it.

**Method note on sequencing.** This needed a re-stage, but upstream is mid-remodel (#26), so a full
`run_pipeline.sh` would have published a mixed-vintage catalogue. Instead the new asset was backfilled
from the staged pre-remodel bundles using the same committed `gpkg_extract_layer()`, keeping the tree
uniform and the release purely additive. The full pipeline path was still exercised for real — the
staged tree was backed up, `WSG=sloc test_pipeline.R` ran end to end, and the tree was restored with
all 120 original assets md5-verified.

Closed by: PR #29.
