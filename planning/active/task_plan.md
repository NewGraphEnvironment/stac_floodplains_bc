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

- [x] `test_pipeline.R` — replace `floodplain_km2 > 0` (`:53`) with all three
      `meta$floodplain_ff0{2,4,6}_km2 > 0` (isTRUE-guarded); assert `floodplain.gpkg` present +
      2 gpkgs in `data/stac/<wsg>/`; assert `is.null(meta$floodplain_km2)`; update the summary
      print. Confirmed RED: `WSG=bulk` fails at `expected 2 gpkgs`.

## Phase 2: Stage three extents + copy the delineation gpkg (`01_stage.R`)

- [x] Copy `floodplain.gpkg` into `data/stac/<wsg>/` (beside the landcover copy).
- [x] `endsWith(scenario, "_ff04")` guard before deriving siblings.
- [x] Compute all three areas via token-swap layer names + `st_area`; `stop()` if any layer absent.
      Selected strictly by primary-species prefix (`sub("_ff.*","",scenario)`), never positionally
      — correct when floodplains#23 lands a second species' `<sp2>_ff0x` layers.
- [x] Keep the ff04 layer as footprint geometry (unchanged).
- [x] Replace `floodplain_km2` in `meta.json` with the three keys; update the staging log.

## Phase 3: Tag + register the asset and properties (`03_cog_tag.py`, `05_stac_register.py`)

> Bundle the Phase-2 + Phase-3 **property rename** into one commit (05 KeyErrors otherwise). The
> new `floodplain` *asset* may be its own commit.

- [x] `03_cog_tag.py` — swapped `floodplain_km2` in `SHARED_FIELDS` for the three keys.
- [x] `05_stac_register.py` — added `floodplain` vector asset → `floodplain.gpkg`; added
      `floodplain.gpkg` to the expected-assets guard; replaced `floodplain_km2` in properties
      with the three keys; updated docstring + collection description.
- [x] Smoke test green (`WSG=bulk`); independent `st_area` recompute matches
      (ff02 428.29 / ff04 490.47 / ff06 540.03); code-check round 1 Clean.

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
