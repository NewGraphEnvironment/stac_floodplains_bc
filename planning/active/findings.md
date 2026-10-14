# Findings — Provenance key check: verify each item finds its scenario (#75)

## Issue context

### Problem

`scripts/fp_provenance.R` (around line 250) stops on any `floodplain` / `landcover` section key in a
`provenance.json` that does not match `^[a-z]{2}_ff[0-9]{2}$`. That refuses keys `floodplains` now
legitimately writes:

- `all_ff04`: whole-network floodplains (`species: all`, NewGraphEnvironment/floodplains#104). The
  Columbia region is moving to it.
- `wct_ff04`: any three-letter species code. `wct` is already listed in the Columbia region's
  species preference.

A provenance record says what produced a file at a point in time, so a newer iteration can be
compared against it. It should not decide what may be published. The check's own comment states the
failure it is there for: a re-keyed section (`ch_ff04` -> `ff04`) would make every item's lookup
miss and publish nulls on every item at once. A whitelist of key shapes is one way to catch that,
and it also blocks every new species and mode.

### Proposal

Replace the shape whitelist with a check on the item itself. For each item, its own scenario key
must be present in the `floodplain` section, and in `landcover` where the item carries land cover. A
miss stops with the key and the keys present. That catches the re-keying failure, since every lookup
misses, and admits any key `floodplains` writes.

Then let `all_ff04` through end to end: item id, item key property `species = all`, and the roster.
Items for species `all` publish **beside** the existing species items for the same groups (KOTL,
LARL, SLOC keep their `bt_ff04` items). Nothing published is replaced.

### Done when

- A `provenance.json` with `all_ff04` and `wct_ff04` keys stages without error.
- A fixture whose item scenario is missing from the record stops: the must-fail arm for the
  re-keying case.

Relates: NewGraphEnvironment/floodplains#104, NewGraphEnvironment/floodplains#123

---

## Measurement — the upstream tree, 2026-10-14

floodplains `main` at `a91acdb`; PR #132 for floodplains#125 (whole-network region mode) is
**merged**. Measured with stdlib `json` over `../floodplains/data/*/provenance.json`.

22 of 24 area dirs carry a `provenance.json`. `mcgr` and `pine` carry none — they are the two
`DEPRECATED_ITEMS`, and `fp_prov_read()` returns `NULL` for them, so no section check ever runs.

`all_ff04` exists **now** in four areas:

| area | `floodplain` keys | `landcover` keys | `network` keys |
|---|---|---|---|
| `bulk` | `all_ff02, all_ff04, all_ff06, co_ff02, co_ff04, co_ff06` | `all_ff04, co_ff04` | `all2, co3` |
| `kisp` | `all_ff02, all_ff04, all_ff06, ch_ff02, ch_ff04, ch_ff06` | `all_ff04, ch_ff04` | `all2, ch3` |
| `morr` | `all_*`, `ch_*`, `co_*` (nine) | `all_ff04, ch_ff06, co_ff04` | `all2, ch3, co3` |
| `dunc` | `all_ff02, all_ff04, all_ff06` | `all_ff04` | `all2` |

No `wct_ff04` key exists anywhere on disk; `wct` appears in no area config. It survives only as a
historical comment in `config/regions/columbia.yml`, which used to carry `species: [bt, wct]`. So
`wct_ff04` is admitted on principle (the producer's own validator is `^[a-z]{2,4}$`), not against a
file.

### The check is already firing, and it takes the whole group with it

`grep` at `fp_provenance.R:252` scans **every** key in the section with `invert = TRUE`, not just
the one being looked up, so `all_ff02` stops `bulk` even for the `co_ff04` item. Measured by running
the repo's own guard-test:

```
$ Rscript scripts/fp_provenance-check.R
... 100+ ok ...
real producer files
Error: provenance.json check: floodplain section key(s) 'all_ff02', 'all_ff04', 'all_ff06' are not
scenario ids of the form <species>_ff<NN>. ...
Execution halted
```

So `fp_provenance-check.R`'s real-file arms (`:312-330`) have **no coverage at all** today — the
script halts before reaching them. Fixing #75 restores them.

floodplains#125 records the same break from the producer's side: *"Publishing is frozen until
NewGraphEnvironment/stac_floodplains_bc#75. Any `all_*` provenance key in a rostered group stops
staging."* And `floodplains/scripts/floodplain_lcc/fp_region.R:24-38` names this repo's regex in a
comment as the reason `all_ff04` cannot publish.

### Premise for the replacement: zero misses across the whole roster

Cross-checked all 23 rostered groups (`config/regions/*.yml` -> `config/<wsg>/area.yml` ->
`primary_scenario`) against each area's section keys. **Every rostered target's scenario is present
in both its `floodplain` and its `landcover` section.** The new per-item check therefore passes on
the entire real tree, and the two areas with no record are unaffected.

### The roster moved underneath the issue body

No `area.yml` in the producer repo declares a `targets:` block any more, so each group stages the
single `(species, primary_scenario)` target (`01_stage.R:205-208`):

- `bulk`, `kisp`, `morr`, `dunc` read `species: all`, `primary_scenario: all_ff04`, `min_order: 2`.
- `kotl`, `larl`, `sloc` are still `bt` / `bt_ff04`; the whole Fraser roster is still `ch`.
- `config/morr/area.yml:9-12` says the `targets:` block naming `co_ff04` and `ch_ff06` is **gone**,
  retired under floodplains#125 / stac#76.

Two consequences the issue body does not describe:

1. The groups moving to `all_ff04` are **BULK, KISP, MORR** plus **DUNC** (new in `columbia.yml`),
   not KOTL/LARL/SLOC.
2. "Publish beside" holds for the **live catalogue** — registration is an upsert, nothing is deleted
   implicitly — but not for the **build**. A rebuild stages `morr_all_ff04` and no longer stages
   `morr_co_ff04` / `morr_ch_ff06`; those plus `bulk_co_ff04` and `kisp_ch_ff04` become live orphans
   that `catalogue_release.sh` reports and refuses to publish past without `--allow-retract`. That
   retraction is #76's work, not this issue's.

### `fp_provenance.R:252` is the only two-letter assumption in the repo

Everything else on the path is already length-agnostic, verified by reading each:

| checked | finding |
|---|---|
| `01_stage.R:219` | item id is `paste0(wsg, "_", scenario)` — `species` never enters it |
| `01_stage.R:338` | `sp_prefix <- sub("_ff.*$", "", scenario)` — `_ff`-anchored |
| `item_create.py:350` | `re.search(r"_ff(\d+)$", scenario)` — unanchored left |
| `item_create.py:452,710-713` | `species` is a pass-through property; summaries derived, not literal |
| `item_validate.py` | **no** item-id, species or scenario regex exists at all |
| `item_unregister.sh:31`, `catalogue_release.sh:102` | character-class guards, no length |
| `04_gpkg_style.py:57-61` | whole-file rule for `floodplain.gpkg`; prefix rules for the landcover bundle |

### The new items would pass the downstream gates

- **Year sets.** `bulk` records `2017..2023` (annual), `kisp`/`morr`/`dunc` record `2017/2020/2023`.
  Both are already in `ALLOWED_YEAR_SETS` (`item_validate.py:1006-1009`), so no literal moves.
- **`deprecated` biconditional.** `flooded` is 0.7.0 (bulk/kisp/morr) and 0.6.5 (dunc), both
  >= 0.5.0, so none is required to be marked and none may be.
- **drift skew.** The `all_ff04` landcover sections record drift 0.20.0 and installed drift is
  0.20.0, so these four groups need **no** `ALLOW_DRIFT_SKEW` override. (The species sections still
  skew; that is #69.)
- **Upstream layers.** `floodplain.gpkg` carries `all_ff02`/`all_ff04`/`all_ff06` — which
  `01_stage.R:338-348` requires — plus `all_ff04_by_blue_line_key`;
  `floodplain_landcover.gpkg` carries `classified_all_ff04_<year>` and
  `transition_all_ff04_2017_2023`; the rasters are under `rasters/all_ff04/`. Every one of those
  layers carries `wsg`, `species` and `scenario`, so `test_pipeline.R`'s attribute contract holds.
- `composition_all_ff04_2017_2023` and `patch_watercourse_all_ff04_2017_2023` are registered
  `data_type='attributes'`, so the three surfaces that walk layers skip them (#65, #70).

### Downstream consequence, deliberately out of scope (user decision, 2026-10-14)

`fp_readme_rows()` (`readme_functions.R:169-178`) refuses when a watershed group's items disagree on
`floodplain_ff04_km2`, because the once-per-group total has no rule for two populations. Measured
against the published items in the bucket and floodplains#125's run log:

| group | `all_ff04` | live species item |
|---|---|---|
| BULK | ~660.0 km² | `bulk_co_ff04` 386.53 |
| MORR | ~479.3 km² | `morr_co_ff04` 357.69 |
| KISP | ~324.4 km² | `kisp_ch_ff04` 190.32 |

So the first `all_*` item published beside a live species item refuses the README render. It fails
safe — a stop, not a wrong number — and #76 retires the species item per group, which ends the
two-item state. Filed as its own issue rather than fixed here.

(`morr_co_ff04` and `morr_ch_ff06` publish *identical* ff02/ff04/ff06, which is why MORR's two
items pass that guard today — the comment at `readme_functions.R` calls it "one physical
floodplain".)

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `curl` to `https://images.a11s.one/collections/stac-floodplains-bc/items` timed out at 40 s | Read the published item JSONs from the bucket instead (`https://stac-floodplains-bc.s3.us-west-2.amazonaws.com/<id>.json`), which is public for GetObject |

## Verification — the real tree, 2026-10-14

| run | result |
|---|---|
| `Rscript scripts/fp_provenance-check.R` | **81 assertions, 0 failed, 1 skipped**. The skip is the pre-existing stale `neexdzii` fold pin (upstream re-ran 2026-10-13); before this change the script *halted* on the real `bulk` file |
| `uv run python scripts/prov_fields-check.py` | 44 assertions, 0 failed |
| `uv run python scripts/year_sets-check.py` | 16 assertions, 0 failed |
| `Rscript scripts/stage_years-check.R` | 14 assertions, 0 failed — including **"a three-year item's `meta.json` is byte-identical to the pre-change build"**, so no staged output moved |
| `WSG=bulk Rscript scripts/test_pipeline.R` | **PASS.** `bulk_all_ff04` ff02 610.91 / ff04 659.99 / ff06 698.94 km² (floodplains#125's log says 660.0), seven-year span, 12/12 provenance fields, 25 style rows over three GeoPackages, RAT in all 8 COGs |
| `WSG=morr Rscript scripts/test_pipeline.R` | `morr_all_ff04` ff04 479.32 km² (#125: 479.3), three-year span, 12/12 fields, network matched on `inputs$species: all` against three sections — then failed `test_pipeline.R`'s own stale MORR literal (below) |
| `WSG=dunc Rscript scripts/test_pipeline.R` | stages, tags, COGs and styles; refused at `item_create.py` on an **upstream** record defect (below) |

### Two defects the verification found, neither in #75's change

**1. `test_pipeline.R` hardcoded MORR's retired two-target shape.**
`stopifnot("morr must stage morr_co_ff04 + morr_ch_ff06" = setequal(names(items), c("morr_co_ff04", "morr_ch_ff06")))`
failed a build `item_validate.py` had already passed. Fixed by deriving the expectation from
`area.yml` — the property is "a group stages exactly the targets its area.yml declares", which holds
for every group and cannot be contradicted by the roster it is about. An expectation naming ids
could only be contradicted by the roster; one derived from the roster can only be contradicted by
the stage.

**2. `dunc` cannot publish — an upstream record defect, filed as floodplains#133.**
`item_create.py` refuses a half-present `processing:software` `link` entry (version with no commit),
which is #74's biconditional working correctly. Two facts combine:

- DUNC's `link_log` is `null`, with `link_log_note: "no log row for DUNC in schema 'fresh'"` — a
  modelled absence, correctly honoured by `fp_prov_leaf`. `link_sha` is read from
  `link_log$link_sha`, so a null log means no commit.
- `inputs$link$sha` is **null on every `all2` section** (`sha_source: unresolved_version_mismatch`),
  while every species section on the same group resolved to `git` with a real sha. So there is no
  second source to fall back to.

| area | `network[all2]` `inputs$link` | `network[<sp><n>]` |
|---|---|---|
| `dunc` | `0.50.0`, sha null, `unresolved_version_mismatch` | — |
| `bulk` / `kisp` / `morr` | same | sha `2b5a435d…`, `git` |

BULK, KISP and MORR publish anyway because their `link_log` is present and supplies the commit.
DUNC is the one group where both sources are empty at once. Not a blocker for #75.

### A wrapper's exit is not the work

Both failing smoke tests returned **exit 0** from the backgrounded wrapper, because the command
ended `; echo DONE`. The failures were only visible in the log. Read the log, not the status.
