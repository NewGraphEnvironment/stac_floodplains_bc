# Progress — Produce the provenance floor and census numbers (#82)

## Session 2026-10-15

- Plan-mode exploration: read `fp_provenance.R`, `fp_provenance-check.R`, `01_stage.R`'s roster
  walk and target loop, `prov_fields-check.py`'s census arms, both literals and their comments,
  `scripts/README.md`, and issues #82 / #89.
- Measured the roster census with a throwaway probe (in `findings.md`) — 23 rostered, 20 staging,
  20 carrying provenance — which surfaced the skip-before-read ordering the issue's spec does not
  carry.
- Two decisions taken at the plan gate (airvine): reconcile with `prov_fields-check.py` by naming
  all three destinations in the output and adding a static no-copy arm, keeping its asserted
  counts; and on a skipped target, print the census with a loud banner and exit 0.
- Phases approved by user. Created branch `82-produce-the-provenance-floor-and-census` off main.
- Next: Phase 1, `scripts/prov_census-measure.R`.

### Phase 1 — the script
- `scripts/prov_census-measure.R` lands: roster walk mirroring `01_stage.R`'s selection and
  order, `PROV_FIELDS` parsed out of `01_stage.R`, the reader driven per target, refusal on any
  failed read, banner + exit 0 on a skip, paste-ready block naming all three destinations.
- Run on the real tree: 23 rostered / 20 staged / 20 carrying, `link_run_uid` 18,
  `link_config_sha256` and `link_sha` 19 — equal to the planning probe. `dunc_all_ff04` is the
  one item short of all three log-sourced fields, `mcgr_all_ff04` short of `link_run_uid` alone.
- Fixed while testing: the roster total was `staged + skipped`, which is only right while every
  skip is a target rather than a whole group. Counted from the targets each `area.yml` declares
  instead, with groups declaring none reported on their own line.

### Phase 2 — the refusal proven
- Seven sandbox arms, each told apart by its own message (`findings.md` carries the table and the
  commands): unreadable record, moved schema and a mid-write raster each refuse with no census;
  the no-record control still prints one; a missing bundle and a missing `area.yml` skip by name.
- Added a guard the plan did not have: nothing staged is now its own refusal. The skip arms were
  printing `PROVENANCE_FLOOR=0` and exiting 0, and 0 is both a legitimate past value and what a
  reader that found nothing produces.

### Phases 3 and 4, and the plan review folded in
- The review landed mid-Phase 4 and moved Phase 1 as well: see `findings.md` for the three
  load-bearing findings (the `processing:software` pairing and today's aborting build; the
  no-rasters skip swallowing a build stop; `fp_prov_span()` never called), what was declined and
  why, and the mutation table for the five new arms.
- Docs: `scripts/README.md` gains its own section naming it a measurement and the pre-flight
  rather than the authority; `CLAUDE.md` and `NEWS.md` likewise, plus the aborting-build finding.
- Issues: #90 filed for the `fp_roster.R` extraction the mirror defers (the number was written
  only after filing). #89's body corrected in two places — its DUNC bullet, which was wrong about
  the build, and step 3, which now names the build's own `census:` line as the authority.
- `prov_fields-check.py`: three arms over the literals, a comment naming the producer, and a note
  that the all-absent fixture population stays even though the live catalogue no longer has one.

### /code-check branch, round 1 (4 findings, all 4 real, all 4 fixed)
- **The group-level order was reversed.** `01_stage.R` reads the record at `:233` and skips a
  missing bundle at `:251`; the draft had it the other way, so a group with a broken record AND
  no bundles was a recorded skip with a pasteable census where the build stops outright. Hoisted.
- **A target with no `transition.tif` was counted as staged.** `fp_prov_rasters_current()`
  filters to `file.exists()`, so it cannot see an absent one, and `01_stage.R:443` stops the
  build on it. Checked explicitly now, between the two calls the build makes either side of it.
- **The paste-block arm was satisfied by prose.** This file's name appears in an R comment three
  lines above the `cat()` that prints it, so the arm passed with that `cat()` deleted. The block
  is now stripped of comment lines before the test — re-mutated, and it fires.
- **Two targets of one group with the same scenario** would count an item twice in the census and
  once in the floor, with the accounting identity still satisfied. Refused by id now.
- Fixed en route: two citations of `01_stage.R:375` for a skip that is at `:380`.

### /code-check branch, round 2 (5 findings, all 5 real, all 5 fixed)
- The mechanism is named in `findings.md`: fidelity was established against the one tree that
  exists, on which each arm's distinguishing case is unreachable.
- Two findings were inside round 1's fixes, and the fix for them recurred the mechanism once
  more on the shell side — so both languages now go through one quote-aware `_code_only()`.
- Terminated by enumeration, not by a quiet round: all eight source-text reads in
  `prov_fields-check.py` tabulated with why each cannot be satisfied by prose, `grep` showing no
  raw-text presence test remains, and six mutations firing on their own arms' messages.

### /code-check branch, round 3 (1 finding, real, fixed) + a falsified claim
- Round 3 attacked both enumerations and neither broke: the source-text set is exactly eight
  (14 mutations, all firing), and a 38-row fidelity table from `01_stage.R` shows no miss, with
  every decline in the direction where the build stages fewer items or stops.
- Its finding is a third mechanism — an undated count restated in several copies, where round 2's
  fix reached one of them. Enumerated by grep over the branch's added prose: 68 hits, 58
  structural, 10 about the tree, 5 of those stale. All corrected.
- While the review ran, the upstream Columbia run finished and **falsified this branch's own
  DUNC claim**: `link_sha` resolves from a log row as of 18:38Z, so that arm no longer refuses.
  Corrected in
  `CLAUDE.md`, `NEWS.md`, both scripts and #89's body; the measurement is a comment on
  floodplains#133, which stays open for its owner.

### /code-check branch, round 4 (9 findings, no bugs, all fixed) — and the loop ends
- Round 4 showed mechanism 3's enumeration was not one: it grepped added lines in three paths, so
  it missed four surviving copies, the PR draft and the issue bodies. Redone with no filters over
  every touched file plus the draft and three issue bodies; it found a 12th instance the reviewer
  had not named — `CLAUDE.md`'s "it cannot be cut yet: 13 of the 23 rostered groups", the sentence
  a future agent would read to decide whether the cutover can happen.
- One claim was falsified rather than stale: "the state recurs whenever upstream cannot resolve a
  sha". Measured, all 23 `all*` sections carry a null `inputs$link$sha` and all 23 publish. The
  condition is both sources empty; corrected in four places.
- Loop terminated by enumeration on all three mechanisms, not by a quiet round: 38 rows for build
  fidelity, 8 source-text arms with 14 mutations, and the unfiltered sweep above.
