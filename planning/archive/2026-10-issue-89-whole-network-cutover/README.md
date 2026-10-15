## Outcome

Cut the whole-network cutover as one release at `v2.0.0`: retire all 23 live per-species
items, publish 23 `<wsg>_all_ff04` ones in a single upsert, and empty the deprecation
literals, which expired by their own mechanism once every group was rebuilt on `flooded`
0.7.0. `DUNC` joins the catalogue having never been published; MORR was the two-for-one
case `RETIRED_ITEMS` was built for.

**The build found a real defect, and the cutover is what created it.** `01_stage.R` dropped
io-lulc class 0 ("No Data") from drift's class table on a written premise that the published
rasters "never contain 0". That was true of every build before this one. The whole-network
floodplain reaches ground the species-accessible one did not, and io-lulc's 2020 composite
has a gap there: `kisp_all_ff04/classified_2020.tif` holds 58,540 cells of 0, while the
producer's `ch_ff04` raster for the same group and year holds none. Caught by this repo's own
`check_layer_styles`, not by a consumer. Fixed by keeping code 0 — 10 classes, RAT 10/100,
styles regenerated, COGs rebuilt.

**Five rounds of `/code-check`, because rounds 2, 3 and 4 each found a defect inside the
previous round's fix.** All one mechanism, which round 3 named: this repo's duplication
discipline was built for *strings* and its prose is full of *quantities*. All four
mechanically pinned pairs — licence block, provenance field map, committed QML bytes,
`RETIRED_ITEMS` against the NEWS entry — compare strings by equality. No measured quantity is
pinned by anything, and a stale quantity is fixed by measuring, where **a measurement taken at
the wrong scope is indistinguishable from a correct one**. It caught three corrections in a
row: comparing upstream's two gpkg bundles against all three staged ones; globbing all 25
upstream directories where the roster is 23; and relabelling a historical MB measurement as
MiB. Terminated by enumerating the candidate set on three axes and re-deriving every corrected
number through different tooling than produced it — not by a quiet round.

Only round 1 found anything behavioural, and it was worth the review on its own: step 6 ran
`item_unregister.sh` bare under `set -e`, so a partial delete (one `DO` block per id, one
`psql` under `ON_ERROR_STOP`, no transaction) killed the release before step 7 — the only
evidence the delete happened — and before the "this is recoverable, here is how" block.
`v2.0.0` is the first release to reach that code with a non-empty literal.

## Measurement

All on the v2.0.0 build, decimal MB, over the 23 **rostered** groups.

- Provenance: 23 rostered / 23 staged / floor **23**; census `link_run_uid` 18, the other
  eleven 23. `PROVENANCE_FLOOR` 21 -> 23, `PROV_CENSUS` rest 21 -> 23.
- Class table: 9 -> **10** classes, RAT 9/81 -> **10/100**, style categories 9/73 -> **10/91**.
  KISP 2020 holds 58,540 zeros of 3,555,686 valid cells (1.65%); one raster and one vector
  feature in the whole catalogue.
- Two gpkg bundles: upstream 1680.4 -> staged **1085.6 MB**, a saving of 594.8 MB; MORR
  116.3 -> 35.6 MB (-69%). `transition_vector.gpkg` a further 93.6 MB, excluded from the
  saving because it was never a whole-file copy.
- `check_checksums` re-reads **1338.3 MB** = three bundles 1179.2 + COGs 154.6 + QML 4.5.
- Item JSON 5.6-18.2 MB each, 252.6 MB total — the `--max-time 60` body read in the `--only`
  preflight is now against an 18 MB body.
- `attributes` layers: 66 in the landcover bundle, 0 in `floodplain.gpkg`, 23 more in
  upstream's `aquatic_network.gpkg` that nothing here reads. An all-directories glob says 68;
  `lit` and `neexdzii` are off the roster.
- 22 of 23 groups report layers no target claims (only DUNC is clean) until floodplains#131
  prunes them — reported, not refused.
- `NEWS.md` 47,156 B, top section 36,129 B: the pipe-buffer margin went 2.0x -> 1.8x.

Roughly twenty prose quantities were corrected. The cutover is why: every "N of 23" claim
survived, because the roster is still 23, and every per-item byte / layer / asset claim did
not, because what is *in* each item changed.

## Evidence

`planning/archive/2026-10-issue-89-whole-network-cutover/review-round{1..5}.md` — the five
code-check rounds, each with its own findings file and measurement tables.

Closed by: PR #94
