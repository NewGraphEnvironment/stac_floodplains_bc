# Progress — Versioned catalogue releases: STAC Version Extension stamp + NEWS.md + git tags (#14 item 3) (#19)

## Session 2026-09-02

- Plan-mode exploration — phases approved by user; instruction: run all phases through to PR
- Created branch `19-versioned-catalogue-releases-stac-versio` off main
- Scaffolded PWF baseline from issue #19 with approved phases
- Next: start Phase 1
- Phase 1: `git mv scripts/05_stac_register.py scripts/item_create.py`; 28 exact-string
  replacements across 13 files (every live reference, including the bare `05` step names in
  comments). Residue grep empty outside `planning/`; `py_compile`, `bash -n`, R `parse()` and
  `catalogue_release-check.sh` (ALL PASS, same as the pre-rename baseline) all green.
  `/code-check` deliberately skipped for this commit: mechanical rename, verified by the greps.
