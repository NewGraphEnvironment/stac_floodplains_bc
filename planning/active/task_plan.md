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

- [x] Add `gpkg_layer_keys(src)`: one row per layer with its own `wsg`/`species`/`scenario`
      and a `status` of `ok` / `nokey` (a key column absent) / `multi` (0 or >1 distinct key
      rows). Read **once per group**, not once per target (review O8) — the bundles are
      group-level files and the census needs every target's verdict against one reading.
      `nokey` and `multi` are refusing statuses, not reported ones (review G4): report-and-drop
      is the direction that ships.
- [x] Add `gpkg_own_layers(keys, wsg, species, scenarios)`. `scenarios` is a SET, so
      `floodplain.gpkg` is keyed on `scenario ∈ {<sp>_ff02/04/06} ∪ {item scenario}` — the
      vector `01_stage.R` already builds as `needed` — and the landcover bundle on the item's
      single scenario. Species-only gives identical keep sets on all 24 areas (measured) and
      is still wrong one axis down (review G2). `wsg` compared case-folded.
- [x] Add `gpkg_copy_layers(src, dst, layers)`: unlink `dst`, then one
      `sf::gdal_utils("vectortranslate", options = c("-f", "GPKG", layers))`.
      **Two guards, and the stated reason was corrected mid-phase.** A missing layer both
      warns and raises (measured both ways; the earlier "warns only" came from a probe using
      `tryCatch(error =, warning =)`, which takes the warning first and never reaches the
      error). The warning guard is kept for its message — `gdal_utils`'s own error names
      nothing, the warning names the layer — as flag-then-raise rather than a `stop()` inside
      the handler, which would longjmp past sf's C++ destructors; and `setequal()` over the
      written layer names is the backstop over the 65,536-byte carcass a failed call leaves.
- [x] Document that `dst` is unlinked (review O12): `stage_years-check.R` hands the stage
      symlinks to the producer's real `.gpkg` files, so a swapped argument deletes upstream data.
- [x] Extend the `SCOPE OF THE GUARANTEE` header with the multi-layer measurement. The
      existing bound (a rewrite into an existing gpkg is not reproducible) stays true and stays:
      one call into an absent file is the *included* case, not an exception to it.

## Phase 2 — staging writes the filtered bundles

`scripts/01_stage.R:337-350`, replacing the two `file.copy()` calls

- [x] For each of the two bundles, classify the source layers and write only the own set:
      `floodplain.gpkg` keyed on `(wsg, species)`, `floodplain_landcover.gpkg` on
      `(wsg, species, scenario)`. State the asymmetry and its measurement in the comment.
- [x] **Stop** when any layer's status is `nokey`/`multi`, or when any layer's `wsg` is not
      the group's. The `wsg` arm is review **B1**: a foreign wsg has never been seen and would
      mean the producer merged two groups into one area dir, and `test_pipeline.R:373-380` is
      the repo's only guard in that direction — filtering would remove such a layer before
      that assertion could see it, trading a stop for a census line.
- [x] **Stop** when the own set is empty for a rostered item (`neexdzii`'s shape), naming the
      keys looked for and the keys found, **and** when it holds no `features` layer (review
      G3): `04_gpkg_style.py:153-156` would otherwise raise three steps later under a message
      about styling. Both stops fire **before** the census (review O9).
- [x] **Stop** when the item's headline-scenario layer or any of `<sp>_ff02/04/06` is not in
      the own set. This is the existing assertion at `:385-391`, moved onto the staged file so
      it asserts what ships.
- [x] **Report** foreign and unattributable layers per item, and accumulate a census, in the
      idiom `01_stage.R` already uses for `traced` / `year_untraced` / `drift_untraced`
      (`:504-528`): a per-item `message()` plus one end-of-run count line naming the items.
      Not a stop: 3 of 24 rostered groups legitimately carry retired-species layers until
      floodplains#131, so a stop blocks every release. Not a silence either — #75's decision
      is explicit that a layer matching no item surfaces as a decision. Computed **once per
      group** from the single key reading, against the group's whole target set (review O8):
      computed per target, a 2-target group double-counts and can call a layer foreign that a
      sibling target owns — dormant while every `area.yml` is `targets:`-free, which is the
      shape #75 spent four rounds on.
- [x] Also report the **aspatial** tables kept per item. They ship (`patch_watercourse_*`,
      `composition_*`) and nothing here describes them (#65/#70); `04_gpkg_style.py`'s
      `feature_layers()` filters them out, so its "matches no style rule" stop cannot see a
      new aspatial family. One line per item is what makes that hole visible. Also report any
      **kept** layer whose name matches no known family (review G5) — the name-vs-key
      cross-check in the opposite direction from the staged-copy assertion below, and the only
      cover `floodplain.gpkg` has, since `04_gpkg_style.py:57` is a catch-all.
- [x] Point `fp_gpkg` at the **staged** copy (`:381`) so `read_area_km2()`, the footprint
      geometry and the EPSG all describe the published bytes — the rationale already written
      at `:361-368` for the transition extraction and at `:417-419` for the metrics. Requires
      the write to precede the area reads, which it does. **The stronger reason is review O7:**
      pointed at the staged copy, the existing `needed`-layer assertion becomes a
      *name-vs-key cross-check* — a layer named `ch_ff02` whose `species` column says `co` is
      dropped by the filter and then stops the stage by name. Its message must name the staged
      path and separate "absent upstream" from "dropped by the filter".
- [x] Keep the `file.copy()`-returns-FALSE reasoning at `:340-342` (review O11): the raster
      copy at `:334` still depends on it. Move one copy and state that `gdal_utils` is the
      different case, with the inverted-return detail.

## Phase 3 — the guards

- [x] `scripts/test_pipeline.R:340-385` — tighten from "every layer carries `wsg`" to "every
      layer carries this item's key", with the per-file asymmetry, and rewrite the comment
      explaining why only `wsg` was assertable (it is the thing this issue removed). Keep the
      `feature_layers()` filter's reason intact, and keep asserting the zero-layer case.
      `transition_vector.gpkg` stays on the single-layer assertion it has.
- [x] `scripts/test_pipeline.R:358-361` — replace the geometry-based `feature_layers()` filter
      with `gpkg_contents.data_type IN ('features','attributes')` for the two bundles (review
      **AC19**). The geometry filter excludes exactly the aspatial tables the stage now
      *selects*, so a tightened assertion would leave them unchecked; `data_type` also excludes
      `layer_styles` without naming it, because `04_gpkg_style.py:21-26` records that it gets no
      `gpkg_contents` row. Verified: `st_read(query = "SELECT table_name, data_type FROM
      gpkg_contents")` works. The floodplain arm asserts `scenario ∈` the item's ff set, so the
      test is not weaker than the stage.
- [x] `scripts/test_pipeline.R` — assert the staged bundles hold **no** layer outside the
      item's own set. The positive check above is satisfied by a subset; this is the arm that
      fails on the defect as it exists today.
- [x] `scripts/gpkg_determinism-check.R` — extend to the multi-layer bundles, reading the
      **upstream** source, not the staged copy (review **AC20**). `:28` reads
      `data/stac/<item>/floodplain_landcover.gpkg`, which after this change is itself a
      vectortranslate output, so extending it there would prove "re-translating our own output
      is stable" rather than "translating the producer's file is stable" — and the second is
      the property whose failure churns 46 published checksums. Add the upstream arm, skipping
      out loud when `$FLOODPLAINS_DATA` is absent (the idiom at `stage_years-check.R:74-78`);
      keep the staged arm so the check still runs without the source tree. Keep the 1.2 s
      sleep. `NO_PIN=1` must still make them **differ**.
- [x] `scripts/gpkg_determinism-check.R:10` and `scripts/style_determinism-check.py:18` both
      suggest `ITEM=bulk_co_ff04`, a retired id. Stale already, fixed in passing.
- [x] Restore the defect and prove the new guards fire: stage a group with foreign layers
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
- [ ] `scripts/catalogue_release.sh:597-598` — "the largest asset is an upstream gpkg copied
      verbatim, so a COG-only republish leaves its checksum identical" is now false, and it is
      *reasoning* rather than decoration (review G6). After this change no published asset is a
      verbatim upstream copy, and both GeoPackage checksums are a function of the R-side GDAL
      (3.8.5 here, not the 3.12+ uv GDAL that writes the COGs), so a rebuild on a
      differently-linked machine churns 2 assets x 23 items.
- [ ] `scripts/01_stage.R:337-342` and `:378-380`, `scripts/README.md:30` and `:293-294`,
      `scripts/item_validate.py:1498-1501` ("nine invisible layers per item" — 3-4 now),
      `scripts/readme_functions.R:518`, `README.Rmd:138` — each states or reasons from the
      whole-copy premise this issue overturns.
- [ ] `CLAUDE.md` — the Collection model's "Assets per item" paragraph, the
      `floodplain_landcover.gpkg also ships a table this repo does not describe` paragraph
      (the per-area counts move — and it is about **two** tables, `composition_*` too, in 5 of
      23 groups), `transition_vector.gpkg`'s "~14% of the bundle's bytes" ratio, and
      `01_stage.R`'s entry under Layout: this repo now writes three GeoPackages, not one.
- [ ] `NEWS.md` — one entry, with the measured size deltas, the fact that every item's
      `file:checksum` for these two assets moves, and one line tying #76: the live orphans are
      the last whole-group GeoPackages in the catalogue after this lands, so #76 finishes what
      #80 starts.

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

Cheapest first, per review AC21. `stage_years-check.R` already drives the real `01_stage.R` in
a sandbox, so the foreign-layer paths need no new harness.

- [ ] `AREA=ufra Rscript scripts/stage_years-check.R` — its `PIN_META_SHA256` is the only
      byte-pin on `meta.json` in the repo, and ufra has no foreign layers, so this is the
      existence proof that reading areas from the staged copy moved no published number.
- [ ] `AREA=morr` and `AREA=bulk Rscript scripts/stage_years-check.R` — the 25- and
      14-foreign-layer paths through the real call site.
- [ ] `WSG=larl Rscript scripts/test_pipeline.R` — the minimal keep set (3 + 4, no
      `_by_blue_line_key`, no aspatial table), where a too-aggressive filter shows first.
- [ ] Roster-wide: every item's staged layer names are a subset of the upstream names, and the
      three ff layers plus the item's transition layer are present.
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
