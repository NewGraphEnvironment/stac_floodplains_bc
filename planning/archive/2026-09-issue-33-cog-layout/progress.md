# Progress — Published COGs are not valid COGs (#33)

## Session 2026-09-01

- Plan-mode exploration — phases approved by user
- Measured the three facts the plan rests on: the layout break, terra's metadata preservation,
  and byte-determinism of both writes
- Created branch `33-published-cogs-are-not-valid-cogs-in-pla` off main
- Scaffolded PWF baseline with approved phases
- Next: Phase 1
- Phase 1 guard landed red on the current tree (all 4 COGs), Phase 2 turned it green
- Phases 3-4: docs swept, verified on ufra / bulk / morr, checksums stable across runs
- Phase 5: folded in a concurrent plan review — widened the tag guard past NGE_, and fixed
  two bugs in that widening
- Archived; PR opened
