# Code review — round 3 — `76-retire-the-per-species-floodplain-items`

Reviewer: code-review subagent, 2026-10-14. Scope: the branch diff against `main`, with the
round-2 fixes as the primary target.

Verification performed here: `bash scripts/catalogue_release-check.sh` → **ALL PASS**;
`scripts/catalogue_release.sh`, `scripts/item_retract_s3.sh`, `scripts/item_unregister.sh`,
`scripts/item_register.sh` and the new harness cases read in full. Four measurements, each run
in `$SCRATCH/r3/` against copies and shims, never against the repo's working tree or anything
real:

1. `item_retract_s3.sh --yes collection` driven against fake `curl`/`aws` — **reproduced an
   `aws s3 rm` of the bucket's `collection.json`**.
2. the bucket witness's `curl | python3` pipeline over five simulated responses.
3. case `20-sorts`'s grep against three mutants appended to a copy of the release script.
4. `pipefail` + early-exiting `grep -q`: the SIGPIPE threshold on this machine, and the real
   `NEWS.md` top section against it.

Nothing from rounds 1 or 2 is re-reported.

## Findings

### 1. [bug] `scripts/item_retract_s3.sh:67` — the id guard is charset-only, so `--yes collection` deletes the bucket's published `collection.json`

This is the reachable member of round 2's E3 class (`guard proving existence/charset where
identity is wanted`) that the enumeration did not walk. E3 closed its two members inside
`catalogue_release.sh` — the bucket witness and the NEWS arm — and left the same guard
unchanged on **the script with no undo**:

```sh
    *[!A-Za-z0-9_-]*) echo "ERROR: suspicious item id: $1" >&2; exit 1 ;;
```

`collection` passes it, and then every one of the three refusals misses:

* **guard 1 (API):** `$API/items/collection` 404s — there is no item with that id.
* **guard 2 (`linked`):** `linked` holds `rel: item` basenames minus `.json`, i.e. item ids, so
  `collection` is never in it.
* **guard 3 (build):** `[ -f "$STAC_DIR/$id.json" ]` is `$STAC_DIR/collection.json`, which
  **does** exist beside a build — so on the ordinary machine this is caught, but *by accident*:
  it fires because `collection.json` happens to be the collection document, not because
  `collection` names a produced item. The script's own header contemplates a machine with no
  `data/stac` ("A release-only machine holds no data/stac, which is not an error"), and
  `STAC_DIR` is overridable, and `run_pipeline.sh` wipes `data/stac`. In any of those states
  guard 3 is skipped.

Reproduced (`$SCRATCH/r3`, fake `curl` serving a real `type: Collection` with no `rel: item`
links, fake `aws` logging argv, `STAC_DIR` pointed at a nonexistent directory):

```
deleting from s3://stac-floodplains-bc (region us-west-2) — permanent, versioning is Suspended:
  collection/        no objects under this prefix (already removed, or never had any)
  collection.json    absent bytes
retracted: collection
OK — 1 item(s) retracted from s3://stac-floodplains-bc.
rc=0
=== aws calls ===
AWS-CALL: s3 rm s3://stac-floodplains-bc/collection/ --recursive --region us-west-2
AWS-CALL: s3 rm s3://stac-floodplains-bc/collection.json --region us-west-2
```

Why it matters rather than being a typo nobody would make: the blast radius is the one object
every other guard in this branch is built around. With `collection.json` gone from the bucket,
rtj's reload-from-S3 cannot read the document it drives from at all, and
`catalogue_release.sh` step 5's bucket read-back (`:933`) fails on the next release — i.e. the
same class of outage as `stac-dem-bc`'s, arrived at from the other end. Versioning is
Suspended; recovery is a full re-release. And the likely entry is exactly the shape this
branch's own prose anticipates for `RETIRED_ITEMS`: a pasted list of ids with one stray token
in it, run on a machine where the build is not present.

Cheap fix, and symmetric with the witness the release now uses: before deleting, require the
bucket key to be a STAC Item whose `id` equals the argument — that is precisely the document
this script's existence is predicated on still being there (it is the rollback for step 6).
A narrower alternative is to refuse `collection` by name, but that guards the symptom again.

### 2. [fragile] `scripts/catalogue_release.sh:527-532` — the new bucket witness cannot tell "the bucket holds no such Item" from "the bucket could not be read", and `2>/dev/null` hides which

The round-2 fix replaced a HEAD with a body-identity check, which closes the identity class.
It also turned a 200/not-200 question into a *parse* question, and every non-success now
collapses into one branch:

```sh
    if curl -sf --max-time 60 "$S3_BASE/$id.json" 2>/dev/null \
         | python3 -c "... except Exception: raise SystemExit(1) ..." "$id"; then
```

Measured (`$SCRATCH/r3/witness.sh`, the real pipeline with `curl` replaced by a function
returning each state):

| simulated response | verdict |
|---|---|
| `type: Feature`, matching id | already_retired — release proceeds |
| `type: Collection` | "was never published", release refused, **literal blamed** |
| curl exit 7 (could not connect) | "was never published", release refused, **literal blamed** |
| curl exit 18 (partial transfer, truncated JSON) | same |
| S3 `<Error><Code>SlowDown</Code></Error>` body, HTTP 200 | same |

The refusal text is `RETIRED_ITEMS names an item that was never published: <id> … Check the
literal against what the collection serves.`

Three things make this worth a fix rather than a shrug:

* **This file states the opposite rule twice, forty lines apart.** `:205-207`: *"MISSING is a
  real state … and a failed read must not look like it: curl -f and a parse that raises on a
  non-JSON body both fail the pipeline, and every caller tests the exit status before using
  the value."* And `:214-215`: *"A failed fetch or an unparseable body raises here … so 'served
  wrong' and 'could not read' stay distinguishable."* The new witness is the one reader in the
  script that merges them. (Shape A: prose rule vs the code beside it.)
* **`2>/dev/null` discards the only evidence.** That is round 1's F2 symptom — a silent
  failure behind a suppressed stderr — re-arriving on a different arm.
* **The prescribed remedy is destructive of the release.** This arm exists *only* to keep the
  re-run after a verify failure possible, i.e. it is reached when the operator is already
  mid-retirement. Editing the literal costs a new commit, a new `NEWS.md` entry and a new tag
  (clean-tree + exact-tag gates) — and if they clear the literal instead, the release completes
  with steps 6 and 7 never running, so the retirement is never verified at all. A transient
  S3 read should not be able to send an operator down that path.

Fix is two lines and keeps the identity check: capture the body first, branch on curl's own
status, then parse.

```sh
    body=$(curl -sf --max-time 60 "$S3_BASE/$id.json") || {
      echo "Could not read the bucket copy of $id — refusing to decide blind." >&2; exit 1; }
    if printf '%s' "$body" | python3 -c '…'; then …
```

Fails closed either way; the difference is which sentence the operator reads.

### 3. [fragile] `scripts/catalogue_release-check.sh:864-869` — case `20-sorts` asserts a narrower property than its comment claims, and one of its two filters is a vacuous-pass vector

The case is the static closure round 2 put in place of a behavioural test. Its comment states
the property as *"Every pipe into `sort` in the release script must be collation-pinned, except
the one that orders filenames for xargs"*, and the finding it was written for was stated more
broadly still ("E1, every `sort` whose output is compared").

```sh
unpinned=$(grep -n '| *sort' "$REPO/scripts/catalogue_release.sh" \
  | grep -v 'LC_ALL=C sort' \
  | grep -v 'xargs bash scripts/item_register.sh' || true)
```

Measured, by appending one line to a copy of the release script and re-running the case's own
pipeline (`$SCRATCH/r3`):

| mutant appended | case verdict |
|---|---|
| `x=$(printf "%s\n" "$a" \| sort -u)` | caught |
| `y=$(sort -u <<<"$a")` | **MISSED** |
| `z=$(… \| LC_ALL=C sort; … \| sort)` | **MISSED** |

Two separate holes, and they are independent:

* **The finder requires a literal `\|` immediately before `sort`.** `sort -u file`,
  `sort <<<"$x"`, `$(sort f)` and a pipeline whose `sort` sits on a continuation line all
  escape it. (Verified the current file is clean: `grep -n 'sort'` over
  `scripts/catalogue_release.sh` gives 11 hits — 3 Python `sorted()`, 4 comments, 3 pinned
  `LC_ALL=C sort`, and the one `| sort | xargs` — so the property holds *today*. The guard just
  would not notice if it stopped holding this way.)
* **`grep -v 'LC_ALL=C sort'` excludes a whole LINE, not a match.** A line carrying both a
  pinned and an unpinned `sort` is dropped entirely, hiding the unpinned one. Note this filter
  is also *currently dead* — because `| *sort` cannot match `| LC_ALL=C sort` in the first
  place, so the pinned sites are never in the finder's output. It contributes nothing except
  the hole.

So the construct round 2 added to close Shape A/B is itself Shape B: scoped to the symptom
(the exact text `| sort`) rather than to the property (every `sort` whose output is compared).
A pattern that enumerates `sort` occurrences and then requires each to be pinned, rather than
one that enumerates the unpinned spelling, closes both: e.g. count `grep -c '\bsort\b'`
matches outside comments and require each to be `LC_ALL=C`-prefixed or the xargs site.

Also out of scope rather than wrong: the case scans only `catalogue_release.sh`, so
`item_retract_s3.sh:88`'s bare `| sort -u` is invisible to it. That one is genuinely harmless
(it feeds `grep -qxF`, where order is irrelevant), which round 2 recorded — but the guard
cannot say so.

### 4. [fragile] `scripts/catalogue_release.sh:652` and `scripts/item_retract_s3.sh:100` — `| grep -q` under `set -o pipefail` reads the writer's SIGPIPE as the test's answer, and this file already documents that trap

`grep -q` exits on its first match, which can SIGPIPE a writer that has not finished. Under
`pipefail` that status becomes the pipeline's, so **a match can report non-zero**. Measured on
this machine:

```
pipe absorbs 64000 bytes -> grep -qxF pipeline status 0
            70000 bytes -> grep -qxF pipeline status 1 (writer got BrokenPipe)
printf builtin, 200000 bytes, match on line 1 -> pipeline status 141
```

Three sites, two of them added on this branch, and the file's own comment at `:606` names the
mechanism: *"Captured whole rather than piped into `grep -m1`: an early-exiting grep can
SIGPIPE git show under pipefail and turn a valid file into a false refusal."* That fix moved
the writer from `git show` to `printf` and left the exposure in place.

| site | writer's payload today | direction if it fires |
|---|---|---|
| `catalogue_release.sh:614` `printf "$news"` → `grep -m1 -E '^## '` (pre-existing) | **39,573 B** (whole `NEWS.md`), first `## ` at line 20 | false refusal: *"NEWS.md in `<tag>` has no '## ' heading"* — blames the wrong thing on every release |
| `catalogue_release.sh:652` `printf "$news_entry"` → `grep -qE` (**new**, round 2's E3 fix) | **29,165 B** (top section) | false refusal: a retired id that IS named reads as unnamed → *"NEWS.md … does not mention"* |
| `item_retract_s3.sh:100` `printf "$linked"` → `grep -qxF` (**new**) | ~350 B (23 ids) | **fails toward PASS**: the "bucket collection.json still links it" refusal does not fire, and the delete proceeds — the exact rtj reload hazard the script exists to prevent, on the irreversible half |
| `catalogue_release.sh:343` `printf "$live_ids"` → `! … grep -qxF "$ONLY"` (pre-existing) | ~350 B | false refusal (fails closed) |
| `catalogue_release.sh:819` `printf "$local_ids"` → `head -1` (pre-existing) | ~350 B | assignment returns 141 → `set -e` exits the release |

**None of these is reachable today** — say that plainly. But the margin on the two NEWS sites
is 1.6x and 2.2x against a 64 KiB buffer, not orders of magnitude, and `NEWS.md` grows on
every release (this branch alone added ~5 KB to the top section). The `item_retract_s3.sh`
one has ~180x headroom and would need a four-figure item count; it is listed because its
*direction* is fail-toward-pass on the script with no undo, which is the one place that
direction is unacceptable regardless of margin.

Fix is the one `:606` already chose, applied to the consumer rather than the producer: use a
here-string (`grep -qE "$pat" <<<"$news_entry"`) or a `case`/`[[ =~ ]]` test, so no pipe is
involved and `pipefail` has nothing to report.

## Enumerations

### Class A1 — prose vs code (claimed members: the README recipe, the containment arm's remedy, the group arm's remedy)

**Incomplete.** Three further members, all in the round-1/round-2 fixes:

* `fetch_live_version`'s stated rule (`:205-207`, `:214-215`, *"a failed read must not look
  like it"*, *"'served wrong' and 'could not read' stay distinguishable"*) versus the new
  bucket witness at `:527-532` — **finding 2**.
* the SIGPIPE rule stated at `:606` versus `:614`, `:652` and `item_retract_s3.sh:100` —
  **finding 4**.
* case `20-sorts`'s own comment (*"Every pipe into `sort` … must be collation-pinned"*) versus
  the pattern beside it — **finding 3**.

Still open from round 2's "walked and deliberately not reported", and now one further out:
`NEWS.md`'s *"Six arms refuse in step 0"* enumerates six; the code has the six plus the shape
guard plus the bucket-identity witness. Not re-reported as a finding, but it is a quantifier
in a public release note that moved twice during this branch.

How I checked the class rather than hunting instances: I read every block comment in
`catalogue_release.sh` and `item_retract_s3.sh` that asserts a *behaviour* (as opposed to a
rationale), listed the assertion, and tested it against the code in its own scope. The ones
that hold: `:311-319`'s *"Every other id or group list compared in this script is pinned the
same way — `retired_ids` below and `build_wsgs` in the group arm"* (complete — those are the
only three shell-sorted lists in the file, and the four Python-sorted ones are codepoint
order); `:1030-1035`'s claim about the delete's placement (verified: every one of the 18
`fail=1` sites is at or above `:1026`, and the gate is `:1036`); `:1050-1052`'s claim that
`COLLECTION`/`GEOSERV_HOST` are not exported (verified at `:37`/`:42`); the group arm's claim
that `$orphans` cannot be empty while a group is missing (verified: `orphans = live − build`
empty ⟹ `live ⊆ build` ⟹ `live_wsgs ⊆ build_wsgs`, so the arm's gating on `$orphans` loses
no coverage, including on a re-run).

### Class A2 — the harness stage counter vs the script's call sequence

**Complete, checked by enumerating the emitters and hand-tracing the shim.**
`grep -n '$API_ROOT/search'` over `scripts/catalogue_release.sh` gives exactly three emitters
(`fetch_live_ids:177`, `fetch_live_wsgs:190`, the deprecation read-back `:987`) and five call
sites (`:333`, `:532`, `:788`, `:987`, `:1068`). Traced against the shim's
`_n`/`_stage` logic:

| # | site | shape | `_n` | `_stage` | set served |
|---|---|---|---|---|---|
| 1 | `:333` preflight | id-only | 0 | 0 | `FAKE_LIVE_IDS` |
| 2 | `:532` group arm | `properties.wsg` | 1 | 0 | `FAKE_LIVE_IDS` |
| 3 | `:788` step-5 compare | id-only | 1 | 1 | `FAKE_LIVE_IDS_AFTER` |
| 4 | `:987` deprecation | `properties.deprecated` | 2 | 1 | `FAKE_LIVE_IDS_AFTER` |
| 5 | `:1068` step-7 re-read | id-only | 2 | 2 | `FAKE_LIVE_IDS_FINAL` |

Matches the comment, and matches round 2's trace. Also checked the `-d` capture it depends on:
the shim's `case` arms are ordered `http*` / `-w` / `-d` / `-*I*` / `*`, and none of the real
argv (`-sf`, `--max-time`, `120`, `-X`, `POST`, `-H`, `Content-Type: application/json`, `-d`,
the JSON body) is mis-claimed by the `-*I*` arm sitting ahead of `*`. Cases 21a / 21c / 21f
distinguish all three stages behaviourally, so the counter is pinned as well as correct.

### Class A3 — Python `sorted()` vs shell `sort`

**Complete in `catalogue_release.sh`, checked by classifying every `sort` hit in the file**
(`grep -n 'sort'` → 11 hits: 3 Python `sorted()` at `:180`/`:201`/`:887`+`:891`+`:1003`,
4 comments, 3 `LC_ALL=C sort` at `:322`/`:423`/`:540`, 1 `| sort | xargs` at `:779` where
nothing compares the result). Every `comm` pair now has both sides on one ordering, and the
two plain string compares (`:798` and `:1086`) are Python-vs-`LC_ALL=C`, which agree because
UTF-8 byte order is codepoint order.

The *guard* that closes the class is not complete — finding 3 — and
`item_retract_s3.sh:88`'s bare `| sort -u` is outside its scope (harmless in fact: it feeds
`grep -qxF`). `catalogue_release-check.sh`'s own `deleted_ids()` uses a bare `sort -u`
compared against a literal, which is fine for the fixture's ASCII ids.

### Class B — a guard scoped to the symptom rather than the property

**Incomplete: three members, not two.** Round 2 found the bucket witness and the NEWS
`grep -qF`. The third is `item_retract_s3.sh`'s id guard — **finding 1** — which is the same
charset-only guard that `RETIRED_ITEMS` had before F4, left in place on the script with no
undo. I walked every id entry point on the branch to get that list: `$ONLY` (`:127-129`,
charset + the live-item preflight, which refuses `collection` because the API 404s it);
`RETIRED_ITEMS` (charset + the identity witness — closed); `item_unregister.sh:32` (charset
only, but the consequence is a scoped `pgstac.delete_item` that deletes nothing — harmless);
`item_retract_s3.sh:67` (charset only, consequence is `aws s3 rm` — the finding).

## A third mechanism

**An early-exiting pipeline consumer under `set -o pipefail`: the pipeline's status is the
writer's SIGPIPE, not the test's answer.** Finding 4, with its five-member list above. It
belongs beside shapes A and B because it has the same signature as both: the file states the
rule in prose at `:606` and the code twenty and forty lines later does not follow it (A), and
the construct asks "did the pipeline succeed" where the property wanted is "did the pattern
match" (B). The reason it is worth naming separately is that its members are invisible to
every instrument used so far — the harness cannot reach them (the fixture's payloads are
hundreds of bytes), a mutation table cannot reach them (there is no guard to disable), and
`bash -n` and the suite are both green. The only way to find them is to enumerate the
early-exiting consumers, which is a one-line grep: `grep -n 'grep -q\|grep -m\|head -1'`.

## Walked and deliberately not reported

Recorded so a round 4, if there is one, does not re-derive these.

* **The sync split's filter semantics.** `--exclude '*' --include '*.json' --exclude '*/*'
  --exclude 'collection.json'` — AWS CLI evaluates filters in order with last-match-wins and
  joins each pattern onto the source root, so `collection.json` ends excluded and every
  `<id>.json` included. Same semantics the pre-existing `--exclude '*/*'` already relied on.
  Case 2 pins the argv and the ordering by shim-log line number, which is the right
  instrument for what a shim can see.
* **The step-7 404 loop and `item_retract_s3.sh`'s API probe** are the other two members of
  finding 2's "cannot tell no from could-not-ask" class. Both read `%{http_code}` with
  `|| true`, so a network failure yields `000`, which is neither 404 nor 410 → refusal, and
  **the message names the code**, so the state is distinguishable. Correct as written; the
  witness is the only weak member.
* **`build_wsgs=$(for … done | LC_ALL=C sort -u) || { … }`.** Round 1 measured this as
  non-defective; re-derived rather than taken on trust. The left segment of the pipeline is a
  subshell with `set -e` inherited, so a `python3` failure on *any* file (not only the last)
  aborts it, `pipefail` propagates, and the `||` fires. The `[ "$b" = collection ] && continue`
  inside it is `set -e`-exempt as the command before an `&&`.
* **`[ "$refusals" -eq 0 ]` in `item_retract_s3.sh` is all-or-nothing**, so one bad id in a
  batch blocks every delete. Correct for a no-undo script.
* **An empty-string argument to `item_retract_s3.sh`** (`--yes ""`) increments `n` but
  contributes no word to `$ITEMS`, so the final line reports `1 item(s) retracted` having
  deleted nothing. Cosmetic; no delete, no refusal bypassed.
* **`already_retired` ids are excluded from `to_delete` but still covered by step 7's 404 loop
  and the equality arm.** Verified by reading `:1057` (`to_delete = retired ∩ live`) against
  `:1091` (`for id in $retired_ids`). Case 20d exercises it.
* **Every id in `to_delete` is provably an orphan.** `retired ∩ build` is refused
  (`also_built`), `retired − live` goes through the witness, so `retired ∩ live` is live and
  not in the build. The literal's bound is therefore the orphan set, as the comment claims.
* **The harness's new `aws s3 ls --summarize` shim has a dead success branch.** Case 22e is
  the only case that reaches the summary, and it reaches the *empty* prefix (which is the point
  — it exercises round 1's F2 guard). The `awk '/Total Objects:/ {o=$3}'` parse is therefore
  never run against a non-zero count. Read by hand against the real output format and it is
  right (`$1 $2` are `Total Objects:`, `$3` the count), so this is a coverage note, not a
  defect. Reachable if wanted: an id with a staged asset directory but no `<id>.json` passes
  guard 3.
* **Cases 22c and 22e mutate `$STAC/collection.json` and never restore it** — 22c appends a
  `rel: item` link, 22e strips *all* `rel: item` links. Case 9j, by contrast, backs the file up
  and restores it. Only case 5 runs after the 20-22 block, it is an `--only` run, and nothing
  on that path reads the collection's `rel: item` links, so the suite is correct today. It is
  the same shape as the `PARTIAL_STAGE` leak the round-2 red run caught (shared fixture state
  cleaned by convention, not by construction), and it will bite whoever adds a case after 22 or
  moves case 5. Not reported as a finding because nothing is currently wrong.
* **`set_retired` / `set_news` / `reset_tree` discipline is complete.** Walked all 17 new
  cases: every case that calls `set_retired` or `set_news` ends with `reset_tree`, and every
  case that sets `LIVE_AFTER` / `LIVE_FINAL` / `GONE` / `BUCKETONLY` / `LIVELIC` clears it.
  Case 5 inherits `LIVE="aaaa_ch_ff04 bbbb_ch_ff04"`, the original value.
* **`set_retired`'s `re.subn(..., count=1)` + `assert n == 1`** is correct against the single
  `^RETIRED_ITEMS=` line, and case 20's anchored `grep -c '^RETIRED_ITEMS=""$'` reads `$REPO`
  (the real script) rather than `$TREPO`, so it asserts what ships.
* **`n_delete()` reads `$SSHIN`, which also receives `item_register.sh`'s payloads.** The grep
  is for `pgstac.delete_item(`, which only the unregister SQL carries. `|| n=0` on the
  assignment handles both the no-match (exit 1, prints 0) and absent-file (exit 2, prints
  nothing) cases, as its comment says.
* **`item_unregister.sh`'s new call site.** `$HOST` is defined at `:42`; both variables are
  passed explicitly; `$to_delete` is deliberately unquoted and every word is charset-guarded
  upstream.
* **The `n_retired`-conditional remedy messages** (containment arm `:518-522`, group arm
  `:548-553`) are consistent: `n_retired > 0` implies `ALLOW_RETRACT` is empty (mutual
  refusal at `:159`), and both branches of each arm are reachable.
* **Step 7's now-unconditional equality arm** is correct: the block is gated on
  `n_retired > 0`, the flag cannot coexist with that, and both sides of the compare are on one
  ordering.

## Verdict

One bug (finding 1 — a reachable, no-rollback delete of the bucket's `collection.json`, and
the member round 2's E3 class missed), and three fragilities, of which finding 2 is the one
worth fixing before the cutover because it prints the wrong remedy to an operator who is
already mid-retirement.

**This does not yet converge.** Two of the four findings sit inside round 2's own fixes
(the bucket witness, and case `20-sorts`), and finding 1 is a missed member of a class round 2
enumerated — the same pattern round 2 reported about round 1. What would end the loop is not
a quiet round but the three enumerations above being complete: A2 and A3 now are, and are
recorded with their method. A1 and B are not, and the new mechanism (finding 4) has a
one-command enumeration that nobody had run.
