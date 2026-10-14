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
