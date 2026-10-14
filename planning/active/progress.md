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
- Phase 4-5: verified on the real tree. `bulk_all_ff04` (ff04 659.99), `morr_all_ff04`
  (479.32) and the `ufra_ch_ff04` control all PASS end to end through `item_validate.py`;
  both whole-network figures match floodplains#125's own run log. Four guard-check scripts
  green (81/44/16/14 assertions, 0 failed).
- Two defects found by the verification, neither in #75's change: `test_pipeline.R` hardcoded
  MORR's retired two-target shape (fixed by deriving it from `area.yml`), and `dunc` cannot
  publish because neither its link log nor `inputs$link$sha` carries a commit — filed as
  floodplains#133.
- Filed #79 (once-per-group ff04 total) and cross-linked it from #76; corrected #75's body.
- Next: `/code-check branch`, archive, PR.
- Plan review (background `Plan` agent, ~10 min) landed after the code did and read real code
  rather than a plan. Three findings reproduced before acting on any of them:
  - **I destroyed a user decision.** My `gh issue edit` of #75's body at 16:04 UTC dropped the
    "Decided (2026-10-14)" section added at 15:50 — I read the body in plan mode before it
    existed and did not re-read it before editing, which is exactly what `feature-workflow.md`'s
    "Re-read the issue body before the baseline" exists to prevent. Recovered verbatim from
    `userContentEdits` via GraphQL, restored, and said so in a comment.
  - A duplicate scenario key published a wrong value (measured: 9.9.9 over the real 0.5.0).
  - A null-valued scenario key published seven NAs and took the unchecked year path.
- The per-item-layer staging the restored decision requires is #80, by the user's call: it moves
  the bytes of every published GeoPackage, so it gets its own plan gate. Its cost was re-costed
  honestly in the issue — the first framing ("republish 23 items on a bucket with no rollback")
  overstated it, since a full release republishes everything anyway.
- Verification after the review fixes: fp_provenance-check 87/0/0 (the dead pin now live),
  prov_fields 44/0, year_sets 16/0, stage_years 14/0 on ufra and 13/0/1 on bulk, and
  `WSG=bulk test_pipeline.R` PASS.
- `/code-check branch` round 1 (reviewer, 11.6 min): three findings, none in the core change.
  The stale `PROV_CENSUS` is named rather than re-measured — DUNC blocks a release one step
  earlier, so writing its numbers in would encode a broken record as the expectation. Two
  quiet pointers fixed, one of them with a twin on the same mechanism.
- One transient failure worth not mistaking for a defect: `item_validate.py` fetches remote
  STAC extension schemas, and `classification/v2.0.0` was briefly unreachable. The retry
  passes every gate. A re-run IS the attempt for a transient, per `planning.md`.
- Round 2 (reviewer, 10.8 min): five findings, one of them INSIDE round 1's fix (the `AREA`
  override made the recordless groups reachable and the script crashed). Mechanism named:
  a fact about the upstream population copied in as a statement, with nothing re-deriving it
  and a quiet failure direction. Because a round found a defect inside a fix, a quiet round 3
  no longer ends the loop — only an enumeration does (`code-check.md`'s stopping rule).
- The real-file arms' uncaught reader call was how the fold pin went unnoticed-dead. Fixed and
  PROVED: with bulk's `co_ff04` landcover re-keyed in a sandbox, the suite reports 84/1 with
  the bulk arm naming the reader's message, and all five neexdzii arms still run.
