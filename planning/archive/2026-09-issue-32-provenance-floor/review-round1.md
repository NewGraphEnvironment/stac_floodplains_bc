# Review round 1 — #32 provenance floor

Diff: main..HEAD over `scripts/`, `CLAUDE.md`, `NEWS.md`, plus the uncommitted
`scripts/test_pipeline.R` hunk. Probes run from a scratch copy of `fp_provenance.R`; nothing in
the working tree was touched.

## Findings

- **[bug]** `scripts/test_pipeline.R:255-264` — the "provenance.json exists ⇒ at least one
  `nge:` value must be non-null" branch refuses a state the reader defines as legitimate.
  `fp_prov_sections()` (`fp_provenance.R` ~206) documents that a present file with no section
  for this `(species, scenario)` "is a legitimate partial state (the producer's three steps run
  independently) and correctly yields nulls", and `fp_prov_item()` then returns twelve `NA`s.
  Measured on a MORR-shaped record (network + floodplain + landcover recorded for `co`/`co_ff04`
  only): `fp_prov_item(prov, "ch", "ch_ff06", ...)` → **0 of 12 non-NA**. The test then hits
  `stop("provenance.json exists for MORR but every nge: value on morr_ch_ff06.json is null — the
  reader found nothing in a record that exists")` — a false refusal that blames a working reader,
  on the first area to be re-modelled one species at a time. It is also a whole-run stop: the
  `co_ff04` item passes and the loop dies on the sibling. The condition is at file granularity
  while the reader's contract is at section granularity. Condition on what the reader resolved
  for this target instead — `01_stage.R` is `source()`d, so `wsg_prov` and `fp_prov_sections()`
  are in scope: expect a non-null value iff any of
  `fp_prov_sections(wsg_prov, meta$species, meta$scenario)` is non-NULL, else expect all null.
  That keeps the two-sided shape and matches the producer's actual unit of work.

- **[fragile]** `scripts/catalogue_release-check.sh:232` (`floor_passed`) — prints the field
  after the flag, so a flag present with an **empty** value yields `""`, indistinguishable from
  the flag being absent. Measured: `uv ... --expect-provenance <empty>` → `[]`, same as no flag.
  Case 2 still fails (`""` ≠ `"0"`), which is the safe direction; but case 1's "the validator was
  NOT given a provenance floor" passes for `--expect-provenance ""` under `--only`, where the
  real `argparse` would reject it. Today's code cannot produce that argv, so no live failure —
  only note that case 1's assertion proves "no value", not "no flag".

- **[fragile]** `scripts/catalogue_release-check.sh:273-275` — the sed premise does what it
  claims for a *replaced* literal (measured: `"0"`, `0  # note`, and `"${PROVENANCE_FLOOR:-0}"`
  all read as an empty premise and fail loud). It does not cover an override **added after** the
  literal (`PROVENANCE_FLOOR=0` kept, a later `PROVENANCE_FLOOR="${X:-$PROVENANCE_FLOOR}"`): the
  harness runs with no such env var set, so the argv still equals the literal and both
  assertions pass. The comment's "an env override sneaking in reads as an empty premise" is true
  of one shape of override. Low weight — a second assignment is visible in review of the script.

## Probed and clean

- `check_provenance` × zero-items: `main()` returns on `items != expected` (expected ≥ 1) before
  the call, so `seen == 0` and the floor never combine in practice; when they do, both problems
  are appended and reported. Fine.
- `traced` counting any single non-null field is the same predicate as `01_stage.R` `has_prov`
  (any non-NA) and `item_create.py` `_no_prov` (all None); the three agree, and the floor's job
  is "is provenance being carried at all", not per-field completeness. Consistent.
- `Filter(Negate(is.null), nge_vals)` on a `read_json` list: `[` keeps NULL elements (measured
  2 kept, 0 non-null), names survive, empty case gives `length 0`. `file.size()` on a missing
  path is `NA` but sits behind `&&` on `file.exists`. Fine.
- Path parity: `test_pipeline.R` builds `file.path(fp_data, wsg, "provenance.json")` with the
  same default `FLOODPLAINS_DATA` and lowercase `wsg` that `01_stage.R` uses for `src_wsg`, and
  the `size > 0` test matches `fp_prov_read()`'s `file.size(path) == 0 → NULL`.
- Release step 1: exactly two `uv run` lines, mutually exclusive on `$ONLY`; the flag value is a
  bare literal with no env source. Harness case 2 fails loud if the sed matches nothing.
