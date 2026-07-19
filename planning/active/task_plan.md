# Task: Publish floodplain.gpkg delineations (ff02/ff04/ff06) as a vector asset + per-frequency area properties (#8)

## Problem

Each `stac-floodplains-bc` item ships 4 raster COGs + one vector asset (`floodplain_landcover`
→ `floodplain_landcover.gpkg`). The upstream `floodplain.gpkg` — delineated floodplain polygons
at all three `run=TRUE` flood-factor scenarios (`<sp>_ff02`, `<sp>_ff04`, `<sp>_ff06`) — is read
at staging only for the ff04 footprint geometry (`01_stage.R:137`) and then dropped. So the
ff02/ff06 delineations are not downloadable, and the only area property is `floodplain_km2`
(ff04 only).

Add `floodplain.gpkg` as a second vector asset (`floodplain`) AND replace `floodplain_km2` with
symmetric `floodplain_ff02_km2` / `floodplain_ff04_km2` / `floodplain_ff06_km2`. Clean schema
break — no back-compat alias. Item count stays 15; ff04 stays the footprint.

## Key facts (from exploration + Plan-agent review)

- **Property rename is atomic across `01`+`03`+`05`:** `05:90` does `meta["floodplain_km2"]`
  (hard KeyError) while `03:29` uses `.get()`. Renaming in `01` without `05` KeyErrors the smoke
  test — Phases 2 + 3 property rename land in **one commit**.
- **Two READMEs** change: root `README.md` and `scripts/README.md` (prose "floodplain km²" not
  caught by the grep sweep).
- Root README **mislabels** the existing landcover asset as `floodplain` (`:75`) while code keys
  it `floodplain_landcover` (`05:77`) — fix the mislabel AND add the genuinely-new `floodplain`.
- Layer naming is a uniform token-swap (`<sp>_ff0{2,4,6}`); `04_s3_upload.R` and `02_cog.R`
  need no change (verified).

## Phase 1: Encode the new contract in the smoke test (tests first)

- [ ] `test_pipeline.R` — replace `floodplain_km2 > 0` (`:53`) with all three
      `meta$floodplain_ff0{2,4,6}_km2 > 0`; assert `floodplain.gpkg` present in
      `data/stac/<wsg>/`; assert `is.null(meta$floodplain_km2)`; update the summary print
      (`:60`). Fails until Phases 2–3 land.

## Phase 2: Stage three extents + copy the delineation gpkg (`01_stage.R`)

- [ ] Copy `floodplain.gpkg` into `data/stac/<wsg>/` (beside the landcover copy at `:133`).
- [ ] `stopifnot(endsWith(scenario, "_ff04"))` before deriving siblings.
- [ ] Compute all three areas via token-swap layer names + `st_area`; `stop()` if any layer absent.
      **Select strictly by the primary-species prefix** (`sub("_ff.*","",scenario)`), never
      positionally — keeps it correct when floodplains#23 lands a second species' `<sp2>_ff0x`
      layers in the same `floodplain.gpkg`.
- [ ] Keep the ff04 layer as footprint geometry (`:136-137`, unchanged).
- [ ] Replace `floodplain_km2` in `meta.json` (`:166`) with the three keys; update log (`:177`).

## Phase 3: Tag + register the asset and properties (`03_cog_tag.py`, `05_stac_register.py`)

> Bundle the Phase-2 + Phase-3 **property rename** into one commit (05 KeyErrors otherwise). The
> new `floodplain` *asset* may be its own commit.

- [ ] `03_cog_tag.py:24` — swap `floodplain_km2` in `SHARED_FIELDS` for the three keys.
- [ ] `05_stac_register.py` — add `floodplain` vector asset → `floodplain.gpkg` (`:77-82`
      template); add `floodplain.gpkg` to the expected-assets guard (`:131-138`); replace
      `floodplain_km2` in properties (`:90`) with the three keys; update the docstring (`:3-9`)
      and collection description (`:164-170`).

## Phase 4: Sweep + docs

- [ ] `grep -rn floodplain_km2` across repo → zero hits.
- [ ] Root `README.md` — fix the landcover mislabel (`floodplain` → `floodplain_landcover`),
      add the new `floodplain` asset, document three ff extent layers + three area properties,
      update the rstac example (`:97`).
- [ ] `scripts/README.md` — hand-edit the prose asset-copy / tag / gpkg rows.
- [ ] `grep floodplain_km2` in `~/Projects/repo/rtj`; record in findings.md (no rename expected).

## Phase 5: Publish + verify live

- [ ] `WSG=bulk Rscript scripts/test_pipeline.R` — new assertions pass; independently recompute
      ff02/ff06 areas via `ogrinfo`/`st_area` and confirm they match `meta.json`.
- [ ] `bash scripts/run_pipeline.sh` — 15 items republished; `collection.json` links 15.
- [ ] Positive check: all 15 `data/stac/*.json` carry the `floodplain` asset + three
      `floodplain_ff0{2,4,6}_km2` (> 0); grep for `floodplain_km2` → zero.
- [ ] File the rtj pgstac reload follow-on (as with rtj#190); verify `images.a11s.one` serves 15
      with the new asset + props.

## Validation

- [ ] `WSG=bulk` smoke test passes; independent `st_area` recompute matches meta.json
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] Zero `floodplain_km2` in repo or generated output
- [ ] `/planning-archive` on completion
