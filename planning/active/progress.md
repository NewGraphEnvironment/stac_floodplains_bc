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
- Phase 2 + 3 (one commit, because the release script and its harness cannot be green
  separately): `collection_version.py` (stdlib stamp; probed: idempotent to the byte, refuses
  `''`, `1.0`, `1.0.0-rc1`, `v1.0.0`, a Feature, and a missing arg); `catalogue_release.sh`
  version gate (HEAD exactly at a tag, clean tracked tree, first `## ` heading of NEWS.md is the
  tag, stamp, read-back) and step-5 verify (API version == tag, bucket copy == tag; `--only`:
  unchanged, MISSING allowed); `item_validate.py` half-stamp check; docs.
  Harness: runs the release from a throwaway tagged git repo; cases 8, 9, 9b, 10, 11, 12, 13
  added; ALL PASS. Restore-the-bug, both red as required:
  - step-5 compare removed → 5 FAILED (cases 8 and 9 go red, nothing else)
  - stamp + read-back removed → 6 FAILED (case 2's five version assertions and case 1's
    "unchanged" read)
  Plan review folded in before the commit — see findings.md for the 17-row disposition.
- Full rebuild (`run_pipeline.sh`, started tag-independently during Phase 2): 18:00:09Z →
  18:07:35Z UTC, 7.5 min, exit 0. **20 items** + collection, no `PARTIAL_STAGE`, validator
  clean (11 nge: properties, COG layout, RAT on every COG).
- Validator proof against that real tree (review G3 — the harness shims `uv` away, so this is
  the only exercise of the check): unstamped build → pass, "collection version: unstamped";
  stamped 1.0.0 → pass, "collection version: 1.0.0"; extension removed with version kept →
  FAILED "half-applied: extension absent, version '1.0.0'"; version removed with extension kept
  → FAILED "half-applied: extension declared, version None". collection.json restored to the
  build's bytes (cmp) afterwards.
- `/code-check` round 1 (`review-round1.md`): one bug — the NEWS gate read the working-tree
  file, so a NEWS.md written but never added passed all three gates while the tag held no
  entry (the exact first-release shape, and the real repo was in it at the time). Fixed: the
  gate reads `git show "$tag:NEWS.md"`, captured whole before the grep. Harness case 11b
  pins it; against the pre-fix script that case goes red (2 FAILED), fixed script ALL PASS.
  Also: throwaway repo now sets `commit.gpgsign=false` / `tag.gpgSign=false`.
- `/code-check` round 2 (`review-round2.md`): one fragility — `describe --exact-match` without
  `--match` prefers any other tag on the commit (an annotated note always wins), so a stray
  `pilot` tag beside the release tag refused with a message blaming NEWS.md. Fixed with
  `--match 'v[0-9]*'`; case 14 (annotated `zz-note` beside `v9.9.9`) pins it: red without the
  flag (2 FAILED), ALL PASS with it. Recipe settled on push-the-tag-after-RELEASE-COMPLETE.
- `/code-check` round 3 (`review-round3.md`): Clean, converged — rounds 1 and 2 were one
  class (a gate reading a proxy for its subject), and every read the release makes now reads
  its actual subject and branches on its own exit status. Committed as Phases 2 + 3.
- Phase 4: NEWS.md written from the rebuilt collection's own summaries (20 items, 19 groups,
  4 regions, 4 scenarios); this commit is the one tagged v1.0.0. Between the tag and
  RELEASE COMPLETE nothing tracked is touched — the gate refuses otherwise by design.
- **v1.0.0 released.** `catalogue_release.sh` 18:40:59Z → 18:46:06Z UTC (5.1 min), exit 0:
  gate passed (HEAD at v1.0.0, tree clean, NEWS agrees), validator clean on the stamped
  collection, 161 objects uploaded across 20 item prefixes + the 21 JSON documents
  (assets: Completed 106.9 MiB/106.9 MiB), 20 items registered, verify: asset + checksum probe on bowr_ch_ff04 OK,
  `live collection version: 1.0.0 — matches the tag just released`,
  `bucket collection.json version: 1.0.0 — agrees`, `RELEASE COMPLETE — v1.0.0: 20 items live`.
- Acceptance, read back independently of the release script afterwards:
  - `curl $API | jq .version` → `"1.0.0"`; `.stac_extensions` →
    `["https://stac-extensions.github.io/version/v1.2.0/schema.json"]`
  - fielded `/search` → 20 items; bucket `collection.json` → version 1.0.0
  - `git tag -l` → `v1.0.0`; `git show v1.0.0:NEWS.md` top → `## v1.0.0 (2026-09-02)`
  - Before the release the same API read returned MISSING with no extensions, so the step-5
    assertion measured a real MISSING → 1.0.0 transition, not the harness's tautology.
- Merge note: tag already cut on the NEWS commit and pushed after RELEASE COMPLETE; there is
  no `DESCRIPTION`, so `/gh-pr-merge` steps 6–9 are n/a for this merge — say so when running it.
