# Review round 2 — release-is-a-tag (#19)

Scope: `git diff --cached` (903 lines) — `scripts/catalogue_release.sh`,
`scripts/catalogue_release-check.sh`, `scripts/collection_version.py`,
`scripts/item_validate.py`, docs, planning. Checked against the Shell Scripts and
General sections of CLAUDE.md's Code Check Conventions. Round-1 findings (NEWS read from
the tag; gpgsign in the throwaway repo) confirmed fixed and not re-reported.

Probes run: `bash -n` both shell scripts and `py_compile` both Python files (clean);
`bash scripts/catalogue_release-check.sh` → ALL PASS, rc 0; throwaway git repos for the
gate predicates (annotated vs lightweight tags, detached HEAD at the tag, a second tag on
the same commit, CRLF headings); a read of the real on-disk `collection.json` (unstamped,
re-serialises byte-identical under `json.dumps(indent=2)`); one anonymous HEAD of the
bucket-root `collection.json` and one GET of the live collection.

## Findings

### [fragile] scripts/catalogue_release.sh:205 — `git describe --tags --exact-match` picks ANY tag on HEAD, and a second tag wins over the `vX.Y.Z` one

No `--match`, so the gate reads whichever tag git prefers among those pointing at HEAD.
Measured in a throwaway repo:

```
lightweight v1.0.0 + lightweight pilot        -> describe picks: pilot
lightweight v1.0.0 + annotated  rc-note        -> describe picks: rc-note
same, with --match 'v[0-9]*'                   -> v1.0.0
```

An annotated non-release tag always wins; between lightweight tags the pick is not the
release one. The gate then compares NEWS.md against `## vpilot` and refuses with
*"NEWS.md's top entry is '## v1.0.0' but HEAD is tagged pilot"* — a false refusal whose
message points at NEWS.md rather than at the stray tag. Every wrong pick I could construct
ends in a refusal (the NEWS compare or `collection_version.py`'s X.Y.Z check stops it), so
this fails loud, not toward pass — flagged because the recipe's "one tag on that commit"
is the only thing holding it, and a `pilot`/`pre-merge` tag beside a release tag is an
ordinary thing to have. The real repo has zero tags today, so it is latent.

One-token fix: `git -C "$REPO" describe --tags --exact-match --match 'v[0-9]*' HEAD`.
Harness case to pin it: tag the fixture commit a second time (`tgit tag -a zz-note -m x`)
before a full release and assert it still passes; with the current code that case is red.

## Checked and not flagged

- **Version gate, both directions**: HEAD past the tag → refused (rc 128 from describe,
  caught); detached HEAD at an annotated tag → `describe` = tag, `status --porcelain
  --untracked-files=no` = '' (passes, correctly); `git show vX:NEWS.md` peels an annotated
  tag the same as a lightweight one. Every `$(...)` in the gate is assigned-then-tested on
  exit status; the `2>/dev/null` on `describe`/`show` are reads and each failure has its
  own refusal message.
- **Step-5 premises**: bucket-root `collection.json` answers `HTTP/1.1 200` to a
  credential-stripped `curl -sI` (the `S3_BASE` shape matches `item_create.py:44` and a
  real item's href host), so the new bucket compare cannot false-fail a by-the-book
  release. The live API serves no `version` today and declares no version extension —
  the first release's step-5 assertion is a genuine MISSING → 1.0.0 transition, not the
  shim's tautology.
- **Failed reads cannot read as a match**: `curl -sf` + a raising parse under `pipefail`;
  `<read failed>` sentinel equals neither a tag nor `MISSING`; under `--only` a failed
  preflight read exits 1 before anything is written.
- **Serialisation claim**: the real `data/stac/collection.json` (4520 B, ASCII) re-serialises
  byte-identical under `json.dumps(indent=2)`, so the stamp changes only the two fields and
  re-stamping is idempotent as the docstring says.
- **item_validate.py half-stamp check**: `has_ext != (version is not None)` is the iff in
  both directions; `continue` on a stamp problem keeps `collections` at 0 but `failed`
  returns 1 first, so the count message cannot mask the real cause.
- **Harness fixture reaches the failure modes it claims**: removing the gate makes cases
  10/11/11b/13 run a full release (aws calls, rc 0) → `refused` goes red; case 9b forces
  the bucket copy alone, so the bucket compare is proven to bite independently of the API
  compare. `refused()` requires both rc≠0 and zero aws calls.
- **Throwaway repo isolation**: `-c commit.gpgsign=false -c tag.gpgSign=false`,
  `--no-verify`, inline identity; only lightweight tags are cut so `tag.forceSignAnnotated`
  cannot reach it. `cp -R` then `add -A` commits the working-tree scripts, which is the
  thing under test.
- **BSD/bash 3.2**: `grep -m1`, `sed 's/^/  /'`, `shasum`, quoted `case` patterns, no
  `\+`/`\|`, no empty-array expansion under `set -u`; `git init -b` needs git ≥ 2.28,
  which a developer machine has.
- **CRLF NEWS.md**: `## v1.0.0 (date)\r` still matches (`"## v$VERSION "*`); a bare
  `## v1.0.0\r` is refused, but the recipe mandates the date. Not flagged.
- **Doc note, not a defect**: `scripts/README.md`'s recipe pushes the tag at step 2, before
  the rebuild and release, while `findings.md` O3 records "push with the evidence". Both
  work (round 1 accepted either); a failed release then leaves a pushed tag for a state
  that never went live, recoverable with `git push --delete origin vX.Y.Z`. Worth one
  sentence in the recipe saying which is intended.
