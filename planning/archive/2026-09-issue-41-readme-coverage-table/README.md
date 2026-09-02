## Outcome

No PWF (single script + README section). `scripts/readme_coverage-table.py` regenerates the
README coverage block — caption and table — from the live API; twenty rows, a `Scenario` column
because the collection mixes flood factors, KOTL/LARL/SLOC corrected from Peace to Columbia.
One review round (`review.md`) found three fragilities, all fixed before merge: the caption's
numbers were hardcoded prose the script did not write (now the caption is part of the generated
block), the once-per-group km² total depended on response order (now asserted equal across a
group's items), and an empty result could pass the count cross-check (now refused outright).

Closed by: PR #43.
