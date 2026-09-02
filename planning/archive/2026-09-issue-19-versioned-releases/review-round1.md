# Review round 1 — release-is-a-tag (#19)

Scope: `git diff --cached` (767 lines) — `scripts/catalogue_release.sh`,
`scripts/catalogue_release-check.sh`, `scripts/collection_version.py`,
`scripts/item_validate.py`, docs, planning. Checked against the Shell Scripts and
General sections of CLAUDE.md's Code Check Conventions.

Probes run: `bash -n` both shell scripts, `py_compile` both Python files (clean);
`bash scripts/catalogue_release-check.sh` → ALL PASS, rc 0; the live API listed for
collection-level `version` round-trip; a throwaway git repo for the gate predicates.

## Findings

### [bug] scripts/catalogue_release.sh:211–232 — an untracked `NEWS.md` passes every gate, and the tag then contains no `NEWS.md` at all

The NEWS gate reads the **working-tree** file (`[ -f NEWS.md ]`, `grep -m1 -E '^## ' NEWS.md`),
and the clean-tree gate runs `git status --porcelain --untracked-files=no`, which by design
hides untracked files. So a `NEWS.md` that was written, never `git add`ed, and left beside a
tagged commit satisfies all three gates while the tag the release publishes under does not
contain the entry the gate just read. The release stamps and publishes vX.Y.Z; the commit
`vX.Y.Z` points at has no NEWS entry — the exact pairing the gate exists to enforce is
unenforced in the one shape it will meet first.

Measured (throwaway repo, tag on an empty commit, `NEWS.md` on disk only):

```
describe:                 v1.0.0          <- gate 1 passes
dirty(untracked=no):      ''              <- gate 2 passes
[ -f NEWS.md ]:           yes             <- gate 3 passes
grep -m1 '^## ':          ## v1.0.0 ...   <- gate 3 passes
git show v1.0.0:NEWS.md:  fatal: path 'NEWS.md' exists on disk, but not in 'v1.0.0'
```

This is not hypothetical: **the real repo is in this state right now** — `git status`
shows `?? NEWS.md` — and the first release (Phase 4) is by definition the one where
`NEWS.md` is a brand-new file. A forgotten `git add NEWS.md` before `git commit && git tag`
is the ordinary first-release mistake and the gate waves it through. Fails toward pass.

The harness cannot reach it: the fixture `tgit add -A`s `NEWS.md` before tagging, so every
case has it tracked (fixture-cannot-reach-the-failure-mode).

**Fix:** read `NEWS.md` from the tag, not from disk. That closes untracked, and it also makes
the predicate say what it means ("the tag's NEWS.md names the tag") rather than relying on
the dirty gate to make the working copy stand in for the committed one:

```bash
if ! news=$(git -C "$REPO" show "$tag:NEWS.md" 2>/dev/null); then
  echo "No NEWS.md in $tag — every release is described there first, in the tagged commit." >&2
  exit 1
fi
if ! news_top=$(printf '%s\n' "$news" | grep -m1 -E '^## '); then ...   # unchanged from here
```

Capture the whole file first rather than piping `git show` straight into `grep -m1`:
under `set -o pipefail` an early-exiting `grep -m1` can SIGPIPE `git show` on a file larger
than the pipe buffer and turn a valid NEWS.md into a false refusal. Measured the `git show`
form on all three states: untracked → refused; tracked → passes with the heading; tracked-
but-modified → the dirty gate still fires (` M NEWS.md`), so nothing is lost.

Harness case to pin it (between cases 11 and 13): `tgit rm -q --cached NEWS.md && tgit commit
-q --no-verify -m "news untracked" && tgit tag -f "v$TVERSION" >/dev/null`, `run_release`,
`refused`, then `tgit tag -f "v$TVERSION" "$TSHA" && tgit reset -q --hard "$TSHA"`. With the
current code that case is green — which is the restore-the-bug check the fix needs.

### [fragile, low] scripts/catalogue_release-check.sh:57 — the throwaway repo inherits the developer's signing config despite the comment saying it does not

`tgit` passes `-c user.name`/`-c user.email` and `--no-verify`, and the comment says the
harness "does not depend on the developer's git config". It still reads `commit.gpgsign`,
`tag.gpgSign` and `init.templateDir` from the global config. On a machine with signing on,
the fixture commit blocks on a passphrase prompt (stdin is the terminal here) or fails
outright, which reads as a broken harness. This machine has `commit.gpgsign=false`, so it
is latent, and it fails loud rather than silent — flagged only because the comment makes a
claim the code does not keep. One line closes it: add `-c commit.gpgsign=false
-c tag.gpgSign=false` to `tgit`.

## Checked and not flagged

- **API round-trip of a collection-level `version`** (the premise every step-5 assertion
  rests on, and the one thing the curl shim supplies tautologically): measured on the
  live API — `imagery-uav-bc-prod` serves `version='1.0.1'` and `stac-elevation-bc`
  `'2.0.0'`, both with the extension declared, through the same pgstac stack. Holds.
- **Guards failing toward skip/pass**: every `$(...)` in the gate and step 5 is
  assigned-then-tested on exit status; `curl -sf` + a raising parse under `pipefail`
  means a failed read cannot equal `MISSING`; the `<read failed>` sentinel cannot equal
  a tag. Correct in both directions.
- **Empty result sets**: `grep -m1` on a heading-less NEWS.md refuses; `describe` on an
  untagged HEAD refuses; verified by cases 10 and 11.
- **Stamp before the validation gate, after every refusal**: confirmed by code order;
  a step-1+ failure leaves a stamped build, which is idempotent on re-run and
  overwritten by a rebuild. The harness cannot pin "a refusal leaves the build
  untouched" because case 2 stamps the shared fixture first (plan review O1) — a gap,
  not a defect.
- **`--skip-sync` on a full release** now `aws s3 cp`s the stamped collection, and
  step 5 reads the bucket copy back (case 9b). The stated rationale for the flag still
  holds against the new guarantee.
- **The recipe's rebuild between tag and release**: `run_pipeline.sh` writes nothing
  tracked (no `>>`/`tee`/log writes), so the clean-tree gate does not refuse a
  by-the-book release.
- **`collection_version.py` serialisation** matches `item_create.py`
  (`json.dumps(indent=2)`, `write_text`, no trailing newline); idempotency claim holds.
- **BSD/bash 3.2**: `grep -m1`, `sed -E`-free `sed 's/^/  /'`, `shasum`, no `\+`/`\|`,
  no empty-array expansion under `set -u`, quoted `case` patterns. Portable.
- **Curl shim routing**: `*/collections/$COLLECTION` is anchored at the end, so the item
  URL (`.../items/<id>`) and the bucket URL fall through correctly; the `-w` branch is
  tested first so the 200 probe never hits the collection branch.
- **Local-only tag accepted** (no check the tag is on origin): the recipe pushes first
  and the plan review chose push-after-evidence; either way the tag exists locally and
  the version is recoverable. Not flagged.
