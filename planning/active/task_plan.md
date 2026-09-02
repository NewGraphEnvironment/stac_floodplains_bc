# Task: Add an operator-set provenance floor so a reader that finds nothing fails the release (#32)


Every guard on the `nge:` provenance today asserts on key **presence**. A reader that silently
finds nothing produces twelve nulls on every item — byte-identical to the forward-only state the
catalogue has legitimately been in since #17 — and every guard passes. Once the upstream
remodel lands (floodplains#58 on flooded 0.5.0, with provenance recording), "all null" stops
being the expected state and becomes the one failure this feature exists to make visible.

The floor is **operator-set**, never derived: deriving it from the build reproduces #23 (the
expectation comes from the data, so the data cannot contradict it). Today the correct floor is
0 — `bulk_co_ff04` is the only item whose producer file carries provenance (its link and
floodplain steps re-ran on 2026-09-02; landcover not yet), and the other 18 areas have no
`provenance.json`. The flip to the built count happens in the same commit as the NEWS entry of
the first release that publishes real provenance (the #26 rebuild), not before and not never.

What the code already provides: `01_stage.R` prints `N of M staged item(s) carry run
provenance` (`has_prov` = any non-null field), `item_create.py` prints `provenance block: N/M`
(`_no_prov` = all null). Those are the number the operator reads off the screen. "Carries
provenance" here means the same thing: at least one non-null `nge:` value.

## Decisions

1. **The floor lives in `item_validate.py` as `--expect-provenance N`, default 0**, checked as
   `traced >= N` where `traced` counts items with any non-null `nge:` property — the same
   predicate the two existing prints use, so the number on screen is the number to set.
   Failure names both numbers and the trap ("a reader that finds nothing looks exactly like the
   expected state").
2. **`catalogue_release.sh` carries the number as a literal**, `PROVENANCE_FLOOR=0`, beside the
   existing `--expect "$n_local"` with the same style of comment saying why a human sets it and
   when to flip it. No env override: an override is the escape hatch the floor exists to not
   have. Under `--only` the floor is skipped out loud, like the two other tree-level guards
   (a one-group pilot tree cannot meet a full-tree floor, and the item's own provenance is
   compared wholesale by the read-back).
3. **`run_pipeline.sh` and `test_pipeline.R` keep the default 0**: a rebuild is not a
   release, and the smoke test runs on one area.
4. **`test_pipeline.R` upgrades from "key present" to a value assertion conditioned on the
   producer**: if `$FLOODPLAINS_DATA/<wsg>/provenance.json` exists, the item must carry at least
   one non-null `nge:` value; if it does not, every value must be null. Two-sided, so it cannot
   pass by the fixture happening to be in one state. This is what #17 deferred with "once they
   land"; bulk has landed.

## Phase 1: the floor in the validator

- [x] `item_validate.py`: `--expect-provenance N` (int, default 0, help text saying it is set by
      the release, not derived); `check_provenance(base, floor)` counts `traced` (items with any
      non-null `nge:` value) and appends a problem when `traced < floor`, naming
      `traced`, `len(items)` and `floor`; the summary line becomes
      `provenance: 12 nge: properties on every item (K of M carry values; floor F), COG tags agree`
- [x] Verify against both answers on the real bulk smoke tree in `data/stac` (1 item, provenance
      present): `--expect-provenance 0` and `1` pass, `2` fails naming `1 of 1 … floor 2`
      (~1 min per run — the validator re-hashes every asset and checks every COG)

## Phase 2: the number the release sets

- [x] `catalogue_release.sh`: `PROVENANCE_FLOOR=0` near the top with the comment: why it is a
      literal set by a human, that 0 is correct until the first provenance-bearing release,
      that it is flipped to the built count in the same commit as that release's NEWS entry, and
      that the number to set is the one `01_stage.R` / `item_create.py` print. Step 1 passes
      `--expect-provenance "$PROVENANCE_FLOOR"` on a full release; under `--only` it passes
      nothing and says `provenance floor: skipped under --only (…)` — the third skip
- [x] `catalogue_release-check.sh`: `uv` is shimmed, so the validator never runs there, but its
      argv is logged. Assert on a full release that the `uv` line carries
      `--expect-provenance 0`, and under `--only` that it does not and the skip line prints;
      bump the "skips said out loud" count 3 → 4
- [x] Docs: `scripts/README.md` release table step 1 names the floor; CLAUDE.md gains one
      paragraph under "Catalog registration" (what the floor is, why it is a literal, the flip
      rule); `NEWS.md` `## Unreleased` gains a bullet
- [x] Verify: `bash scripts/catalogue_release-check.sh` ALL PASS; restore-the-bug: with the
      `--expect-provenance` argument removed from step 1, the argv assertion goes red

## Phase 3: the smoke test asserts values, then review + PR

- [x] `test_pipeline.R`: after the key-set check, read `nge:` values from the item JSON
      (`read_json` maps null → NULL, so count non-NULL); if the producer's `provenance.json`
      exists for this WSG require ≥1 non-null and print which, else require all null. Premise
      printed either way so a reader sees which branch ran
- [x] `WSG=bulk Rscript scripts/test_pipeline.R` → PASS on the "producer file present" branch
      (5 non-null); a second WSG without a producer file (e.g. `WSG=kotl`, ~3 min) → PASS on
      the all-null branch — both branches exercised, recorded in `progress.md`
- [ ] `/code-check`, then PR. No tag and no release; the floor stays 0 until the #26 rebuild

## Validation

- [ ] Validator: 0 and 1 pass, 2 fails on the real bulk tree; harness ALL PASS, argv case red
      with the argument removed
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion

## Files

| file | change |
|---|---|
| `scripts/item_validate.py` | `--expect-provenance`, floor check, summary line |
| `scripts/catalogue_release.sh` | `PROVENANCE_FLOOR=0` literal + comment; step 1 argument; `--only` skip |
| `scripts/catalogue_release-check.sh` | argv assertions for the flag, skip count 4 |
| `scripts/test_pipeline.R` | two-sided value assertion conditioned on the producer file |
| `scripts/README.md`, `CLAUDE.md`, `NEWS.md` | floor documented; Unreleased bullet |
