# Task: Publish multiple species items per WSG (config-driven; MORR chinook ch_ff06) (#11)

## Problem

The pipeline emits one item per WSG (`01_stage.R` reads a single `primary_scenario`). MORR now
carries a second species (chinook, LULC on **ff06**) alongside coho. Goal: emit `morr_ch_ff06`
beside `morr_co_ff04`. Blockers: (1) one-item-per-WSG discovery; (2) #8's `endsWith(scenario,
"_ff04")` guard + ff04-as-footprint; (3) asset paths are WSG-keyed and would collide for two
`morr` items.

Decisions: **config-driven** discovery (declare targets in `area.yml`, don't infer from disk);
**item-keyed** asset paths for all items (`data/{raw,stac}/<item_id>/`, S3 `<item_id>/<asset>`);
**shared gpkgs accepted** (species-prefixed layers are self-describing).

## Key facts (exploration + Plan-agent review)

- All WSG→path keying (`01` dirs, `05` hrefs from `meta['wsg_lower']`, meta.json path) must switch
  to item-id. `03_cog_tag.py` + `02_cog.R` are dir-agnostic (no change). `04` sync needs no change.
- **Blocker:** old WSG name is a string-prefix of its item-id — S3 cleanup MUST use trailing slash
  `s3://…/<wsg>/` or it wipes the new assets.
- **01 + 05 item-key migration is atomic** (one commit) — split hrefs → dead links.
- **Footprint vs area split:** read the item's `scenario` layer for geometry; read `ff04` layer
  separately for `floodplain_ff04_km2`.
- Cleanup runs **after** the verified reload (avoid dead-href window). Existing 15 re-publish with
  identical content under new paths (footprint unchanged; only paths change).
- Fallback safe: all 14 other `area.yml` have `primary_scenario` + `species`.

## Phase 1: Upstream floodplains — declare MORR's two targets (prerequisite)

- [x] Added a `targets` list to `floodplains/config/morr/area.yml` (co/co_ff04 + ch/ch_ff06);
      kept `species`/`primary_scenario`. floodplains PR #25. Validated it parses (R yaml).
- [x] No change to the other 14 area.yml — STAC layer falls back to a 1-target list (Phase 3).

## Phase 2: Encode the new contract in the smoke test (tests first)

- [x] `test_pipeline.R` — re-keyed to iterate `data/raw/*/meta.json`; per item assert item-id dir
      (`basename(dirname(mp)) == item_id`), 4 COGs + 2 gpkgs, three `floodplain_ff0{2,4,6}_km2` > 0,
      no `floodplain_km2`, item JSON. Asserts staged count == declared targets; `WSG=morr` → exactly
      `morr_co_ff04` + `morr_ch_ff06`. Confirmed RED: `WSG=morr` halts at "staged item count !=
      declared targets" (old staging = 1).

## Phase 3: Discovery + item-keyed staging + footprint/guard (`01_stage.R`)

- [x] Per-WSG target list: `area$targets` if present, else `[{species, primary_scenario}]`. Nested
      loop → one item each; `item_id <- paste0(wsg, "_", scenario)`.
- [x] Staging dirs + meta.json keyed by **item_id**; rasters from `rasters/<scenario>/`; metrics
      from `transition_<scenario>_2017_2023`.
- [x] Footprint = the item's `scenario` layer; all three areas via species-prefix token-swap
      (ff04 read separately). Dropped `endsWith(scenario,"_ff04")`; guard requires the scenario
      layer + the three ff02/04/06 layers exist.
- [x] `meta` carries `item_id`; `WSG_ONLY` stages all of a WSG's targets; `PARTIAL_STAGE` kept.
- [x] Bundled with Phase 4's `05` href change in one commit.
- [x] Verified: `WSG=bulk` (fallback → 1 item, item-keyed dir + hrefs); `WSG=morr` (2 items:
      morr_co_ff04 + morr_ch_ff06, ch footprint from ch_ff06). code-check Clean.

## Phase 4: Item-keyed asset paths in register/tag (`05_stac_register.py`, `03_cog_tag.py`)

- [x] `05` — asset hrefs use `meta['item_id']` (all 4); `wsg_dir`/expected-assets guard key off the
      item-id dir; docstring + collection description → "one or more items per WSG".
- [x] `03_cog_tag.py` — confirmed dir-agnostic (no change; tags come from per-item meta.json).

## Phase 5: Docs

- [x] `README.md` — item model (one-or-more items per WSG, item-keyed asset prefix), coverage now
      16 items / 15 WSGs with a MORR chinook row (+ MORR-counted-once footnote), pipeline-table
      `<item_id>` paths, `species` added to the rstac example. `scripts/README.md` — stage/COG/STAC
      rows re-keyed to `<item_id>`.

## Phase 6: Publish + migrate layout + verify live

- [x] `WSG=morr` smoke test — two items; independent `st_area` recompute matches meta.json.
- [x] `run_pipeline.sh` — 16 items published to S3 under item-keyed paths; collection.json links 16.
- [x] Positive check across 16 (dry-run + S3): three ff areas + `floodplain` asset + no
      `floodplain_km2`, every href under `<item_id>/`; morr_ch_ff06 verified on S3.
- [x] **rtj pgstac reload (rtj#198) — RUN.** Live now serves 16; all 16 verified item-keyed;
      morr_co_ff04 + morr_ch_ff06 both present.
- [ ] Clean up old flat prefixes (90 objects / 0.4 GB): `aws s3 rm --recursive s3://…/<wsg>/`
      with a **trailing slash**. Reload gate PASSED and dry-run verified (90 objects, zero
      item-keyed matches) — awaiting explicit authorization.

## Validation

- [ ] `WSG=morr` smoke test yields two items; independent recompute matches
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] Every published href under `<item_id>/`; old `<wsg>/` prefixes removed post-reload
- [ ] `/planning-archive` on completion
