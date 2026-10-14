# Task: Stage each item's GeoPackages with only that item's layers (#80)

## Context

`scripts/01_stage.R:337-350` copies `floodplain.gpkg` and `floodplain_landcover.gpkg`
**whole** from `$FLOODPLAINS_DATA/<wsg>/` into every item's staging dir. That was
self-describing while a shared bundle held two species' layers of one group. It stops being
self-describing now that groups are whole-network: upstream keeps the retired species layers
on disk until floodplains#131 prunes them, so `bulk_all_ff04` publishes **BULK's coho
floodplain and coho transition** inside the whole-network item's own assets — two floodplain
models, built on different networks and (after floodplains#117) different DEM grids, with
nothing in the item saying which is current.

The decision was taken in #75 ("staging copies only the item's own layers") and split out to
#80 to build, because it converts a copy into a write and moves the bytes of every published
GeoPackage.

Nothing catches it today, verified by reading each gate: `test_pipeline.R:370` asserts only
`wsg` per layer (and its comment says why — the whole copy makes `wsg` the one item-invariant
key); `04_gpkg_style.py:57-61` styles `floodplain.gpkg` whole-file and the landcover bundle by
`classified`/`transition` prefix, so the extra layers are styled and valid; `item_validate.py`
requires every feature layer to carry a style row, which they do.

### What was measured, 2026-10-14

Enumerated over all 24 upstream area dirs, both GeoPackages, via `gpkg_contents` + `PRAGMA
table_info` + `SELECT DISTINCT`:

| fact | value |
|---|---|
| layers carrying `wsg`/`species`/`scenario` (floodplains#30) | **276 of 276** |
| distinct values per key column per layer | **exactly 1**, every layer |
| `data_type` split | 246 `features`, 30 `attributes` |
| groups carrying foreign layers | **bulk (14), kisp (9), morr (25)** — all whole-network; the other 21 rostered groups have none |
| multi-layer fresh `vectortranslate`, two runs, pin set | **byte-identical** (UFRA landcover, 5 layers incl. one aspatial) |
| same, pin unset | **differ** — the cold arm can still fire |
| `vectortranslate` preserves | `data_type='attributes'`, layer schema (identical `ogrinfo -so`), `gpkg_extensions` (4), rtree indexes (16 tables) |
| `sf::st_read(query=)` on an aspatial table | works, returns a plain `data.frame` |
| size effect | morr landcover 91.8 → 23.1 MB, morr floodplain 24.5 → 12.2 MB, kisp landcover 38.4 → 23.9 MB |
| `st_layers()` vs `gpkg_contents` | identical counts on all 10 files spot-checked, so the selector walks the surveyed population |
| a layer name the source lacks | `gdal_utils()` **warns only**, and leaves a 65,536-byte unopenable file |

So issue item 1 — *"whether a fresh sequential append is reproducible is an open empirical
question"* — is **answered, and the question is moot**: a single `vectortranslate` call taking
the layer names as trailing positional arguments writes all N layers into an absent file in
one pass, so there is no append at all. It is deterministic with the pin and non-deterministic
without it.

Two notes the plan depends on:

- **`neexdzii` keeps zero layers under the filter**, because its `wsg` column reads `BULK` (it
  is a subset of BULK, `config/regions/skeena.yml:29` excludes it from the roster). It never
  stages, so this is not a defect — but it is why the zero-layer guard in Phase 2 is real
  rather than defensive.
- **The key asymmetry is a property of the data, not an oversight.** In `floodplain.gpkg` the
  ff02/ff06 delineations carry their *own* flood factor (`all_ff02` has `scenario =
  "all_ff02"`), and the item publishes all three, so the match there is on `(wsg, species)`.
  In `floodplain_landcover.gpkg` every own layer carries `scenario` == the item's, so the match
  is on all three.

### Decided at this gate (airvine, 2026-10-14)

- **A layer matching no rostered item is reported, not refused.** A per-item `message()`
  naming the dropped layers plus one end-of-run census count. No `ALLOW_*` override: the
  retired layers are the expected state for bulk/kisp/morr until floodplains#131, so a stop
  would be overridden on every release of those three — a guard that fails toward pass.
- **The aspatial tables are reported, not whitelisted.** `patch_watercourse_*` and
  `composition_*` ship as they do today, item-scoped; one line per item names them so the
  undescribed families are visible in every stage run. Their descriptions stay #65/#70, and
  no second hand-maintained literal is added here.

## Phase 1 — the writer

`scripts/fp_gpkg.R`

- [ ] Add `gpkg_copy_layers(src, dst, layers)`: unlink `dst`, then one
      `sf::gdal_utils("vectortranslate", source = src, destination = dst, options = layers)`.
      **Two guards on the call, both measured necessary.** Given a layer name the source does
      not hold, `gdal_utils()` only **warns** (`GDAL Error 1: Couldn't fetch requested layer`)
      and leaves a 65,536-byte file that `st_layers()` cannot even open — so wrap it in
      `withCallingHandlers(warning = )` and stop on any warning (`code-check-spatial.md`,
      "`sf::gdal_utils()` does not raise when GDAL cannot open the source"), **and** assert
      afterwards that `sf::st_layers(dst)$name` is `setequal()` to `layers`. The written file
      is the thing to test, not the call's return.
- [ ] Add `gpkg_item_layers(src, wsg, species, scenario = NULL)`: for every layer
      `sf::st_layers(src)$name`, read its key with
      `SELECT DISTINCT wsg, species, scenario FROM "<layer>"` and classify it **own** /
      **foreign** / **unattributable** (missing a key column, or not exactly one distinct
      value per column — the measurement says neither happens today, so this arm is what
      would surface it changing). Return all three vectors; the caller decides.
      Layer names are interpolated into SQL, so they go through `"` quoting exactly as
      `test_pipeline.R:374` already does.
- [ ] Extend the file's `SCOPE OF THE GUARANTEE` header with the multi-layer measurement
      above, replacing the "rewriting into an existing gpkg is not reproducible" bound's
      implication that multi-layer is out of reach — the bound itself stays true and stays.

## Phase 2 — staging writes the filtered bundles

`scripts/01_stage.R:337-350`, replacing the two `file.copy()` calls

- [ ] For each of the two bundles, classify the source layers and write only the own set:
      `floodplain.gpkg` keyed on `(wsg, species)`, `floodplain_landcover.gpkg` on
      `(wsg, species, scenario)`. State the asymmetry and its measurement in the comment.
- [ ] **Stop** when the own set is empty for a rostered item (`neexdzii`'s shape), naming the
      keys looked for and the keys found. A filter that removed everything makes every later
      assertion in the loop vacuous.
- [ ] **Stop** when the item's headline-scenario layer or any of `<sp>_ff02/04/06` is not in
      the own set. This is the existing assertion at `:385-391`, moved onto the staged file so
      it asserts what ships.
- [ ] **Report** foreign and unattributable layers per item, and accumulate a census, in the
      idiom `01_stage.R` already uses for `traced` / `year_untraced` / `drift_untraced`
      (`:504-528`): a per-item `message()` plus one end-of-run count line naming the items.
      Not a stop: 3 of 24 rostered groups legitimately carry retired-species layers until
      floodplains#131, so a stop blocks every release. Not a silence either — #75's decision
      is explicit that a layer matching no item surfaces as a decision.
- [ ] Also report the **aspatial** tables kept per item. They ship (`patch_watercourse_*`,
      `composition_*`) and nothing here describes them (#65/#70); `04_gpkg_style.py`'s
      `feature_layers()` filters them out, so its "matches no style rule" stop cannot see a
      new aspatial family. One line per item is what makes that hole visible.
- [ ] Point `fp_gpkg` at the **staged** copy (`:381`) so `read_area_km2()`, the footprint
      geometry and the EPSG all describe the published bytes — the rationale already written
      at `:361-368` for the transition extraction and at `:417-419` for the metrics. Requires
      the write to precede the area reads, which it does.

## Phase 3 — the guards

- [ ] `scripts/test_pipeline.R:340-385` — tighten from "every layer carries `wsg`" to "every
      layer carries this item's key", with the per-file asymmetry, and rewrite the comment
      explaining why only `wsg` was assertable (it is the thing this issue removed). Keep the
      `feature_layers()` filter's reason intact, and keep asserting the zero-layer case.
      `transition_vector.gpkg` stays on the single-layer assertion it has.
- [ ] `scripts/test_pipeline.R` — assert the staged bundles hold **no** layer outside the
      item's own set. The positive check above is satisfied by a subset; this is the arm that
      fails on the defect as it exists today.
- [ ] `scripts/gpkg_determinism-check.R` — extend to the multi-layer bundles. Build each of
      the two filtered bundles twice through `gpkg_copy_layers()`, 1.2 s apart, from the
      staged tree, and compare md5. `NO_PIN=1` must still make them **differ** — measured
      above that it does, so the cold arm is not decoration. Keep the existing
      `transition_vector` arm.
- [ ] Restore the defect and prove the new guards fire: stage a group with foreign layers
      (`WSG=morr` or `WSG=bulk`) with the filter bypassed, and confirm the two
      `test_pipeline.R` arms go red.

## Phase 4 — the prose that goes stale

- [ ] `scripts/style_qml-write.py:20-25` — "MORR has nine, including `<sp>_ff04_by_gnis_name`
      and `<sp>_ff0N_by_blue_line_key`" and "A multi-target group holds both species' layers in
      one file" are both false of a staged bundle afterwards. MORR stages four floodplain
      layers; the `_patches` families exist only for MORR's retired species and stop shipping.
      The styles themselves do not change (`style_drift-check.py` byte-compares them), so this
      is docstring only — verify that by running it.
- [ ] `scripts/04_gpkg_style.py:52-55` — the comment's reasoning survives; the claim about
      what the landcover bundle holds does not.
- [ ] `scripts/item_create.py:409-421` — the two GeoPackage asset titles/descriptions now
      describe an item-scoped file.
- [ ] `CLAUDE.md` — the Collection model's "Assets per item" paragraph, the
      `floodplain_landcover.gpkg also ships a table this repo does not describe` paragraph
      (the per-area counts move), and `01_stage.R`'s entry under Layout: this repo now writes
      three GeoPackages, not one.
- [ ] `NEWS.md` — one entry, with the measured size deltas and the fact that every item's
      `file:checksum` for these two assets moves.

## Out of scope, named

- **The release.** Republishing is the next full release, which syncs the whole tree and
  re-registers every item anyway. `PROVENANCE_FLOOR` and `PROV_CENSUS` are exact literals
  re-taken on the build that release is cut from (CLAUDE.md), and DUNC cannot publish until
  floodplains#133 — so no literal moves here.
- **Retracting the live orphans** (`bulk_co_ff04`, `kisp_ch_ff04`, `morr_co_ff04`,
  `morr_ch_ff06`) — #76.
- **Describing `patch_watercourse_*` / `composition_*`** — #65/#70. This issue reports them;
  it does not document them.
- **Upstream's prune** — floodplains#131, which this change demotes to disk hygiene.

## Validation

- [ ] `WSG=bulk Rscript scripts/test_pipeline.R` — the group whose defect the issue names;
      asserts stage → tag → COG → STAC → validate end to end, and the two new layer arms.
- [ ] `WSG=morr Rscript scripts/test_pipeline.R` — the heaviest foreign set (25 layers) and
      the only group carrying `_by_gnis_name` and `_patches` families.
- [ ] `WSG=ufra Rscript scripts/test_pipeline.R` — a group with no foreign layers, so the
      filter must be a no-op on content.
- [ ] `Rscript scripts/gpkg_determinism-check.R` and `NO_PIN=1 Rscript …` — warm arm matches,
      cold arm differs.
- [ ] `Rscript scripts/stage_years-check.R` — its symlinked sandbox runs the real
      `01_stage.R`, so it exercises the new writer over real UFRA layers.
- [ ] `uv run scripts/style_drift-check.py` and `uv run scripts/style_determinism-check.py`.
- [ ] `bash scripts/catalogue_release-check.sh` — synthetic trees, unaffected by layer
      contents, but it pins the `--only` path these bytes travel.
- [ ] `/code-check branch` before the PR, three rounds minimum.

## Validation (workflow)

- [ ] Tests pass
- [ ] `/code-check branch` clean (three rounds minimum)
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
