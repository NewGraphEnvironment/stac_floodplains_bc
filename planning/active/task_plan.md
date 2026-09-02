# Task: nge:landcover_key publishes item_hash, the one landcover field that cannot detect an upstream reprocess (#40)

`nge:landcover_key` exists to move when the upstream landcover moves. It publishes
`inputs$item_hash`, a hash over resolved STAC item ids — an identity, not a fingerprint — so an
in-place re-derivation upstream leaves it unchanged. floodplains#64 added
`inputs$classified_content_sha256`, a per-year content digest invariant to the writing toolchain.
This repo has to point `landcover_key` at it — and, found in planning, read upstream's
`schema_version: 2` first, because the reader pins 1 and the next rebuild refuses at BULK.

## Decisions

1. **Fold the year map to one scalar, by a stated rule.** A STAC property here is a scalar, and
   `fp_prov_leaf` deliberately rejects a list (a single-key object would otherwise publish its
   member as the value). The rule mirrors upstream's own `item_hash` construction so it is
   reproducible from the published record:
   `sha256:` + sha256 over the text `"<year>=<digest>"` joined by `\n`, years sorted ascending.
   Asserted before folding: the map's years equal the item's staged `years` (2017/2020/2023),
   every value matches `^sha256:[0-9a-f]{64}$`. Any mismatch stops — it is a schema break, not an
   absence. Documented at the map entry and in CLAUDE.md as a fold, since a consumer cannot tell a
   fold from a single year's hash otherwise.
2. **Keep `item_hash` published, as a twelfth field `nge:landcover_item_hash`.** It is right as
   "what was read" and only wrong as "what was produced". The repo has six copies of the field
   list, each tied to another by a guard, so adding one field exercises every guard — which is
   the point of having them.
3. **No migration of published items.** Provenance is forward-only. The 20 live items carry
   nulls; the first full release after upstream finishes re-running (the #26 rebuild) publishes
   real values for whichever areas have a landcover section. Nothing here needs to run against
   the live catalogue, and no release is cut by this issue.
4. **Safe to switch now.** An area with no landcover section yields null (the normal state); an
   old schema-1 record is refused by the pin. There is no path by which the switch publishes a
   wrong value.

## Phase 1: Read schema 2, and prove the reader offline

The reader has never had a test that runs without a full stage. Add one, then use it for the
pin bump and for Phase 2.

- [x] `scripts/fp_provenance-check.R` — sources `01_stage.R`'s `PROV_FIELDS` block and
      `fp_provenance.R` without staging, then asserts against both known answers: the real
      `$FLOODPLAINS_DATA/{bulk,neexdzii}/provenance.json` when present (skip out loud when not),
      and synthetic mutations of the neexdzii file written to a temp dir. Cases: v2 file reads;
      `schema_version: 1` stops naming both versions; a top-level `floodplain_v2` stops; bulk's
      `co_ff04` yields network + floodplain values and landcover nulls; neexdzii's `co_ff04`
      yields all fields non-null; a landcover section whose `classified_content_sha256` key is
      renamed stops ("schema break, not an absence"); a null leaf publishes NA
- [x] `fp_provenance.R`: `FP_PROV_SCHEMA_VERSION <- 2L`, with the comment naming what v2 changed
      (floodplains#65 phase 1) and that the map is unaffected because it walks paths
- [x] Verify: `Rscript scripts/fp_provenance-check.R` → all cases pass; the pin case is red
      with the constant at `1L` (restore-the-bug)

## Phase 2: `landcover_key` = content digest, `landcover_item_hash` = the ids

- [x] `fp_provenance.R`: `FP_PROV_MAP` gains an optional `fold` per entry; `fp_prov_leaf`
      hands the raw value to `fold` when present instead of applying the scalar guard.
      `landcover_key` → `c("inputs", "classified_content_sha256")` with
      `fp_fold_year_digests()` (rule and assertions from decision 1, `digest::digest(...,
      algo = "sha256", serialize = FALSE)` on the canonical text — same call upstream uses).
      New entry `landcover_item_hash` → `c("inputs", "item_hash")`, no fold
- [x] The twelfth field in every copy: `01_stage.R` `PROV_FIELDS` (+ comment rewrite: the
      `landcover_key` paragraph currently documents the wrong claim), `item_create.py`
      `PROV_FIELDS`, `02_raster_tag.py` `PROV_FIELDS` (tag `NGE_LANDCOVER_ITEM_HASH`),
      `item_validate.py` `REQUIRED_NGE_PROPERTIES`, `test_pipeline.R` `prov_keys`. The
      `stopifnot` in `fp_provenance.R`, the `meta[f]` KeyError in item_create, set equality in
      the validator and test_pipeline's two-sided tie are what make a missed copy fail
- [x] `fp_provenance-check.R` cases for the fold: neexdzii's map folds to a fixed 64-hex value
      (pin it — it is a function of three published digests); reordering the map's keys gives
      the same value; one hex character changed gives a different one; a missing year, an
      extra year, a value without `sha256:` and a scalar in place of the map each stop;
      `landcover_item_hash` equals the file's `item_hash` verbatim
- [x] Docs: CLAUDE.md "Collection model" gains two sentences (what `landcover_key` is now, that
      it is a fold and how, and that `landcover_item_hash` is the identity); the `#17`
      sentence in floodplains' CLAUDE.md that says the key "IS NOT" the digest becomes true —
      note that in the PR for the upstream repo to reconcile, not edited here
- [x] Verify: check script all pass; `python3 -m py_compile` on the three Python scripts;
      `bash scripts/catalogue_release-check.sh` still ALL PASS (its fixture carries one
      `nge:probe` null and must be unaffected)

## Phase 3: Smoke on a real v2 area, review, PR

- [x] `WSG=bulk Rscript scripts/test_pipeline.R` — the one rostered area with a v2 file.
      Expect: staging succeeds under the new pin, `bulk_co_ff04` carries non-null
      `link_*`, `flooded_version` and null landcover fields (its landcover step has not been
      re-run), 12 `nge:` keys on the item; on the COGs the five non-null value tags plus
      `NGE_PROVENANCE_NULL` naming the seven nulls (a null is never tagged — corrected from
      "12 tags" after the plan review), validator clean.
      Record the field-by-field values in `progress.md`
- [ ] `/code-check`, then PR. No tag and no release: the change publishes nothing until the
      next full release, which is #26's rebuild once upstream finishes
- [ ] Reconcile #40's body at merge: the "Ordering" section's premise (switching early
      publishes a null) is what the pin already guarantees, and the twelfth field is a decision
      the body left open

## Validation

- [ ] `Rscript scripts/fp_provenance-check.R` passes; restore-the-bug: the pin at `1L` aborts the
      run at the synthetic v2 base (an uncaught stop, rc 1, not a FAIL line); dropping the
      `<year>=` prefix from the fold reddens both the recomputed-rule case and the neexdzii pin
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion

## Files

| file | change |
|---|---|
| `scripts/fp_provenance.R` | schema pin 2; `fold` hook; `fp_fold_year_digests`; two map entries |
| `scripts/fp_provenance-check.R` | new, offline proof of the reader against real v2 files + mutations |
| `scripts/01_stage.R`, `scripts/item_create.py`, `scripts/02_raster_tag.py`, `scripts/item_validate.py`, `scripts/test_pipeline.R` | the twelfth field, one line each; comment fix in 01 |
| `CLAUDE.md` | what the two landcover fields mean |

Upstream references read: `floodplains/scripts/floodplain_lcc/fp_provenance.R` (`fp_prov_stac_items`
for the `item_hash` payload shape, `fp_raster_content_sha256`, `FP_PROV_SCHEMA_VERSION <- 2L`),
floodplains#64 and #65 phase-1 commit `4740702`, the neexdzii and bulk `provenance.json` on disk.
