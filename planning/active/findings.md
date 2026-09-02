# Findings — Add an operator-set provenance floor so a reader that finds nothing fails the release (#32)

## Issue context

## What changes if we do it

A release refuses to publish when the provenance reader silently finds nothing, instead
of shipping a catalog of all-null properties that looks exactly like the expected state.

## What happens if we never do

The one failure `nge:` provenance exists to make visible stays invisible. Once
NewGraphEnvironment/floodplains#33 has landed and areas are re-modelled, a broken reader
and a correctly-empty upstream produce **identical** output — all eleven properties null
on every item — and every existing guard passes, because they assert on key *presence*,
not on value.

## Why it cannot be done yet

Today `0 of N` items carry provenance, and that is correct: #33 is forward-only, so every
area modelled before it lands has none until it is re-run. A floor set now would fail
every release.

The floor is therefore an operator-set number, not a derived one — deriving it from the
build reproduces the #23 defect exactly (the expectation comes from the data, so the data
cannot contradict it).

## The work

- `item_validate.py` grows `--expect-provenance N`, defaulting to `0`.
- `catalogue_release.sh` passes it explicitly, next to the existing `--expect "$n_local"`,
  with the same comment style explaining why the floor is set by a human.
- Flip it to `n_local` **in the same commit that first publishes real provenance**, not
  before (every release fails) and not never (the hole stays open).

`01_stage.R` and `05_stac_register.py` already print the count, so the number to set is on
screen. Printing is not a guard, though — a zero and a silence look the same in a
scrollback nobody reads, which is why this needs the assertion and not just the line.

## Also worth folding in

Once real provenance exists, `test_pipeline.R` can upgrade from "key present" to "value
non-null", which is what #17 originally asked for and deferred with "once they land".

Blocked on NewGraphEnvironment/floodplains#33.



## Exploration (2026-09-02, plan mode)

- "Carries provenance" already has one definition in two places: `01_stage.R` `has_prov` (any
  non-null field → `N of M staged item(s) carry run provenance`) and `item_create.py` `_no_prov`
  (all null → `provenance block: N/M`). The floor uses the same predicate so the number printed is
  the number to set.
- `item_validate.py` `check_provenance()` asserts key-set equality per item and refuses zero
  items; it has no notion of values. `--expect` (item count) is passed explicitly by the release
  (`catalogue_release.sh` step 1) because a release-only machine has no `data/raw` to derive from.
- The check harness shims `uv`, so the validator never runs there — but the shim logs argv, so
  "the release passes `--expect-provenance 0`" is assertable from the log.
- State on disk (after #40's smoke): `data/stac` holds the bulk smoke tree — one item, five
  non-null `nge:` values (link_*, flooded_version), seven null. Producer files exist only for bulk
  and neexdzii; the other 18 rostered areas have none, so the correct floor today is 0 and the
  Columbia groups (grabbed networks, no link log row) will count as carrying provenance once
  their steps 2/3 re-run, with the three link-log fields null.
- floodplains#33 is CLOSED (2026-09-01); the blocker named in the issue is gone, the flip waits
  on the remodel (floodplains#58).

## Errors Encountered

| Error | Resolution |
|-------|------------|
