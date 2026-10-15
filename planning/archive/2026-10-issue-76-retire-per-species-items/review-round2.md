# Code review — round 2 — `76-retire-the-per-species-floodplain-items`

Reviewer: code-review subagent, 2026-10-14. Scope: the branch diff against `main`.

Verification performed here: read `scripts/catalogue_release.sh` (all 1069 lines),
`scripts/item_retract_s3.sh`, `scripts/catalogue_release-check.sh`, `scripts/item_register.sh`,
`scripts/item_unregister.sh`, `scripts/README.md`, the `CLAUDE.md`/`NEWS.md` additions and the
four default-moving script edits. `bash scripts/catalogue_release-check.sh` → **ALL PASS**;
`bash -n` clean on all four shell scripts. Three measurements, noted inline: locale collation of
the real watershed-group roster, the installed AWS CLI's return-code logic for `s3 rm` vs
`s3 ls`, and a hand-trace of the curl shim's stage counter for both a retirement release and
`--only`.

## The mechanism behind round 1

Round 1's six findings are three instances of one shape and three of another, and both shapes
still have reachable members on this branch.

**Shape A — two artefacts that must agree, with nothing mechanical joining them.** F1 (prose
asserting a code behaviour the code did not have), F3 (the harness's stage counter against the
script's actual call sequence), F5 (Python `sorted()` against shell `sort`). The fixes closed
the three named instances and did not enumerate the class. Remaining members: **Finding 1**
(prose asserting a capability `item_register.sh` does not have — the same shape as F1, in the
*recovery* path rather than the happy path) and **Finding 2** (the one `sort` site the
`LC_ALL=C` sweep missed).

**Shape B — a guard scoped to the symptom rather than to the property.** F4 guarded the
*character set* of a `RETIRED_ITEMS` entry because the symptom was `../collection.json`; the
property wanted is "this is an item id of this collection". Remaining member: **Finding 3**.

Checked and clean on both axes:

* the `--allow-retract` / `RETIRED_ITEMS` mutual refusal is **complete**. Under
  `ALLOW_RETRACT` the literal is provably empty and vice versa, so every downstream read of
  either (`:485`, `:493`, `:506`, `:775`, `:1041`) is consistent, `unaccounted == orphans` and
  `surplus == extra` in the flag's mode, and `n_retired > 0` implies all four arms are live.
  Case 21g pins the refusal; case 21f no longer depends on the forbidden combination.
* the `LC_ALL=C` sweep covers every *id* comparison. All eight `comm` call sites were walked:
  `:415`, `:445`, `:462`, `:484`, `:766`, `:767`, `:774`, `:1016`, `:1032` now have both sides
  on one ordering. `item_retract_s3.sh:81`'s `sort -u` feeds `grep -qxF`, where order is
  irrelevant. Only `:515` is left (Finding 2).
* the curl shim's stage counter is correct for both paths. Traced: a retirement release issues
  five `/search` calls and the id-only counter puts them on stages 0, 0, 1, 1, 2
  (preflight ids, preflight wsgs, step-5 compare, step-5 deprecation, step-7 re-read) — the
  wsg/deprecated arms read `_n - 1`, which is the stage of the most recent id-only read, i.e.
  the same catalogue their own phase saw. `--only` issues two (stages 0, 1), matching the
  pre-existing `LIVE`/`LIVE_AFTER` semantics. `--skip-sync` changes no `/search` call, so the
  counter holds there too (`--skip-sync` has no harness case at all, pre-existing).
* the new `aws s3 ls` shim behaviour weakens nothing. `aws s3 ls` has exactly one caller in the
  repo (`item_retract_s3.sh:119`); the shim's branch is gated on `$1 = s3 && $2 = ls` and on
  `--summarize`, so no pre-existing case can reach it, and the suite is green.

## Findings

### 1. [bug] The recovery instruction for the only unrecoverable direction names a command that cannot do what it says

`scripts/catalogue_release.sh:1057-1058` (the operator-facing message), and the same claim in
`scripts/item_retract_s3.sh:16-17`, `scripts/README.md:180-181`, `CLAUDE.md:366-367`,
`NEWS.md:56-58`.

The step-7 failure path prints:

```
  re-run this release, or re-register from the bucket copy with
  scripts/item_register.sh, before running scripts/item_retract_s3.sh.
```

and `item_retract_s3.sh:16-17` states it more strongly: *"`scripts/item_register.sh` can
re-register a retired item straight from `s3://<bucket>/<id>.json`"*.

`item_register.sh` cannot read either form. Its only input path is
`json.load(open(f))` over `sys.argv[1:]` (`scripts/item_register.sh:41-45`), so
`scripts/item_register.sh s3://stac-floodplains-bc/morr_co_ff04.json` and the `https://…`
form both die with `FileNotFoundError` — and the build no longer holds `<id>.json`, which is
the whole premise of the sentence. The missing step is a download:

```bash
aws s3 cp "s3://$BUCKET/<id>.json" "${TMPDIR:-/tmp}/<id>.json"
bash scripts/item_register.sh "${TMPDIR:-/tmp}/<id>.json"
```

Why this is worth a message edit rather than a shrug: this is the text printed at the one
moment the catalogue is in a half-done retirement, and it is the stated justification for
`item_retract_s3.sh` existing as a separate script. It is round 1's F1 one axis over — a
documented recipe for a destructive path asserting behaviour the code does not have — and the
harness cannot see it, because case 22 drives `item_retract_s3.sh` directly and no case
re-registers anything.

Second half of the same sentence, worth one clause: re-registering the row restores API
service into a collection whose **bucket** `collection.json` — just republished by the release
that dropped the id — no longer links it. That is the API-and-bucket-disagree state that
`:889-891` and `:906-908` both call out as the one rtj's reload-from-S3 turns into data loss,
and `readme_functions.R`'s item-count check refuses a render in it. So the honest instruction
is "re-register to restore service, then re-run the release", not "re-register" on its own.

### 2. [fragile] `scripts/catalogue_release.sh:515` — the one `sort` the `LC_ALL=C` fix missed, and it feeds a `comm`

```sh
    build_wsgs=$(for f in "$STAC_DIR"/*.json; do
      ...
    done | sort -u) \
    ...
    lost=$(comm -23 <(printf '%s\n' "$live_wsgs") <(printf '%s\n' "$build_wsgs") || true)
```

`live_wsgs` is sorted in Python (`fetch_live_wsgs`, `:201`, codepoint order); `build_wsgs` is
sorted by a bare `sort`, which follows `LC_COLLATE`. F5's fix added `LC_ALL=C` at `:320` and
`:421` and its comment claims it "fixes every comparison in this script at once"; this site was
not reached. It is the group arm — the arm whose own comment at `:499-505` calls it the only
guard that survives `ALLOW_SKIPPED=1`.

Measured here, not assumed:

```
C / en_US.UTF-8 : SSSS TTTT ZZZZ
et_EE.UTF-8     : SSSS ZZZZ TTTT      # Estonian puts Z between S and T
```

Today's 23 group codes collate identically under `C`, `en_US.UTF-8`, `et_EE.UTF-8` and
`lt_LT.UTF-8` — there is no `Z` code in the roster — so the arm is correct on any plausible
host right now. BC does have a `Z` watershed group (`ZYMO`, Zymoetz River), so the exposure is
the roster growing, not an exotic machine alone.

**Direction, measured rather than guessed:** this one fails toward *refusal*, not toward pass.
`comm -23` emits every line of file 1 in either column 1 or column 3, and column 3 requires
exact string equality, so a group genuinely absent from the build can never be skipped. The
reproduction gives a spurious extra "lost" group plus
`comm: file 1 is not in sorted order` on stderr, and the `|| true` swallows the exit 1. So the
realistic harm is indirect: the operator sees a bogus *"These watershed groups are LIVE but no
item in this build covers them"* and the message's own remedy at `:522` points at
`--allow-retract`, which waives every arm. One-token fix: `done | LC_ALL=C sort -u)`.

### 3. [fragile] `scripts/catalogue_release.sh:430-436` + `:462-477` — the F4 guard constrains the character set, not "is an item id", and the F4 symptom is still reachable

The new guard refuses `-*` and anything outside `[A-Za-z0-9_-]`. `RETIRED_ITEMS="collection"`
passes it, and then:

* `also_built`: `local_ids` excludes `collection` by construction (`:319`), so no refusal.
* `not_live` (`:462`): `collection` is not a live item id, so it reaches the bucket witness —
  `curl -sfI "$S3_BASE/collection.json"`, which is a **200**. It is appended to
  `already_retired` and reported *"already retired by an earlier run of this release"*.
* the NEWS arm (`:609-620`) is `grep -qF -- "$id"` over the top entry, and any real release
  entry contains the word "collection".
* `to_delete` (`:1016`) is empty, `still` is empty, and `$API/items/collection` 404s, so step 7
  passes and the release prints `RELEASE COMPLETE`.

Net: exactly F4's symptom — "a release that completes announcing a retirement it never
performed" — reached without a single dot-segment. Nothing is deleted, so this is not a data
hazard; it is a guard that answers a narrower question than the one its own comment states
(`:424-429` says the point is that these ids "reach a URL and a prefix unvalidated").

The cheap strengthening is to make the bucket witness prove identity rather than existence:
read the document rather than HEAD it, and require `type == "Feature"` and `id == <entry>`.
That refuses `collection`, refuses `../collection.json` without depending on the charset, and
also catches an entry that resolves to some *other* item's document. Harness cost is one case
and the existing `FAKE_BUCKET_ONLY_IDS` knob already serves a `type: Feature` body with a
matching `id` (`catalogue_release-check.sh:354-359`), so case 20d keeps passing unchanged.

## Walked and deliberately not reported

Recorded so round 3 does not re-derive them.

* **`aws s3 rm --recursive` on an empty prefix (`item_retract_s3.sh:133`, no `|| true`).** This
  is F2's obvious sibling and it is **not** a defect. Read from the installed CLI
  (`awscli/customizations/s3/subcommands.py:1590-1597`): the `s3` transfer commands return 0
  unless `num_tasks_failed > 0` (1) or tasks warned (2), and an empty prefix produces zero
  tasks. `s3 ls` is the genuine exception — `_check_no_objects()` at `:913-918` returns 1 when
  the first page is empty — so the asymmetry F2's fix relies on is real, and the shim at
  `catalogue_release-check.sh:182-199` models it faithfully.
* **Raw vs normalised literal in the two mutual refusals.** `:141` and `:159` test
  `-n "$RETIRED_ITEMS"` on the raw string while the retirement arms use the whitespace-stripped
  form (`:421`, and `:419-420` says why). A literal of `" "` therefore refuses `--only` and
  `--allow-retract` while being empty everywhere else. Fails closed in both directions; no path
  exists where raw is empty and normalised is not.
* **Dead branch after the mutual refusal.** `[ -z "$ALLOW_RETRACT" ]` at `:1041` and the "Still
  tolerant under `--allow-retract`" comment at `:1039-1040` are now unreachable, since step 7
  only runs when `n_retired > 0`. Harmless; the comment is stale.
* **`NEWS.md` says "Six arms refuse in step 0" and enumerates six.** The F4 shape guard is a
  seventh. A quantifier that moved with a fix.
* **`--skip-sync` reopens the window the step-3 split closes**, for a build that adds items: it
  uploads `collection.json` (`:663`) and no item documents. Pre-existing, and the flag's own
  header scopes it to re-runs where "the assets are already up"; the new prose in
  `scripts/README.md` and `CLAUDE.md` is about the full path and does not claim otherwise.
* **After `item_retract_s3.sh` runs, the same tagged release is no longer re-runnable** — the
  literal's ids are then absent from both the API and the bucket, so the `:468-471` arm refuses
  with "was never published", and the clean-tree and exact-tag gates make clearing the literal
  cost a new commit and tag. That is arguably the correct behaviour (the retirement is done and
  the literal should be cleared) and the message's guidance points there.
* **Weak `expect_out` greps in two new cases.** 20b's `"aaaa_st_ff04"` also matches the
  unconditional "LIVE but absent from this build" list, and 21a's `"RETIRE"` matches three
  different banners. Both are backed by stronger assertions in the same case (`refused()`'s
  rc term, and `n_delete`/`deleted_ids`), and the mutation table shows M1 reddening 20b, so
  neither is a guard that cannot fire.
* **`item_unregister.sh` failing mid-step-6** aborts the release under `set -e` before step 7's
  recovery text prints. Fails closed; diagnostic only.
* `printf '%s\n' $RETIRED_ITEMS` at `:421` is unquoted, so a literal containing `*` would
  pathname-expand before the shape guard sees it — every repo-root entry with a `.` in it then
  trips the guard and refuses. Fails closed.

## Verdict

Three findings. Finding 1 is the one worth acting on before the cutover: it is the text the
operator reads with a half-retired catalogue in front of them. Findings 2 and 3 are both
one-line hardenings of guards that are correct today for reasons outside the code.
