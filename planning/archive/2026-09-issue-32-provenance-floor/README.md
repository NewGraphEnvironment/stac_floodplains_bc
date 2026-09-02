## Outcome

The release now carries an operator-set provenance floor: `item_validate.py --expect-provenance N`
fails unless exactly N items carry a non-null `nge:` value, and `catalogue_release.sh` passes
`PROVENANCE_FLOOR`, a literal a human sets to the count the build printed, never derived and with
no override. Exact rather than a minimum, so each release records the count beside its NEWS entry
and a floor nobody updated fails as loudly as a reader that found nothing. The plan review found
the hole that mattered: `--only`, the release path in use, had no provenance guard, and the
read-back's null-equals-absent rule would have let a reader that found nothing replace bulk's
twelve live values with nulls. Its preflight now refuses, before any write, any live `nge:` value
the build would publish as null — per key, after round 2 showed a total-count check passes a
partial loss. `test_pipeline.R` compares three per-target scalars against the producer's raw JSON.
What was learned: three rounds found one class — a guard at a coarser granularity than its
property (file, item, key) — and it terminated by enumeration, since there is no level below key.

## Measurement

Validator on real trees: bulk (12 values) floors 0/1 pass, 2 fails; kotl (all null) floor 1 fails
`0 of 1`, floor 0 passes. Harness ALL PASS (cases 1, 2, 15 carry the floor's assertions); flag
removed → 2 red; guard disabled or total-count → case 15 red with the release syncing before the
read-back catches it. Reader check 49/0/0 with bulk's landcover section, which landed at 20:46Z
during this work. Smokes: bulk PASS (three producer sections identical), kotl PASS (all null).

## Evidence

`review-round1.md` … `review-round3.md` and the plan-review disposition in `findings.md`, here.

Closed by: PR for #32 (branch `32-add-an-operator-set-provenance-floor-so-`).
