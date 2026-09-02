# Review round 3 — release-is-a-tag (#19)

Scope: `git diff --cached` (1018 lines) — `scripts/catalogue_release.sh`,
`scripts/catalogue_release-check.sh`, `scripts/collection_version.py`,
`scripts/item_validate.py`, `scripts/README.md`, `README.md`, `CLAUDE.md` (repo section),
`planning/active/*.md`. Checked against the Shell Scripts and General sections of CLAUDE.md's
Code Check Conventions. Round-1 (NEWS read from the tag; gpgsign) and round-2 (`--match`;
push-after-complete) findings confirmed present in the code and not re-reported.

Probes run: `bash -n` both shell scripts and `py_compile` both Python files (clean);
`bash scripts/catalogue_release-check.sh` → ALL PASS, rc 0; `scripts/collection_register.sh`
read for its load method; `item_validate.py` main loop read for failure ordering;
`item_create.py` read for its collection serialisation; `.gitignore` checked for
`scripts/__pycache__` and `data/stac/`; the real repo's state (`?? NEWS.md`, zero tags);
throwaway git repo for the remaining wrong-pick shapes and two NEWS heading variants.

## Clean

No issues found.

## Convergence — stated by mechanism, not by instance count

The brief for this round was to name the mechanism behind any defect class rather than hunt
more instances. Rounds 1 and 2 were both the same class: **a gate reading a source other than
the one it claims to describe** (the working-tree NEWS.md instead of the tag's; whichever tag
git preferred instead of the release tag). The question for convergence is whether any gate or
verify still reads a proxy for its subject. Walking each one:

| gate / verify | subject it claims | what it actually reads | proxy? |
|---|---|---|---|
| HEAD is at a release tag | the tag HEAD sits on, release-shaped | `describe --tags --exact-match --match 'v[0-9]*' HEAD` | no — exact, filtered |
| tree is clean | tracked files equal the tag | `status --porcelain --untracked-files=no`, exit tested | no |
| NEWS names the tag | the tagged commit's NEWS.md, first `## ` | `git show "$tag:NEWS.md"`, captured whole, then `grep -m1` | no |
| stamp landed | the value on disk | `version_of < collection.json` re-read after the write | no |
| validator half-stamp | ext ⇔ version on the document about to publish | the same document, both directions | no |
| API version | what the API serves after register | `curl -sf "$API" \| version_of`, exit tested | no |
| bucket version | what rtj's reload would read | anonymous GET of the bucket object, exit tested | no |
| `--only` unchanged | live version before vs after | two guarded reads, string compare | no |

Every read in that table branches on its own exit status, and every failure sentinel
(`<read failed>`, `MISSING`) is a value no tag can equal, so no comparison can pass on an
empty-equals-empty. The one remaining wrong-pick — two `vX.Y.Z` tags on one commit — was
measured: `describe` returns `v1.0.0` when `v1.0.0` and `v1.0.1` are both on HEAD (either
lightweight, or `v1.0.0` annotated), and NEWS naming `v1.0.1` then refuses with a message
naming the wrong tag. That is the round-2 accepted residual, loud not silent, and it is
**terminal by enumeration**: `--match` restricts the candidate set to release-shaped tags,
and within that set there is no further attribute to filter on — two release tags on one
commit is a contradiction in the convention itself, not a pick the gate could resolve.

The change has converged. The last two rounds each found one instance of one class; this
round finds the class closed on every read the release makes.

## Checked and not flagged

- **A second release can move the served version.** `collection_register.sh` loads with
  `pypgstac load collections --method upsert`, so 1.0.0 → 1.0.1 replaces the row content.
  Had it been `insert_ignore`, the first release would pass and every later one fail loudly
  at step 5 after the 700 MB sync — worth confirming because the step-5 compare only detects
  *transitions*; a re-release of the same version against a register that silently no-ops
  is indistinguishable from success. Same tautology the harness header already names for
  case 2; not new, and the wholesale item read-back is where the equivalent guard lives.
- **`aws s3 sync` uploads the stamped collection on every full release.** The stamp rewrites
  the file (`write_text`, even when bytes are unchanged) so the local mtime is newer than the
  bucket's, and the size changes on a version transition; sync uploads on either. The bucket
  compare in step 5 then reads what was written, not what was assumed.
- **Validator ordering.** `failed` is reported before the `collections != 1` check, so a
  half-stamp `continue` cannot surface as the count symptom. The two `VERSION_EXT` literals
  (stamp and validator) are duplicated deliberately; if they ever diverge the validator's
  iff refuses — a divergence fails toward refuse, not toward pass.
- **Serialisation.** `item_create.py` writes `collection.json` with
  `json.dumps(indent=2)` and no trailing newline (`item_create.py:467`); the stamp uses the
  same call, so idempotent re-stamping is byte-stable as the docstring claims.
- **Stamp placement.** The version gate sits after the ssh probe, the live read and the
  orphan check, and before the validator. Every refusal above it leaves the build untouched;
  a failure at or after step 1 leaves a stamped build that a re-run overwrites (any version)
  and a rebuild wipes. `stamp()` raises before `write_text` on a bad version, so a refused
  stamp cannot leave a partial file.
- **`--skip-sync` on a full release** still `aws s3 cp`s the stamped collection before
  registering, so the bucket compare cannot false-fail a by-the-book skip-sync run, and the
  flag's stated rationale survives the new guarantee (the round-1 check, re-read against the
  final code).
- **`--only` never stamps and never reads git.** Case 12 pins the byte-identity; a release-only
  machine with no checkout can still run `--only`. The three `skipped under --only` lines are
  counted (3), so a new skip added silently would fail case 1.
- **Real repo state.** `?? NEWS.md`, zero tags — exactly the round-1 shape. The fixed gate
  refuses it via `git show` (case 11b), and `scripts/__pycache__` / `data/stac/` are ignored
  so the recipe's rebuild cannot dirty the tracked tree.
- **NEWS heading variants.** A tab after the version is refused (same class as a bare CRLF
  heading, accepted in round 2 — the recipe mandates `## vX.Y.Z (YYYY-MM-DD)`); a BOM'd
  heading is refused by the `case` compare. Both loud.
- **Harness isolation.** `tgit` overrides identity and signing and the fixture uses only
  `--no-verify` commits; the developer's global config here carries no hooks, templates,
  `fsmonitor` or editor setting that a non-interactive `tag`/`commit` could block on. A
  probe of mine stalled once without `GIT_CONFIG_GLOBAL=/dev/null` and not with it, but the
  harness itself — same git, same `-c` overrides, same `/private/tmp` layout — ran ALL PASS
  in the same session, so that stall is not attributable to the diff.
- **BSD/bash 3.2.** `grep -m1`, `sed 's/^/  /'`, `shasum`, quoted `case` patterns, no
  `\+`/`\|`, no empty-array expansion under `set -u`. `VERSION` is derived from a refname,
  which cannot contain `*`, `?` or `[`, and is quoted in the `case` pattern regardless.
- **Docs.** `scripts/README.md` recipe, `README.md` guard line and the `CLAUDE.md` paragraph
  all describe the code as shipped (stamp before validate, push after RELEASE COMPLETE,
  `--only` moves no version, never hand-register the collection). Nothing below the
  visibility marker references private infrastructure.
