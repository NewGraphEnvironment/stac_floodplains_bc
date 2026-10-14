# Task: Provenance key check: verify each item finds its scenario, not a key-shape whitelist (admit all_ff04, wct_ff04) (#75)

`scripts/fp_provenance.R:251` stops on any `floodplain` / `landcover` section key that does not
match `^[a-z]{2}_ff[0-9]{2}$`. It scans **every** key in the section, so one unrecognised key stops
the whole group, not just the target being looked up. That refuses keys `floodplains` now
legitimately writes: `all_ff04` (whole-network, `species: all`, floodplains#104/#125) and any
three-letter species code such as `wct_ff04`.

A provenance record says what produced a file at a point in time. It should not decide what may be
published. The check's own comment states the failure it is there for: a re-keyed section
(`ch_ff04` -> `ff04`) would make every item's lookup miss and publish nulls on every item at once.
A whitelist of key shapes is one way to catch that, and it also blocks every new species and mode.

**Replace the shape whitelist with a check on the item itself**: for each item, its own scenario key
must be present in the `floodplain` section, and in `landcover`, whenever that section is non-empty.
A miss stops with the key and the keys present. That catches the re-keying failure, since every
lookup misses, and admits any key `floodplains` writes.

## Phase 1: Replace the whitelist with a per-item presence check

- [x] `scripts/fp_provenance.R` `fp_prov_sections()`: replace the `grep("^[a-z]{2}_ff[0-9]{2}$", ...)`
      loop with a per-item key-presence check over `floodplain` and `landcover`
- [x] An empty or absent section stays the forward-only state and still yields `NULL`
- [x] Rewrite the comment block: the subject is now the item, not the key's shape
- [x] Fix the two comments the upstream move falsified — MORR's `targets:` block is gone
      (one target, `all_ff04`), and `min_order` is no longer uniformly 3 (`all2` is order 2)

## Phase 2: Prove it in `scripts/fp_provenance-check.R`

- [x] Must-fail, landcover: the re-keyed section (`names(d$landcover) <- "ff04"`) stops on the new message
- [x] Must-fail, floodplain: its twin, which the old shape check also covered
- [x] Control: `all_ff02`/`all_ff04`/`all_ff06` + `wct_ff04` beside `co_ff04` reads clean for the `co_ff04` item
- [x] Control: an `all_ff04` item round-trips `fp_prov_item()` and `fp_prov_span()` clean
- [x] Control: an absent / empty section does not stop (forward-only state preserved)
- [x] The real-file arms run rather than halt the script

## Phase 3: `all` end to end, and the prose that states a two-letter species

- [x] `scripts/readme_functions.R` `SPECIES`: add `all = "whole network"`, `wct = "westslope cutthroat trout"`
- [x] Say in `CLAUDE.md` that `<sp>` is two to four letters and `all` is the whole-network token,
      and that the roster is upstream. The `<wsg>_<sp>_ff0N` placeholders in `README.Rmd`,
      `item_create.py`, `item_unregister.sh` and `catalogue_release.sh` assert no length and
      stay; `README.md`/`index.html` are rendered artifacts (release step 6), not edited here
- [x] Describe the per-item scenario check in `CLAUDE.md`'s Collection model
- [x] Register the new check arms in `scripts/README.md`

## Phase 4: Verify on the real tree

- [x] `Rscript scripts/fp_provenance-check.R` — 0 failed, real-file arms running
- [x] `Rscript scripts/stage_years-check.R`, `prov_fields-check.py`, `year_sets-check.py` — no regression
- [x] `WSG=bulk Rscript scripts/test_pipeline.R` — `bulk_all_ff04`, seven-year span, PASS
- [x] `WSG=morr Rscript scripts/test_pipeline.R` — `morr_all_ff04`, species `all` matched against
      three network sections, PASS
- [x] `WSG=ufra Rscript scripts/test_pipeline.R` — a species group, the control for the derived
      target assertion (needs `ALLOW_DRIFT_SKEW=1`, pre-existing: #69)
- [x] `WSG=dunc` — stages and COGs; refused at `item_create.py` on an upstream record defect,
      filed as floodplains#133, not a #75 regression
- [x] `test_pipeline.R`: derive the per-group target expectation from `area.yml` instead of
      hardcoding MORR's retired two-item shape, which failed a build item_validate.py had passed

## Phase 5: Bookkeeping

- [x] `NEWS.md` Unreleased entry
- [x] File the once-per-group README issue with the measured ff04 figures; link it from #76 (#79)
- [x] Edit #75's body: the groups are BULK/KISP/MORR (+DUNC), and "beside" holds for the live
      catalogue but not for the build
- [x] File floodplains#133 — `dunc` cannot publish: no link log row and `inputs$link$sha` null
      on every `all2` section, so the `processing:software` link entry is half-present

## Phase 6: Fold in the plan review (landed work, reviewed as code)

- [x] A duplicate scenario key refuses rather than taking the first — measured publishing a wrong
      value (9.9.9 over the real 0.5.0), the one class worse than a null; the network arm 50 lines
      above already refused the same ambiguity
- [x] A scenario key whose value is JSON null refuses rather than reading as an absence — measured
      publishing seven NAs and routing a recorded item onto the unchecked disk-discovery path
- [x] Record in the code the safety premise (raster dirs == landcover keys, all 22 areas) and the
      early-warning signal deliberately given up, so the next reader does not re-add the whitelist
- [x] Two stale headers in `fp_provenance.R` describing a state the reader now refuses
- [x] Re-take the dead `neexdzii` fold pin, re-derived independently of the reader
- [x] `stage_years-check.R`: `AREA` override, scenario and mutated years derived from the record,
      so it can drive a whole-network annual span at the real call site (floodplains#125 asked)
- [x] Assert the roster's `species`/`scenario` in `01_stage.R`, where every symptom is quiet
- [x] Strengthen the weak `"it holds"` arm; drop the fixture line hinting at a declined check
- [x] The live-catalogue vs build distinction for MORR, in `CLAUDE.md` and `item_create.py`
- [x] File #80 for the per-item-layer staging the restored #75 decision requires, and restore the
      body section an earlier edit of mine destroyed

## Validation

- [x] Tests pass
- [x] `/code-check branch` — five rounds, closed by enumeration (see findings.md)
- [x] PWF checkboxes match landed work
- [x] `/planning-archive` on completion
