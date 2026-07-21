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

- [ ] `test_pipeline.R` — fully re-key off `data/stac/<wsg>/` (every line is wsg-keyed today).
      Iterate the item dirs produced for the WSG; per item assert item-keyed dir, 4 COGs + 2 gpkgs,
      three `floodplain_ff0{2,4,6}_km2` > 0, footprint area == item's headline-scenario area, item
      JSON validated. `WSG=morr` → exactly two items. Red until Phases 3–4.

## Phase 3: Discovery + item-keyed staging + footprint/guard (`01_stage.R`)

- [ ] Per-WSG target list: `area$targets` if present, else `[{species, primary_scenario}]`. Loop
      targets → one item each; `item_id <- paste0(wsg, "_", scenario)`.
- [ ] Key staging dirs + meta.json by **item_id**; rasters from `rasters/<scenario>/`; metrics from
      `transition_<scenario>_2017_2023`.
- [ ] Footprint = the item's `scenario` layer (geometry/bbox/epsg); compute all three areas via
      species-prefix token-swap independently (`floodplain_ff04_km2` still reads the ff04 layer).
      Relax #8's guard: drop `endsWith(scenario,"_ff04")`; require the scenario layer + the three
      ff02/04/06 layers exist.
- [ ] `meta` carries `item_id`; `WSG_ONLY` stages all of a WSG's targets; keep `PARTIAL_STAGE`.
- [ ] **Bundle with Phase 4's `05` href change in one commit** (atomic item-key migration).

## Phase 4: Item-keyed asset paths in register/tag (`05_stac_register.py`, `03_cog_tag.py`)

- [ ] `05` — asset hrefs use `meta['item_id']`; `wsg_dir`/expected-assets guard key off the item-id
      dir; docstring + collection description → "one or more items per WSG (per modelled
      species/scenario)".
- [ ] `03_cog_tag.py` — confirm dir-agnostic (no change expected).

## Phase 5: Docs

- [ ] `README.md` + `scripts/README.md` — multiple items per WSG (one per declared target); asset
      paths `s3://…/<item_id>/<asset>`; MORR worked example.

## Phase 6: Publish + migrate layout + verify live

- [ ] `WSG=morr` smoke test — two items; independent `st_area` recompute of the ch_ff06 footprint +
      ch ff02/04/06 areas matches meta.json.
- [ ] `run_pipeline.sh` — 16 items under item-keyed paths; collection.json links 16.
- [ ] Positive check across 16: three ff areas + `floodplain` asset + no `floodplain_km2`, AND every
      asset href resolves under `<item_id>/` (no bare `<wsg>/`).
- [ ] rtj pgstac reload (out-of-repo) → verify `images.a11s.one` serves 16, morr has both.
- [ ] **After the verified reload**, clean up old flat prefixes: `aws s3 rm --recursive
      s3://…/<wsg>/` with a **trailing slash**, iterating only the 15 known pre-migration WSG names.
- [ ] Update/append rtj#190 once published (16 items).

## Validation

- [ ] `WSG=morr` smoke test yields two items; independent recompute matches
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] Every published href under `<item_id>/`; old `<wsg>/` prefixes removed post-reload
- [ ] `/planning-archive` on completion
