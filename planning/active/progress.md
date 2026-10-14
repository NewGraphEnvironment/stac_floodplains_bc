# Progress — Provenance key check: verify each item finds its scenario (#75)

## Session 2026-10-14

- Plan-mode exploration: three Explore agents over the species/scenario flow, the check-script
  house style, and the producer's tree + issues. Phases approved by user.
- Measured the break directly: `all_ff04` keys live on disk in bulk/kisp/morr/dunc, and
  `fp_provenance-check.R` halts on the real `bulk` file today.
- Cross-checked all 23 rostered targets against their section keys — zero misses, so the
  per-item replacement passes on the whole real tree.
- Two scope decisions taken at the plan gate: the once-per-group README total is filed as its own
  issue rather than fixed here; `all` renders as "whole network".
- Created branch `75-provenance-key-check-verify-each-item-fi` off main; scaffolded PWF baseline.
- Next: Phase 1 — replace the whitelist in `fp_prov_sections()`.

- Phases 1-2 landed in one commit: the check script pins the message the reader emits, so
  splitting them would leave a red commit. `fp_provenance-check.R`: 81 assertions, 0 failed,
  1 skipped (the pre-existing stale `neexdzii` fold pin — upstream re-ran 2026-10-13).
- Mutation evidence, measured before the fix: the old whitelist stopped with "not scenario ids
  of the form" on the `co_ff04` item of a doc carrying `all_*` siblings, and halted the whole
  check script on the real `bulk` file. Both new controls fail under it.
- Phase 3: `SPECIES` gains `all = "whole network"` and `wct`. CLAUDE.md gains two paragraphs —
  the species slot is two to four letters with `all` reserved for the whole network, and the
  per-item scenario check replacing the key-shape whitelist. `scripts/README.md` registers the
  new arms. The `<wsg>_<sp>_ff0N` prose turned out NOT to be wrong: `<sp>` is a placeholder
  that asserts no length, and "MORR publishes two" is still true of the live catalogue (the
  build no longer stages them, which is #76's boundary). README.md / index.html are rendered
  artifacts and are not edited here.
