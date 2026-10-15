# Code-check round 4 — the enumeration round

Reviewed at `e3769c0` ("Class D enumerated and made self-policing"), which landed **during** this
review. Bytes reviewed:

```
a50c3ee…  scripts/catalogue_release.sh
8785675…  scripts/catalogue_release-check.sh
e7da9a8…  scripts/item_retract_s3.sh
```

Method note, because it affects what this report is worth: at 02:42 UTC the working tree held
`catalogue_release.sh` and `catalogue_release-check.sh` **modified**, and one hunk I read at 02:43
disagreed with the same line read at 02:41. I snapshotted (`cp -r`) and reviewed the snapshot;
by 02:51 the tree was clean at `e3769c0` with the snapshot's exact hashes, so the snapshot is that
commit. `bash scripts/catalogue_release-check.sh` from the snapshot: **ALL PASS**. Every mutation
below was run in a `cp -r` copy; the repo's own tree was never patched.

---

## Findings

- **[fragile]** `scripts/catalogue_release-check.sh:924-965` — `case 20-assertions`, the guard
  just added to close class D, **matches only lines whose stripped text begins with `echo `**
  (`if ls.startswith("echo ")`). Measured over the two scripts it scans: **155 of 227
  emitting lines are visible, 72 are not.** Invisible are every `|| { echo … }`,
  `[ … ] || { echo … }`, `*) echo …;;` and `printf` site — including
  `catalogue_release.sh:1082`, `[ "$fail" -eq 0 ] || { echo "RELEASE INCOMPLETE" >&2; exit 1; }`.
  `RELEASE INCOMPLETE` is therefore reachable from `:1082` (the pre-delete gate) **and**
  `:1144` (step 7's post-delete failure) — the one distinction cases 21b and 21c exist to
  make — and the guard reports the set clean.

  Proven, in a copy, by planting two `expect_out` patterns before case 20a:

  | planted pattern | sites | guard |
  |---|---|---|
  | `RETIRED_ITEMS names` (4 bare-`echo` lines) | `:454 :511 :516 :701` | **FLAGGED** |
  | `refusing to publish blind` (5 `\|\| { echo … }` lines) | `:334 :384 :397 :571 :619` | **not flagged** |

  Three of those five — `:334`, `:571`, `:619` — are preflight refusals reachable in the same
  run, which is precisely the ambiguity the guard is for. Two consequences: the three-entry
  allowlist exists because three ambiguities happened to be *visible*, not because the class was
  walked; and there is **no mutation-table row for `20-assertions`** — unlike `20-sorts` and
  `20-pipes`, nothing has yet shown it fires. (It does fire, for the half it can see; the table
  row should say which half.)

  Fix: match `\b(echo|printf)\b` anywhere in the code part of the line, then re-take the
  allowlist. `RELEASE INCOMPLETE` then needs an entry with its reason (two spellings of one
  outcome; 21b is pinned by its sibling `grep -c '=== 6: RETIRE ===' == 0`). Also consider
  flagging `len(hits) == 0` for patterns that are literals — today a zero-hit literal passes.

- **[fragile]** `scripts/catalogue_release-check.sh:999-1000` — case 20b's
  `expect_out "names the unaccounted id" "aaaa_st_ff04"` is satisfied by the **generic orphan
  listing** at `catalogue_release.sh:536-537`, which prints every orphan on every orphan, not by
  the containment arm's own message at `:540-541`. A live open member of class D, and one
  `20-assertions` structurally cannot see (it does not read `printf`, and the pattern is a
  runtime value, not a literal in the source).

  Proven: in a copy, deleted `catalogue_release.sh:540-541` (the message **and** the id list),
  keeping `exit 1`. Case 20a went red; **case 20b stayed fully green on both assertions.**
  Fix: assert the arm's own phrase as well (`not named in RETIRED_ITEMS` plus the id), or assert
  `grep -c` of the unaccounted block.

- **[fragile]** `scripts/catalogue_release.sh:141` and `:159` — both test
  `[ -n "$RETIRED_ITEMS" ]` on the **raw** literal, which is exactly what `:426-427` forbids in
  prose three hundred lines later: *"`grep -c .` over the normalised form, never
  `[ -n "$RETIRED_ITEMS" ]` on the raw literal: a literal holding only whitespace is empty in
  fact and non-empty to `-n`."* Proven with `RETIRED_ITEMS="   "`:

  ```
  $ STAC_DIR=/nonexistent bash scripts/catalogue_release.sh --only aaaa_ch_ff04
  --only and a non-empty RETIRED_ITEMS do not combine: a retirement publishes a
  smaller COLLECTION, and --only never publishes the collection.   (rc=1)
  ```

  Nothing is being retired (`n_retired` would be 0), so this is a false refusal with a remedy
  that describes a state the operator is not in. One-directional and safe — `n_retired > 0`
  implies `-n` is true, never the reverse — so it cannot let a retirement through. Class A (two
  places decide "is the literal empty", the rule is written beside one of them) and class B (the
  guard tests the literal's *text*; the property wanted is "does this release retire anything").
  Fix: hoist the normalisation above the arg-parse refusals and test `n_retired`.

- **[bug]** `scripts/catalogue_release.sh:739-750` — **`--skip-sync` on a full release that ADDS
  items publishes a `collection.json` linking item objects that were never uploaded.** On that
  path the only S3 write is `aws s3 cp "$STAC_DIR/collection.json" "s3://$BUCKET/collection.json"`
  (`:748`); no item JSON is sent. Nothing refuses the combination — the three mutual-exclusion
  arms at `:130`, `:141`, `:159` say nothing about `--skip-sync` — and **nothing reads back
  whether the bucket holds an object for each id the published collection links**: step 5
  compares ids against the API (`:851-864`), probes one asset and one checksum of
  `head -1 local_ids` (`:865-891`), and the only `"$S3_BASE/…"` reads in the whole script are
  `collection.json` (`:978`, `:1065`), `$ONLY.json` (`:383`) and the not-live witness (`:491`,
  `:498`) — measured by grep, no read over `local_ids`.

  That is the precise window the sync split at `:794-809` was added to close, and the comment
  there states why it matters now: *"Latent on every release so far, because none of them ADDED
  an item… The release that completes floodplains#125 adds 17 at once."* On the normal path the
  invariant holds by ordering plus `set -e`. `--skip-sync` removes the ordering and leaves the
  invariant asserted by nothing. The consequence is the stac-dem-bc incident: rtj's
  reload-from-S3 reads those `rel: item` hrefs, `DELETE`s every row of the collection, then
  discovers a 404 and aborts — collection serving zero items, bucket versioning Suspended.

  It also survives a *failed* release: the `cp` is at step 2+3 and the asset probe that would
  notice is at step 5, so `RELEASE INCOMPLETE` prints with the hazardous `collection.json`
  already live, and the message says nothing about it.

  `--skip-sync` is pre-existing and the accepted tradeoffs note it has no harness case; the
  *reachability* is new, and arrives with this branch for the same reason finding #7 did.
  Minimum fix, in the preflight beside the other mutual exclusions: refuse `--skip-sync` when
  `comm -23 <(local_ids) <(live_ids)` is non-empty, i.e. when the release adds an item. (On a
  first release every id is an add, which is also exactly when skipping the sync is wrong.)
  Stronger fix: a step-5 `curl -sI -w '%{http_code}'` over `"$S3_BASE/$id.json"` for every id in
  `local_ids` — ~23 HEADs, and the only thing that would turn the ordering argument into
  evidence.

- **[fragile]** `scripts/catalogue_release-check.sh:897-986` — the two static enumerations scan
  `catalogue_release.sh` and `item_retract_s3.sh` only. `item_unregister.sh` is the script step 6
  invokes to perform the pgstac delete and is **not** in either population. Measured: it has zero
  `sort` invocations and zero early-exiting pipeline consumers today, so both classes are empty
  there in fact — but a class closed by "no members" is only as wide as the files read, and the
  destructive path is three scripts, not two. One-line fix: add it to both `sys.argv` lists.

---

## Enumerations

**A (two artefacts that must agree, nothing mechanical joining them) — OPEN, two members.**

Closed members, re-checked rather than taken on trust:

| claimed member | verdict, and how |
|---|---|
| recipe vs code | closed. `README.md:163-180` Replacement passes no `--allow-retract` and `:195-215` Removal publishes **before** unregistering, so its "`--allow-retract` is required at step 3" is true on its own ordering (orphans non-empty at that point). Round 1's false claim is gone |
| the containment arm's remedy | closed. `:545-553` branches on `n_retired` |
| the group arm's remedy | closed. `:587-594` branches on `n_retired`, and says the flag would waive this very arm |
| step-7 recovery text (×5) | closed by full-text check of all five: `catalogue_release.sh:1149-1151`, `item_retract_s3.sh:18-21`, `README.md:181-188`, `CLAUDE.md:367`, `NEWS.md:60` — every one says local file/path |
| harness stage counter vs call sequence | closed. The shim counts only the id-only search; a retirement release makes exactly three (`:333`, `:834`, `:1114`), matching the three stages, and the wsg/deprecated searches read the current stage without advancing it |
| Python `sorted()` vs shell `sort` | closed statically by `20-sorts`, with the three planted shapes recorded in mutation table part 5 |
| `NEWS.md`'s arm count | closed by removal |
| the two bucket witnesses | closed. `catalogue_release.sh:491-526` and `item_retract_s3.sh:129-156` are the same three-outcome `case` on `$code`/`$ident`, read side by side |

Still open: **`[ -n "$RETIRED_ITEMS" ]` at `:141`/`:159` against the normalised-form rule at
`:426-427`**, and **the bucket's `collection.json` links against the bucket's item objects**
(finding 4).

**B (a guard scoped to the symptom, not the property) — OPEN, one new member.** The three
recorded members are closed: the release witness and `item_retract_s3.sh` guard 4 both ask the
document for its `type`/`id` (`:504`, `:139`), the NEWS match is delimited (`:697`), and
`20-sorts` is per-occurrence. The fourth member is `[ -n "$RETIRED_ITEMS" ]` — the literal's text
standing in for "does this release retire anything". That is the third consecutive round in which
a class declared complete gained a member.

**C (an early-exiting pipeline consumer under `set -o pipefail`) — closed, checked by**
`case 20-pipes` (static, proven by planting a piped `grep -q`) **plus an independent re-scan of
both files for shapes its regex does not cover**: no `| read`, no `| sed -n '1p'`, no
`| awk '…exit'`, no `| grep -q` whose consumer sits on a continuation line, no `| head -c`. The
`python3 -c` consumers at `:498-505` and `item_retract_s3.sh:133-139` call `json.load(sys.stdin)`,
which drains stdin, so they are not members. One scope caveat only: `item_unregister.sh` is
outside the scanned population and has zero members today (finding 5).

**D (a fixture or assertion that cannot reach the state under test) — OPEN.** Enumerated as
asked, over all 83 `expect_out` calls plus the six negative `grep -c … == 0` controls, with an
emitting-line extractor that reads `echo` and `printf` anywhere in the line:

- **One live open member: case 20b** (finding 2), proven by mutation.
- **The terminator does not cover the class** (finding 1), proven by two planted patterns.
- `RELEASE INCOMPLETE` is shared between `:1082` and `:1144`; harmless in cases 4/6/8/9c/9k
  (empty literal, so `:1144` is unreachable) and pinned in 21b by a sibling `expect_eq`, but
  unflagged and so not *decided*.
- Everything else checks out, and two things are worth recording as done right. Every negative
  control's pattern is proven reachable by a sibling case — `Could not read` by 20L,
  `never published` by 20c, `=== 6: RETIRE ===` by 21a, `RETIRED BUT STILL SERVED` by 21c,
  `still produces it` by 22d, `not a STAC Item` by 22a2 — so none of the six is vacuous. And I
  walked each case's fixture against its name (20a–20L, 21a–21g, 22–22e): each reaches the arm it
  claims. 20f's `CCCC` is uppercase and the orphan listing prints lowercase ids, so that one is
  genuinely unique to the group arm.
- Knob hygiene checked across the whole run: `GONE`, `GARBLED`, `BUCKETONLY`, `LIVELIC`,
  `LIVE_AFTER`, `LIVE_FINAL` are each cleared by the case that sets them, and every `set_retired`
  is paired with `reset_tree`. The only cross-case state left is `$STAC/collection.json`, already
  reported in round 3 and accepted.

**E — a fifth mechanism: an invariant established by construction, with no read-back.** Not a
restatement of A: A is two artefacts with no joining *check*; E is an invariant whose entire
enforcement is the **order of two statements**, so any path that reorders or omits one of them
voids it silently and no probe can tell.

- **Open:** the bucket's `collection.json` must never link an object that is not in the bucket.
  Enforced on the normal path by `:807` before `:809` plus `set -e`; voided by `--skip-sync`
  (finding 4); never read back anywhere.
- **Recorded as implied:** `RETIRED_ITEMS ⊆ orphans` — true by construction, no mutation can make
  it fire. Already in findings.md as implied rather than covered, which is the right disposition.
- **A named sub-shape of D, from finding 1:** when a class is closed by a hand-written scanner,
  the class's boundary becomes the scanner's reach. `20-sorts` was wrong twice in one round
  (R3-3), `20-assertions` was wrong on its first outing. The instrument that ends a class is
  itself a member of it, which is why each of the three static cases needs a planted-member proof
  in the mutation table, and `20-assertions` has none.

---

## Verdict

**The loop must continue, because D has an open member and its terminator is proven not to cover
the class** — and because finding 4 is a new `[bug]` outside all four named mechanisms.

Concretely, round 5's work is bounded and enumerable:

1. `--skip-sync` + an item-adding release: refuse it, or read the bucket back per id.
2. Widen `20-assertions`' extractor to `echo|printf` anywhere, re-take the allowlist, and add its
   mutation-table row.
3. Tighten case 20b's assertion.
4. Hoist the `RETIRED_ITEMS` normalisation above `:141`/`:159`.
5. Add `item_unregister.sh` to the `20-sorts` / `20-pipes` populations.

Items 2–5 are mechanical. Item 1 is the one that changes behaviour, and it is the one that can
leave the collection serving zero items.
