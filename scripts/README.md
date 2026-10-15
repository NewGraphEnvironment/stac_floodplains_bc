# scripts

Publish pipeline for the `stac-floodplains-bc` collection. Reads the already-produced
floodplain outputs from `$FLOODPLAINS_DATA` (default `../floodplains/data`) — this repo does
no floodplain modelling.

Two commands, deliberately separate:

```bash
bash scripts/run_pipeline.sh                        # rebuild locally — no network writes at all
bash scripts/catalogue_release.sh                   # validate → sync → register → verify
bash scripts/catalogue_release.sh --only <item_id>  # republish ONE item; never collection.json
```

Only the rebuild needs `$FLOODPLAINS_DATA` (~900 MB). A release needs AWS credentials and SSH to
the catalog host, so it can be cut from a machine that does not hold the source tree.

## Prerequisites

| for | needs |
|---|---|
| rebuild (`run_pipeline.sh`) | [`uv`](https://docs.astral.sh/uv/) — `uv run` syncs the env from `pyproject.toml` + `uv.lock` (pystac, rasterio; GDAL **3.12+**, which is what puts the class-label RAT inside the COG rather than in a sidecar). R with `sf`, `readr` and `drift`. A populated `$FLOODPLAINS_DATA` tree (~900 MB, default `../floodplains/data`) |
| release (`catalogue_release.sh`) | AWS credentials for `s3://stac-floodplains-bc`, and SSH to the catalog host. **Not** the source tree — which is the point of the split |
| README render | R with `rmarkdown`, `knitr`, `rstac`, `sf`, `geojsonsf`, `jsonlite`, `bcdata`, `bcmaps`, `tmap` (**v4**), `mapgl`, `DT`, `htmlwidgets`, `dplyr`, `purrr`, `tibble` and `glue`. Past the tag, so it need not be the release machine |

## Rebuild — `run_pipeline.sh`

| Step | Script | What |
|----|----|----|
| Stage | `01_stage.R` | Discover rostered WSGs + their publish targets; for each item (`<wsg>_<scenario>`, one per declared `(species, scenario)`) copy the classified/transition rasters into `data/raw/<item_id>/`; **write** `floodplain_landcover.gpkg` + `floodplain.gpkg` (ff02/ff04/ff06 delineations) into `data/stac/<item_id>/` holding **only that item's layers**, selected by each layer's own `wsg`/`species`/`scenario` (#80 — a whole-file copy would ship a target the group no longer publishes); extract the transition layer to `transition_vector.gpkg` (layer `transition`); derive per-flood-factor floodplain areas + tree metrics + footprint → `data/raw/<item_id>/meta.json` |
| Tag | `02_raster_tag.py` | Embed GDAL metadata tags from `meta.json` onto the **staged** rasters (WSG, species, scenario, region, floodplain area per flood factor ff02/ff04/ff06 km², gross loss/gain/net ha, run provenance, per-asset year). Before the COG conversion, not after — tagging a finished COG in place moves its main IFD to the end of the file (#33). Also authors the class-label RAT as a PAM `.aux.xml` beside each staged raster, which `03` absorbs into the COG (#34/#35) |
| COG | `03_cog.py` | Convert the tagged rasters to Cloud-Optimized GeoTIFFs → `data/stac/<item_id>/` via `rasterio.shutil.copy` (a GDAL `CreateCopy`), which carries the tags, colour table, band description **and the class-label RAT** through. This is the last step to touch a published byte. Python rather than terra since #34: only a RAT can put labels inside a `.tif`, and RAT-in-`GDAL_METADATA` needs GDAL 3.12+ while terra links 3.8.5 |
| Style | `04_gpkg_style.py` | Embed a `layer_styles` row per feature layer in all three GeoPackages, so QGIS opens them already coloured with the same palette the COGs carry in their RAT (#46). Stdlib `sqlite3` — a GeoPackage is a SQLite database and a style row is an INSERT, so no GDAL and no new dependency. `f_table_schema` is `''`, never NULL (QGIS matches with `= ''` and NULL never equals, so a NULL row is written, logs nothing, and the layer opens unstyled). No `gpkg_contents` row and no triggers, unlike QGIS's own writer: measured to auto-style fine without them, and registering the table adds a second wall-clock stamp that would churn `file:checksum`. `update_time` pinned to `GPKG_EPOCH`, read from `fp_gpkg.R` so the two cannot drift. A re-run compares first and skips the write, because SQLite bumps its header change counter on any write transaction |
| STAC | `item_create.py` | Build the collection + one `<item_id>.json` per target into `data/stac/`; asset hrefs under `<item_id>/`. Also hashes every asset into `file:checksum` + `file:size`. Build only — no validation, no network; the collection carries no `version` until `catalogue_release.sh` stamps it |
| Extract | `fp_gpkg.R` | Sourced by `01_stage.R`: pins `OGR_CURRENT_DATE` and writes single-layer GeoPackages into a fresh file (the only case the pin makes byte-reproducible) |
| Validate | `item_validate.py` | pystac-validate every document **on disk**, so what is checked is what ships. Requires exactly the staged item count, so a wrong `--base` fails instead of reporting `valid: 0` and exiting 0. Also re-hashes every asset and asserts the published `file:checksum`/`file:size` match the bytes |

### The step order is load-bearing for checksums

`02` tags the **staged** rasters and writes their class-label sidecars, `03` writes the COGs from
them, and `item_create.py` hashes what `03` produced. Hashing is correct only because it runs last.
**Anything that touches an asset after `item_create.py` publishes a checksum that silently does not match the
object** — so a new step that rewrites bytes belongs before `item_create.py`, not after.

The order also decides whether the labels ship at all. `03`'s `CreateCopy` is what folds `02`'s PAM
sidecar into the COG's own `GDAL_METADATA` tag; run in the other order the labels would sit in a
file the S3 sync excludes and geoserv's titiler could not fetch.

**All three GeoPackages are written here** — `transition_vector.gpkg` since #23, the other two
since #80, which replaced whole-file copies of the group's bundle with per-item writes. No
published asset is a verbatim upstream copy any more, so every one of their checksums is a
function of the R-side GDAL. That is why `01_stage.R` pins `OGR_CURRENT_DATE` via `fp_gpkg.R`:
GDAL otherwise stamps wall-clock time into `gpkg_contents.last_change`, and those checksums would
churn on every rebuild while every other asset's stayed stable — reading as "checksums are
unreliable" when the cause is a single unpinned writer. `gpkg_determinism-check.R` proves the pin
over all three, and its `NO_PIN=1` cold path proves the check can fail.

`file:checksum` is a multihash (`1220` + sha256), not a bare digest. The STAC schema only checks the
string is hex, so it accepts a bare digest and cannot catch a checksum of the wrong bytes; both are
asserted in `item_validate.py` instead. Verifying re-reads every asset — that is the cost
of the guard actually guarding something. The two GeoPackage bundles are the bulk of it: 643 MB
across the 23 rostered groups, measured 2026-10-14, down 184 MB from the whole-file copies #80
retired (827 MB). The tree total also carries the COGs and is re-taken at a full build.

## Release — `catalogue_release.sh`

| Step | What |
|----|----|
| 0 preflight | `PARTIAL_STAGE` absent; ≥1 item + `collection.json`; SSH reachable; the build compared against the **live** collection — refuses if any live item is missing; then the **version gate** — HEAD exactly at a `vX.Y.Z` tag, tracked tree clean, `NEWS.md` top entry naming that version — and `collection_version.py` stamps `collection.json` (STAC Version Extension) before anything is validated or published |
| 1 validate | the gate. Nothing below runs unless every document validates; on a full release the validator is also given `PROVENANCE_FLOOR` — a literal in the script, set by a human, naming how many items must carry provenance at all (#32), which also turns on the per-field census — the literal `PROV_CENSUS` in `item_validate.py` naming how many items carry a value for **each** of the twelve fields (#74). `check_collection_metadata` and `check_citation_premise` also run here: the licence, the six providers, both links and `sci:citation` asserted verbatim, and every item's `landcover:collection` **and** `landcover:stac_url` checked against what the citation attributes — the id and the host can move independently, and a host move alone would change the licensor (#47). `check_deprecated` asserts exactly `EXPECTED_DEPRECATED` publish `deprecated: true`, and that every item is marked **iff** its `processing:software` `flooded` entry is below 0.5.0 or unreadable — both directions, since an unmarked over-mapped item adds nothing to the provenance floor's count (#26). Under `--only` the release passes `--partial`, which drops exactly one arm — ids named in the literal but absent from the tree. A stray marker, and an item in the literal that is present but unmarked, are both still refused there |
| 2 sync assets | `aws s3 sync` — no `--delete`, no `--size-only`, `--exclude '*.json'` |
| 3 sync JSON | after the assets, so no document references an object that has not landed. **Two calls**: the item documents, then `collection.json` on its own, last. One `aws s3 sync` over both parallelises them, so a pass that uploaded the collection and then failed would leave it linking objects that were never written — and a reload-from-S3 deletes the collection's rows before discovering that (see **Retraction**) |
| 4 register | collection first (pgstac items reference the collection row), then items |
| 5 verify | collection 200; live ids match the build **both ways**; the largest asset of one item probed for size and its published `file:checksum` re-verified against the bytes on S3; the live collection's `version` equals the tag just released (under `--only`: unchanged); and, on a full release, the **deprecation markers** (#26) read back from the API and reconciled against the build — the field's whole purpose is that a consumer sees it — and the **licence** read back from both the API and the bucket copy: `license` against the constant, and `sci:citation` plus the `rel: license` and `rel: derived_from` hrefs compared against the collection.json this release published (#47). Compared by VALUE, not presence: pgstac rebuilds a collection's `links` array through `get_links()` — which is why the build's `rel: item` links are served as none — and the one thing it does to a link it keeps is rewrite the href |
| 6 retire | only when `RETIRED_ITEMS` is non-empty, and only once `fail` is 0 for every probe above: `item_unregister.sh` over exactly those ids, scoped to this collection. Placed here and not after step 4 on purpose — between register and verify it would precede every read-back that can veto the release, so one stale checksum would cost the deleted item ids as well as the release |
| 7 verify retirement | the collection re-read: none of the retired ids is in it, each answers 404 from the API, and the served set **equals** the build. Step 5 asks only for containment, because at that point the retirement has not happened yet and a re-run after a verify failure would otherwise be refused |

Validation gates the **asset** sync, not just the JSON. Bucket versioning is Suspended, so there is
no rollback from pushing the better part of a gigabyte of assets for a build that then fails.

Registration is an **upsert**, so nothing is deleted implicitly and the collection never serves
zero items mid-release. The cost is that an item dropped from the build stays live — fine when that
is deliberate and recorded, which is what `RETIRED_ITEMS` names and step 6 removes, and a refusal
when it is not: step 0 refuses any live item this build does not produce unless the literal names it
or `--allow-retract` waives it. See **Retraction**.

### Cut a release

A version means "the published catalogue is in this state" — the `NEWS.md` convention shared with
`stac_uav_bc` and `stac_dem_bc`. Scripts are not versioned separately: a tag says the live
catalogue (bucket + API) matches what that commit describes, which is why the release, not the
build, writes the stamp — the rebuild precedes the tag in every real flow.

```bash
# 1. rebuild — the build carries no version, so this can happen before the tag exists
bash scripts/run_pipeline.sh
# 2. describe the release at the top of NEWS.md: `## vX.Y.Z (YYYY-MM-DD)`, commit it
# 3. tag that commit — locally; the tag is pushed only once the release has succeeded
git tag vX.Y.Z
# 4. release — refuses unless HEAD is exactly at the tag, the tree is clean and the tag's
#    NEWS.md agrees; stamps collection.json, publishes, fails unless API + bucket serve it back
bash scripts/catalogue_release.sh
curl -s https://images.a11s.one/collections/stac-floodplains-bc | jq .version
# 5. only now publish the tag: a pushed tag says the catalogue IS in this state, and a release
#    that failed would otherwise leave a public tag for a state that never went live
git push origin vX.Y.Z
# 6. rebuild the repo README from what the API now serves, and commit it. On a release that
#    set RETIRED_ITEMS, this comes AFTER step 4 has done the retirement — which it does, in
#    band — because the README refuses to render while a group carries two items disagreeing
#    on floodplain_ff04_km2, and a whole-network item genuinely disagrees with the species one
#    it replaces (#79). This commit is past
#    the tag by design (the tag marks the catalogue's state, not the README), so it can happen
#    later, and on a DIFFERENT machine than the one that cut the release -- it needs R and
#    rstac, which a release-only machine has no reason to hold. The caption the render writes
#    names the version the table describes.
Rscript -e 'rmarkdown::render("README.Rmd", "github_document", params = list(rmd_on = FALSE, update_query = TRUE))'
Rscript -e 'rmarkdown::render("README.Rmd", "html_document", output_file = "index.html", params = list(rmd_on = TRUE, update_query = FALSE))'
```

Step 6 in that order, always: the `github_document` render is the one that refreshes
`data/readme_items.rds` and `fig/coverage.png` from the live API, and `index.html` reads the cache
it leaves. Reversed, the site publishes the previous release's figures.

`--only` republishes one item and never the collection, so it needs no tag and moves no version.
`--allow-retract` is a full release and stamps like any other. Between the tag and the release,
touch nothing tracked: the gate wants HEAD exactly at the tag (one tag on that commit) and a clean
tree, so tick the planning boxes afterwards. On a release-only machine, `git fetch --tags` first.
Never register `collection.json` by hand (`collection_register.sh` outside the release): a rebuilt
collection carries no version, and registering it would silently un-version the API.

## Retraction

Two different jobs, and the one you want is decided by whether anything takes the item's place.

| | **Replacement** (#76) | **Removal** |
|---|---|---|
| when | a group's item **id changes** — `<wsg>_ch_ff04` becomes `<wsg>_all_ff04` | a group leaves the catalogue with nothing in its place |
| driven by | `RETIRED_ITEMS` in `catalogue_release.sh` | `--allow-retract` |
| the release | unregisters them itself, in step 6, and step 7 requires the served set to equal the build | publishes past them; they stay live until you unregister them by hand |
| refuses if | any retired group is not covered by another item in the build | — |
| **never with** | `--allow-retract` — refused, because the flag waives the arms the literal depends on | a non-empty `RETIRED_ITEMS` — same refusal, read from the other side |

**Both are release-first.** The bucket's `collection.json` must stop linking an item *before*
its objects go, and the API must stop serving it before that:

```
publish the smaller/replacing collection  ->  pgstac delete  ->  S3 delete
```

Get that order wrong and a reload-from-S3 empties the collection. `rtj`'s
`stac_register-all.sh` reads the bucket `collection.json`, extracts every `rel: item` href,
**`DELETE`s every row of the collection**, and only then fetches each href — one 404 and it
aborts, having already deleted. rtj's own script records that happening to `stac-dem-bc`. So a
window in which `collection.json` links an object you have removed is a window in which any
reload serves zero items. `item_retract_s3.sh` refuses to open one.

### Replacement — a group moving to a new item id

```bash
# 1. upstream: point the group at its new scenario (config/<wsg>/area.yml), re-run it there
# 2. rebuild here — the old id is no longer produced, the new one is
bash scripts/run_pipeline.sh
# 3. set RETIRED_ITEMS in scripts/catalogue_release.sh to exactly the live ids being replaced,
#    name every one of them in the NEWS.md entry, and commit both with the version bump
# 4. tag, then release: it validates, syncs, registers, verifies, THEN unregisters the
#    retired ids and re-verifies that the collection serves exactly this build.
#    NO --allow-retract. The literal is what retracts; the flag would waive the arms that
#    check it, and the two are refused together for that reason.
bash scripts/catalogue_release.sh
# 5. only now the assets, which is the only irreversible step
scripts/item_retract_s3.sh --yes <retired-id> [<retired-id>...]
# 6. regenerate the README (release step 6) — AFTER the retirement, not before
```

**`--allow-retract` is not passed at step 4, and must not be** — the two are refused together.
The literal is what retracts: step 6 is gated on it alone. The flag waives the containment arm,
the group-survival arm, step 5's surplus arm and step 7's equality arm, so passing it alongside a
literal would delete every id in it with nothing left checking the result. The flag retracts
nothing by itself; it only permits publishing past an orphan.

Until step 5 runs, **the retirement is reversible**: no sync passes `--delete`, so each retired
item's document is still in the bucket and its pgstac row can be put back. `item_register.sh`
reads **local files**, so fetch it first and re-run the release afterwards — restoring the API row
alone leaves the API serving an item the bucket's `collection.json` no longer links, which is the
disagreement a reload-from-S3 turns into an empty collection:

```bash
aws s3 cp "s3://stac-floodplains-bc/<item-id>.json" "${TMPDIR:-/tmp}/"
scripts/item_register.sh "${TMPDIR:-/tmp}/<item-id>.json"
bash scripts/catalogue_release.sh      # re-run it, so bucket and API agree again
```

That is why the asset delete is a separate script, needs `--yes`, and refuses while the API still
serves the item, while the bucket `collection.json` still links it, or while this build still
produces it.

### Removal — a group leaving the catalogue

```bash
# 1. drop the group upstream (region roster / area.yml in the floodplains repo)
# 2. rebuild — the item is no longer produced
bash scripts/run_pipeline.sh
# 3. publish the smaller collection FIRST, so the bucket stops linking the item
bash scripts/catalogue_release.sh --allow-retract
# 4. then the API row
scripts/item_unregister.sh <item-id>
# 5. then the assets (irreversible)
scripts/item_retract_s3.sh --yes <item-id>
```

`--allow-retract` is required at step 3 because a build with fewer items than the live collection
is otherwise refused — that refusal is the guard against an accidental partial publish. It is also
what waives the arm that would otherwise refuse losing a watershed group entirely, which is the
whole difference between this recipe and the one above.

## Pilot — `catalogue_release.sh --only <item_id>`

Republish **one existing item** — its assets, its JSON and its pgstac row — so a change can be
piloted on one group and inspected live before a full release against a bucket with no rollback:

```bash
WSG=bulk Rscript scripts/test_pipeline.R                  # one-group tree, PARTIAL_STAGE written
bash scripts/catalogue_release.sh --only bulk_all_ff04    # that item only
```

What `--only` changes, step by step:

| Step | Under `--only` |
|----|----|
| 0 preflight | `PARTIAL_STAGE` interlock and the live-vs-build comparison are **skipped, out loud** — both guard `collection.json`, which is never published here. Instead: the item's JSON and asset dir must exist, and the item must **already be live** (a new item needs a full release, which updates the collection's extent/summaries/links) |
| 1 validate | the whole tree on disk, so with a full build present this re-hashes every asset; the provenance floor is **not** applied (a one-group tree cannot meet it) — instead step 0 refuses if any provenance value the live item serves is absent on this build's copy, per field — both sides canonicalised to the staged names so the comparison survives #74's rename — and refuses too if the **bucket** copy of the item publishes a different provenance key set, which is the only read that can see a contract change on an item whose values are all absent (the API drops nulls) |
| 2 sync assets | `aws s3 sync data/stac/<id> s3://…/<id>`, same excludes, no `--delete` |
| 3 sync JSON | `aws s3 cp data/stac/<id>.json s3://…/<id>.json` — **one explicit object**. The full path's `--include '*.json' --exclude '*/*'` sweep would carry `collection.json` with it, and a one-group tree's `collection.json` describes one group |
| 4 register | `item_register.sh` for that file; `collection_register.sh` is never run |
| 5 verify | item endpoint 200; collection **membership byte-identical** to the preflight read; size + checksum probes on that item; the live item read back from the API and its `assets` + `properties` compared to the build **wholesale** — the only proof the pgstac row changed, and checksums alone would miss a labels- or provenance-only republish |

`--only` refuses to combine with `--allow-retract` (retraction is a collection-level operation) and
composes with `--skip-sync`.

The property that makes this safe — no route under `--only` reaches `collection.json` — is
pinned by `catalogue_release-check.sh`, which runs the real release script against `aws`/`ssh`/
`uv`/`curl` shims and reads their argv logs. Its positive control is a full release on the same
fixture, which **must** be seen to sweep `collection.json` by the same greps; without that, the
`--only` zeros would be a search that has never matched anything.

```bash
bash scripts/catalogue_release-check.sh      # no network, no credentials; exit = failed assertions
```

The tree-loss numbers (`gross_loss_ha`, `gross_gain_ha`, `net_ha`) are computed once, during
staging, from each WSG's `transition_<sp>_ff04_2017_2023` gpkg layer (`from_class == "Trees"` vs
`to_class == "Trees"`, summing `area_ha`) and written to `meta.json` — so the tag and register
steps publish identical figures that trace directly to the modelled transition patches. Metrics
are computed in R (step 01) because the publish Python env carries no vector reader.

## Smoke test

`test_pipeline.R` runs one watershed group end-to-end (`stage → tag → COG → build → validate`),
through the **same** `item_validate.py` gate a release uses. It cannot touch S3 — nothing it calls
makes network writes — and it leaves a `PARTIAL_STAGE` marker that `catalogue_release.sh` refuses
to publish past as a collection; the one-group tree it leaves is exactly what
`catalogue_release.sh --only <item_id>` republishes, one item at a time and never `collection.json`. It builds and
validates every item that group stages (a group may declare more than one
`(species, scenario)` target). It also asserts the attribute contract: every layer of all three
published GeoPackages carries `wsg`, `species` and `scenario` matching the item — all three
since #80, which made the bundles item-scoped writes rather than whole-group copies and so made
the stronger assertion available. `floodplain.gpkg` is checked against the item's ff set rather
than its single scenario, because its ff02/ff06 delineations each record their own flood factor.
Use it after any change to the scripts, the floodplains data layout, or the STAC schema, before
a real full publish.

```
Rscript scripts/test_pipeline.R            # defaults to UFRA
WSG=necr Rscript scripts/test_pipeline.R   # any rostered WSG
WSG=bulk Rscript scripts/test_pipeline.R   # whole-network group: species `all`, 7-year span
```

## Classified year sets

The per-item span is read from the producer's record and asserted against the rasters staged
(#61). Two check scripts cover it, one per side, and neither runs from `run_pipeline.sh` — like
`fp_provenance-check.R`, they exercise guards a normal build never trips, so running them is
deliberate.

```
Rscript scripts/stage_years-check.R              # the staging call site, on a real upstream tree
uv run python scripts/year_sets-check.py         # item_validate.py's ALLOWED_YEAR_SETS arms
```

`stage_years-check.R` restores three defects in a sandboxed copy of one area and runs
`01_stage.R` over each: a raster the record names and disk lacks, a raster on disk the record
does not name, and a record naming a year nobody built. It skips out loud with no upstream tree.
`year_sets-check.py` drives `check_checksums` over synthetic trees with real bytes, including
the uniform-loss case a cross-item compare structurally cannot see (#23) and the `--partial`
partition (#26).

## The `--only` preflight

`scripts/only_preflight.py` is the comparison `catalogue_release.sh --only` makes before it
writes anything: it reads the live item from the API on stdin, the item this build would
publish, and the bucket's current copy, and prints one `|`-separated line of counts, lost
fields, dropped keys and gained keys. Stdlib only, run as `python3` rather than `uv run`,
because a release machine holds nothing but this repo and `catalogue_release-check.sh` shims
`uv`.

It is a file rather than an inline `python3 -c` for a measured reason (#74): as the argument of
a double-quoted shell string, bash reached it before python did, and three separate characters
broke it — a markdown backtick span that ran as a command on every preflight, the quoted phrase
in the comment recording that, and a `$(` the pattern written to catch both did not match.
`prov_fields-check.py` asserts that the release still calls the file, because reverting it
would bring the whole class back.

## Renamed provenance fields

The twelve provenance fields publish under `processing:*`, `link:*` and `landcover:*` (#74),
and an absent value omits its key. The arms that guard that shape are release-only or sit
behind the whole-tree checksum re-read, so a third check script drives them directly — and, like
the two above, it does not run from `run_pipeline.sh`.

```
uv run python scripts/prov_fields-check.py       # item_validate.py's #74 arms, over synthetic trees
```

Fixtures cover all three live populations (all twelve fields, only `link_run_uid` absent, none
at all), with real tagged GeoTIFFs for the COG-tag arms. It also joins the four publish-side
copies of the field map, which are deliberately not shared: it parses `item_create.py` and
`02_raster_tag.py`, imports `only_preflight.py`, and compares all three against the
validator's, plus one assertion that the release still calls `only_preflight.py` rather than
an inline program. A field dropped from both sides of any pair would otherwise be invisible to
every runtime arm. Removing each guard in a copy of `scripts/` turns assertions red — the table is in
`planning/archive/2026-10-issue-74-*/findings.md`.

All three grep for **that guard's own message** rather than reading an exit code: a suite with N
guards has N ways to exit 1, and only one of them is the evidence.

Two values in `stage_years-check.R` are pinned witnesses, each gated so a re-run reads as
"re-take the pin" rather than "the code broke" — `ufra`'s `produced_datetime` (upstream) and
the sf/GDAL/PROJ triple (this machine, because the areas and geometry in `meta.json` are
computed here).

## Where the floor and census numbers come from — `prov_census-measure.R`

**A measurement, not a gate** (#82). Every other `*-check.{R,py}` in this directory **asserts**
an expectation; this one **produces** one, which is why it is not named `-check`. A run that
exits 0 says nothing about whether the build is correct — it says "here are the numbers a human
sets". Nothing here reads its output automatically, and nothing should.

```bash
Rscript scripts/prov_census-measure.R      # exit 0: a census was printed; non-zero: none was
```

It prints, paste-ready and at column 0, all three literals that are re-taken together on the
build a release is cut from — `PROVENANCE_FLOOR` (`catalogue_release.sh`), `PROV_CENSUS`
(`item_validate.py`) and `prov_fields-check.py`'s fixture populations — because #75 found two of
the three stale and a block naming only the one being asked for leaves the others exactly as
findable as they were then. Before it existed the only routes were a full ~900 MB build or a
throwaway script. Two of the five literals of this shape; `ALLOWED_YEAR_SETS`,
`EXPECTED_DEPRECATED` and `RETIRED_ITEMS` are still read off a build.

**It is the pre-flight, not the authority.** A release rebuilds anyway, and `item_validate.py`
prints the same twelve counts from the *published* items as its `census:` line — which this
script also emits, in that line's exact format, so comparing the two is a `diff`. The build's
line is what the literals are set from; this saves the round trip, and the two agreeing is worth
more than either alone. The one way they differ by construction: `link_version` and `link_sha`
publish as a single `processing:software` entry, and `item_create.py` **raises** on an item
carrying one without the other, so this script can print two different counts for that pair
while no publishable build can. `prov_fields-check.py` refuses exactly that pasted census.

It needs `$FLOODPLAINS_DATA` and the config tree beside it and nothing else: no stage, no writes,
no network, no database. It walks the roster the way `01_stage.R` does and drives
`fp_provenance.R`, so the numbers come from the code the build reads provenance with rather than
from a second implementation of it — and it mirrors the build's **selection in the build's
order**, which is load-bearing: `01_stage.R`'s no-rasters skip sits above its first `fp_prov_*`
call, so a target with no rasters never reaches the reader. A rostered target sits in exactly that
state whenever its group's config is converted ahead of its run, and reading one raises — so the
issue's stated walk order would print no census on a tree a build is perfectly happy with. How
many are in that state is a property of the hour; the script names them.

**It refuses rather than print a short census**, because its output becomes a release gate and a
count low for any reason other than the data would be pasted into the floor and then satisfied by
a build that lost provenance. A failed read — unreadable record, a `schema_version` past the
reader's pin, a raster newer than the record describing it — prints every failure with its target
id and exits non-zero with **no census at all**. So does a run that staged nothing: a floor of 0
was once true and is also what a reader that found nothing produces. An **absent**
`provenance.json` is not a failure; it is the forward-only state, and such an item is what the
floor's denominator counts.

A skipped target is reported by name beside a banner and exits 0: the census still describes the
set a build of that tree stages, and such a build drops a `PARTIAL_STAGE` marker the release
refuses to publish past. The output also carries its own provenance — UTC timestamp, the resolved
`$FLOODPLAINS_DATA`, and the producer tree's `git describe` — because a census with no date is
the state #75 found the literals in, and a tree mid-write (an upstream run in flight) measures a
half-finished roster.

What it does **not** check, so exit 0 is never read as "this build will stage": it does not open
the GeoPackages (existence yes, readability no — the build's key arms need `sf`/GDAL, the
dependency separating "runs where a build cannot" from "needs the build env"), and it does not
compare `drift_version` against the installed `drift`, for the same reason. Both make a real
build stage fewer items or stop outright, so its count can only sit at or above what such a
build publishes. It does run `fp_prov_span()`, `fp_years_reconcile()` and
`fp_prov_rasters_current()`, in the build's own order, so the first refusal it shows is the one
the build would.

It **mirrors** `01_stage.R`'s roster walk rather than sharing one, which is the duplication this
repo normally refuses — #90 tracks extracting an `fp_roster.R` both scripts source. Until then
`prov_fields-check.py` statically asserts that both files still carry the three expressions that
decide what is counted: the `[[`-not-`$` target read, the anchored `classified_` pattern, and the
directory-only raster skip.

## Determinism check

`gpkg_determinism-check.R` proves the GeoPackage timestamp pin is doing its job — extract the same
layer twice and assert byte-identical output.

```
Rscript scripts/gpkg_determinism-check.R              # warm path: rebuilds must MATCH
NO_PIN=1 Rscript scripts/gpkg_determinism-check.R     # cold path: rebuilds must DIFFER
ITEM=bulk_all_ff04 Rscript scripts/gpkg_determinism-check.R
```

The cold path is the point. A guard nobody has seen fail is decoration, so `NO_PIN=1` asserts the
rebuilds **differ** and errors if they match — if it passes, the warm run was measuring nothing.
Measured on `sloc_bt_ff04`: unpinned `5429357d…` vs `c2bfa94b…`; pinned, both `ea0ac66f…`.

## Layer styles

`style_qml-write.py` generates the three QGIS styles this repo ships, all from the one
`data/raw/classes.json` that already feeds the RAT and `classification:classes` — so the vector
palette cannot disagree with the labels inside the COGs (#46).

```bash
uv run python scripts/style_qml-write.py      # regenerate styles/*.qml
uv run python scripts/style_drift-check.py    # committed styles still match classes.json?
                                             # (also run by run_pipeline.sh, before step 04)
```

| Style | Applies to | Renderer |
|---|---|---|
| `styles/floodplain.qml` | every layer of `floodplain.gpkg` — `<sp>_ff02/04/06`, plus `_by_blue_line_key` on 18 of 23 groups | single symbol, ColorBrewer Paired blue |
| `styles/classified.qml` | `classified_<sp>_<scen>_<year>` and its `_patches` variant in `floodplain_landcover.gpkg` (upstream only — no published item carries a `_patches` layer since #80) | categorized on `class_name`, 9 io-lulc classes |
| `styles/transition.qml` | `transition` in `transition_vector.gpkg`, and `transition_<sp>_<scen>_<y1>_<y2>` | categorized on `transition`, 72 pairs |

All symbols ship at **50% opacity** — these layers are read over a basemap. Transition patches
are coloured by **destination class**, the same choice the transition COG makes, so the raster and
vector views of one item agree. The 8 `Trees -> *` loss categories ship switched **on**; the other
64, including the 8 `<other> -> Trees` gain categories, ship switched **off**, so widening the view
is a checkbox rather than a re-classify. File names are year-free so a QGIS `path|layername=`
style survives a change of span.

The styles are **committed**, not generated during a build, so a human reviews what ships — which
is why the drift check exists: `01_stage.R` rewrites `classes.json` from drift on every run, and
nothing else would notice that `styles/` had not followed. It is two-sided on the file set as well
as the bytes, and refuses when it compared nothing.

Symbol and category UUIDs are derived (`uuid5` over a fixed namespace), never `uuid4`. A random id
makes the generator non-deterministic at identical byte length, which would defeat the byte-compare
and churn `transition_vector.gpkg`'s published `file:checksum` on every rebuild. The drift check
caught exactly that on its first run.

### Style determinism check

`gpkg_determinism-check.R` covers GDAL's timestamp pin. It cannot cover the style step:
`04_gpkg_style.py` writes through `sqlite3`, which GDAL never sees, so `OGR_CURRENT_DATE`
does not reach it and the style carries its own pin.

```bash
uv run python scripts/style_determinism-check.py            # warm: rebuilds must MATCH
NO_PIN=1 uv run python scripts/style_determinism-check.py   # cold: rebuilds must DIFFER
ITEM=bulk_all_ff04 uv run python scripts/style_determinism-check.py
```

Three properties, measured on `kotl_bt_ff04`: two writes with the pin are byte-identical
across all three GeoPackages; two writes with a wall-clock stamp differ (the cold path, so a
warm pass means something); and re-running the style step does not move a single byte.

That third one is not obvious. SQLite bumps its header change counter on **any** write
transaction, so a writer that rewrote identical rows would still republish a new
`file:checksum` for unchanged content. The writer compares the rows first and skips.

### Verifying a style against QGIS itself

A style that reloads in our own reader proves only self-consistency. The question that matters
is what **QGIS** does with a layer opened plain, with no `.qml` handed to it — which is how a
style that loads cleanly and renders nothing gets caught.

```bash
R=/Applications/QGIS-final-4_2_1.app/Contents/Resources
PYTHONPATH="$R/python3.12:$R/python3.12/site-packages:$R/python3.12/lib-dynload" \
  /Applications/QGIS-final-4_2_1.app/Contents/MacOS/python3.12 probe.py
```

`PYTHONHOME` does **not** work: the bundle's stdlib is at `Resources/python3.12`, not the
`Resources/lib/python3.12` that PYTHONHOME implies, so it dies with
`ModuleNotFoundError: No module named 'encodings'` before running a line. Put the stdlib on
`PYTHONPATH` instead. In the script, `QgsApplication.setPrefixPath(".../Contents/MacOS", True)`
then `QgsApplication([], False)` and `initQgis()`.

Two API details that each cost a retry: `renderer.symbols()` requires a `QgsRenderContext()`
argument rather than `None`, and a raster's embedded palette reads back as
`layer.renderer().classes()` with `.value` / `.color` / `.label` per entry.

This is how the #46 styles were verified — all 24 layers of a multi-target group opened plain,
renderer and symbol opacity read back from QGIS — and it is what #48 will need for raster
opacity. `item_validate.py` covers the same ground without QGIS for anything that runs in the
pipeline; this is for the questions only the real consumer can answer.

## Provenance reader check

```bash
Rscript scripts/fp_provenance-check.R
```

Proves `fp_provenance.R` — the one file that knows the producer's `provenance.json` shape — offline:
a synthetic schema-2 document mutated per guard (schema pin, renamed section, renamed leaf,
modelled-null `link_log`, the `landcover_key` fold, rasters newer than their record), plus the
producer's own `$FLOODPLAINS_DATA/{bulk,neexdzii}/provenance.json` when present, skipped out loud
when not. Exit status is the number of failed assertions. Run it whenever the reader or the
upstream writer changes; it is the only exercise of the reader that needs no stage.

The section headed **"the item's own scenario key (#75)"** is the one whose *passing* direction is
the subject. Its two must-fail arms re-key a section (`co_ff04` -> `ff04`) in `landcover` and in
`floodplain` and grep for that arm's own message; its controls prove what the retired key-shape
whitelist refused — `all_*` and `wct_*` siblings beside `co_ff04` do not stop the `co_ff04` item,
and a whole-network record (`network[all2]` with `inputs$species: all`, floodplain keyed
`all_ff02/04/06`) reads end to end through `fp_prov_item()` and `fp_prov_span()`. Two further
controls hold the line on either side of it: an absent section is still the forward-only state and
does **not** stop, and a section that reads back as a JSON array is refused before `[[scenario]]`
can report a schema break as "subscript out of bounds". A real-file arm that *halts* rather than
failing is the tell that the reader has stopped on a key: measured 2026-10-14, the whole script
halted on the real `bulk` file, so its producer-file arms had no coverage at all.

A following section covers **the two states that satisfy the name check and still cannot be read**,
both found in review and both measured before being fixed. A **duplicate** JSON key survives as a
duplicate list name, `%in%` is TRUE and `[[` takes the first — a planted sibling published its own
`flooded` version silently, which is the one failure class that publishes a wrong value rather than
an absence, and which the network arm 50 lines above already refused. A key whose **value is null**
published seven NAs and sent a recorded item down the unchecked disk-discovery path. Its fixtures
are raw JSON rather than `synthetic()`, because `jsonlite::write_json` cannot emit a duplicate
object key from an R list.

## Attribution drift check

```bash
uv run python scripts/attribution_drift-check.py
```

`ATTRIBUTION.md` reproduces the `sci:citation` sentence, the landcover collection id and the
outbound licence — a fourth and fifth copy of literals this repo deliberately duplicates rather
than shares, and until #53 the only copies nothing asserted. They are also the copies a licensor
actually reads, so an upstream move to `v03` would turn `check_citation_premise` red on the
machine-readable surface while the human-readable one went on claiming the old attribution.

Compares against `item_create.py` by full equality, resolving `CITATION`'s f-string placeholders
from the same file and stripping only markdown decoration. The constant arms read the **parsed
value**, not whether the literal appears somewhere in the file: a first version asked the latter
and stayed silent through a `v02` → `v03` mutation, because a comment still named `v02`.

Proven in both directions — clean tree exits 0 with no arms; changing one word of the blockquote,
the collection id, or the licence each exits 1 naming the arm that fired.

## Environment flags

| Flag | Effect | Risk |
|----|----|----|
| `WSG_ONLY=<wsg>` | Restricts `01_stage.R` to one group and drops a `PARTIAL_STAGE` marker. Used by the smoke test; `run_pipeline.sh` refuses to start if it is set, and `catalogue_release.sh` publishes the result only under `--only` | safe |
| `NO_PIN=1` | Disables the GeoPackage timestamp pin in `gpkg_determinism-check.R` only — the cold path that proves the check can fail | safe (check only) |
| `ITEM=<item_id>` | Which staged item `gpkg_determinism-check.R` and `style_determinism-check.py` exercise (default `sloc_all_ff04`, the smallest) | safe |
| `AREA=<wsg>` | Which upstream area `stage_years-check.R` builds its sandbox from (default `bulk`). Its scenario comes from that area's own `primary_scenario`, and the mutated years from its own record, so `AREA=bulk` exercises the reconciliation guard against a whole-network annual span rather than only a three-year one. A group declaring `targets:` is skipped out loud — the arms drive one scenario. The `meta.json` digest pin is `ufra_ch_ff04`'s and now skips permanently — floodplains#125 moved ufra to `all_ff04`, so no build produces that item; see the comment beside the pin | safe (check only) |
| `GEOSERV_HOST` | Overrides the catalog host (default `root@geopro`, the tailnet node name) | safe |
| `ALLOW_SKIPPED=1` | Suppresses the `PARTIAL_STAGE` marker when a rostered group was skipped (not modelled yet) | **disables an interlock** |

The last one exists for deliberate one-off cases and **persists for the whole shell if exported**,
so `run_pipeline.sh` prints a loud banner when it is set. Publishing fewer items overwrites the
live `collection.json`, and bucket versioning is Suspended — there is no undo. The equivalent for
a release is the explicit `--allow-retract` flag rather than an env var, for the same reason.

Catalog registration is owned by this repo (`item_register.sh`, `collection_register.sh`,
`item_unregister.sh`). `rtj` still manages the server itself, and its `stac_register-all.sh` can
reload this collection **from S3** — harmless, because step 3 syncs the JSON before step 4
registers it, so the bucket and the API always agree.
