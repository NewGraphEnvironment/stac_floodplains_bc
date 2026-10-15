# Code-check round 5 — review

Scope: the round-5 fixes in `07832ae` only, plus the mechanism-E enumeration. Branch clean at
`07832ae` throughout; every claim below was reproduced in a `cp -r` copy under the scratchpad,
never in the repo tree. Baseline: `bash scripts/catalogue_release-check.sh` = 213 ok, 0 FAIL,
exit 0.

**Verdict: the loop must continue.** Five of five rounds have now found a defect inside the
previous round's fix, and mechanism E is not closed — it has four open members, one of them on
the irreversible step.

---

## Findings

### 1. [HIGH] `catalogue_release.sh:1140-1142` — the in-band delete's collection scoping is an
unpinned mechanism-E member, and the harness cannot see it

```sh
COLLECTION="$COLLECTION" GEOSERV_HOST="$HOST" \
  bash scripts/item_unregister.sh $to_delete
```

`item_unregister.sh:22` defaults `COLLECTION` to `stac-floodplains-bc` — the production
collection — and `catalogue_release.sh` never **exports** `COLLECTION`, so the whole of
"the delete goes to the collection this release targets" is that one env assignment on that
one line. Nothing reads it back and nothing asserts it.

This script's own header documents running against a throwaway collection id. In that mode,
dropping (or mis-editing) that assignment makes the retirement delete from the **real**
collection while the release is pointed at the throwaway. Step 7 would then refuse — because
the throwaway still serves the id — but only *after* the production delete has landed, on a
bucket with versioning Suspended.

**Proved:** removing `COLLECTION="$COLLECTION" GEOSERV_HOST="$HOST"` from that invocation in a
copy leaves the suite **fully green** — 213 ok, exit 0 (`scratchpad/mA.out`). The harness
already captures the SQL (`SSHIN`), but `deleted_ids()` (`catalogue_release-check.sh:502`)
extracts only the first argument of `pgstac.delete_item(...)` and discards the collection, and
`check-collection` appears in no assertion anywhere in the file (grep-verified: only at `:106`,
`:116`, `:441`, `:1283`, all definitions/plumbing).

Cheapest close: assert the full call in case 21a, e.g.
`grep -c "delete_item('aaaa_co_ff04', 'check-collection')" "$SSHIN"` = 1, or widen
`deleted_ids()` to print `id|collection`.

### 2. [MEDIUM] `catalogue_release.sh:464-471` — the `--skip-sync` refusal is scoped to `added`,
which is R4-1's symptom, not the property (mechanism B, inside round 5's own fix)

The guard refuses `--skip-sync` when the build **adds** an item. It permits `--skip-sync` when
the build **changes** an existing item's JSON, and that is the same hazard:

- the only S3 write on that path is `aws s3 cp collection.json` (`:773`);
- step 4 registers the **local** item documents, so the API serves the new ones;
- on a full release nothing reads a bucket item document's bytes or identity. Grep-verified:
  every `S3_BASE` read in the file is `:414` (`--only` only), `:516`/`:523` (the retirement
  witness, reached only for a *not-live* retired id), `:903` (the new HEAD — existence only),
  `:1025` and `:1112` (both `collection.json`).

So bucket and API diverge silently, and `rtj`'s reload-from-S3 — which `CLAUDE.md` calls
"harmless, because the release syncs the JSON before registering it" — then reverts every
changed item. The asset probe and checksum probe cover **one** asset of **one** item
(`probe_item=$(head -1 <<<"$local_ids")`, `:889`), so they are a sample, not a read-back.

`--only --skip-sync` has the same hole and is not covered by this guard at all (it sits in the
full-release `else` branch): that path uploads *nothing*, and the `--only` preflight compares
only the bucket copy's provenance **key set** (`only_preflight.py`), so a properties-only change
publishes a new API document over an unchanged bucket document with every arm green.

Note the asymmetry the code already shows: under `--only` the script insists on reading the
bucket copy before publishing, "because the bucket copy is the document the release would
overwrite". The full release, which writes 23 documents, makes no such comparison.

The harness cannot reach this state: `FIXTURE_ROOT` and `STAC_DIR` are both `$STAC` in
`run_release` (`:440-442`), so the bucket and the build are the same bytes by construction. Any
case would need a third root, the way case 22a2 needed the `FIXTURE_ROOT`/`STAC_DIR` split.

### 3. [MEDIUM] `catalogue_release-check.sh:933-985` — `case 20-assertions` is blind for 40 of
its 76 patterns, so the class-D terminator still cannot fail for the majority of them

Round 4 widened the *line* extractor (155→236 visible emitting lines). The complementary
measurement was never taken: run the case's own python over its own inputs and

```
patterns 76 | emitter lines visible 236
zero-hit 40 | one-hit 32 | >1-hit 4
>1: ['RELEASE COMPLETE', 'RELEASE INCOMPLETE', 'full release', 'not a STAC Item with that id']
```

**40 of 76 patterns match no emitter line at all**, because the message is assembled from a
shell literal plus an interpolated variable (`"the bucket answers $code for $id.json"`,
`"$id still answers $code from the API"`, `"live collection version: $TVERSION"`) or from a
token built inside an embedded `python3 -c` (`built-has-no-citation`, `rel=license-href=`,
`STALE asset:classified_2017`). The case's only test is `len(hits) > 1`, so for those 40 it is
vacuous, and the 4-entry allowlist is exactly the `>1` set — i.e. the allowlist is complete with
respect to what the scanner can see, which is 36 of 76 patterns, not 76.

**Proved behaviourally**, not only statically. Appending to a scanned file in a copy:

```sh
if false; then
  echo "It is absent from the API and the bucket answers 404 for zzzz.json" >&2
  echo "  zzzz still answers 200 from the API" >&2
fi
```

makes case 20c's pattern and case 21f's pattern each reachable from a **second** emitter in
`catalogue_release.sh`, and the suite stays green — 213 ok, exit 0 (`scratchpad/mD.out`) —
because the scanner counts 1 hit (the plant) and cannot see the original.

This is round 5's own named sub-shape: *when a class is closed by a hand-written scanner, the
class's boundary becomes the scanner's reach.* Minimum honest fix: flag `len(hits) == 0` as well
(each pattern must have at least one visible emitter), which forces the interpolated ones to be
handled rather than silently skipped.

Two smaller gaps in the same case:

- **File scope was not widened with its siblings.** It scans `catalogue_release.sh` and
  `item_retract_s3.sh` (`:943`); `20-sorts` and `20-pipes` were widened to three files in this
  same commit because `item_unregister.sh` emits into the release's output. It does — its
  `unregistering N item(s)`, `not registered, nothing to delete`, `OK — verify 404` lines all
  land in `$OUT`. Zero live members today (checked: no current `expect_out` pattern appears in
  `item_unregister.sh`, `item_register.sh`, `collection_register.sh` or `only_preflight.py`;
  `collection_version.py` contains the already-allowlisted `full release`), so this is the same
  "no members closure is only as wide as the files read" gap R4-5 named.
- **The `RELEASE INCOMPLETE` allowlist reason is narrower than its scope.** It reads "the case
  asserting it also pins `n_delete` and the absence of the step-6 banner" — singular. Six cases
  assert that pattern (`:569, :597, :675, :834, :845, :1201`) and only `:1201` (21b) pins those
  two. The entry is still safe (step 7's spelling is unreachable with an empty literal, which is
  the state of the other five), but as written the reason describes one case and covers six.

### 4. [MEDIUM] `catalogue_release.sh:896-912` — the new read-back iterates the build's files,
not the collection's links, so its stated property is a proxy

The comment and the message both claim "every id the published **collection links**". The loop
is `for id in $local_ids`, and `local_ids` (`:352-354`) is `basename` over `$STAC_DIR/*.json`.
The two sets agree only because `item_create.py:734-739` writes the `rel: item` links and the
item files in one run — an invariant established by construction, with nothing reading it back
(`item_validate.py` checks the item **count** via `--expect`, and greps show it never compares
`collection.json`'s links against the items on disk).

So an id the collection links but whose JSON is absent from `$STAC_DIR` is invisible to this
guard — and that id is exactly what kills a reload-from-S3. It also makes the orphan/`added`
arms compare against a short set. Closing it is free and stdlib-only: read the ids out of
`$STAC_DIR/collection.json`'s `rel: item` hrefs, assert that set equals `local_ids`, and HEAD
*that* set. That turns the proxy into the property the message already claims.

### 5. [LOW-MEDIUM] `catalogue_release.sh:903-907` — every non-200 is reported as "no document",
which is the collapse the arm 390 lines above refuses to make

```sh
code=$(curl -sI ... || echo 000)
case "$code" in 200) ;; *) absent="$absent $id($code)" ;; esac
```

A 403, a 301, a transient 500 and an S3 `503 SlowDown` all print *"the bucket has no document
for item(s) this collection links"* and *"A reload-from-S3 would delete the collection's rows
and then fail on these"* — a false and alarming statement for a read that did not complete.
The direction is safe (it fails toward refusal, before step 6), but:

- this file states the opposite rule three times — `fetch_live_version`'s `MISSING` note, the
  licence read-back's `READFAIL` sentinel, and the retirement witness's own three-outcome
  `case`, whose comment says collapsing "no such Item" into "could not be read" is wrong
  because the two have different remedies;
- it is a **new** way for a full release to fail *after* the collection has been published and
  the items registered, on 23 HEADs against S3 with no retry. The harness already models an
  S3 `SlowDown` (`FAKE_BUCKET_GARBLED`), so the condition is one this repo treats as real.

The code is already in the message (`$id(503)`), so the fix is only to branch: `404|403` →
absent, anything else → "could not read, retry".

### 6. [LOW] `catalogue_release-check.sh:987-1009` — `case 20-pipes`'s regex misses 8 of 15
early-exit shapes, including the most likely one

`\|\s*(grep\s+-[a-zA-Z]*[qm]|head\s+-n?\s*1\b)` catches `| grep -q`, `| grep -m1`,
`| grep -qxF`, `| head -1`, `| head -n 1`. Measured misses: `| grep -E -q`, `| grep -i -q`,
`| grep -F -m 1`, `| grep --quiet`, `| grep --max-count=1`, `| head` (bare — 10 lines, still
early-exits), `| head -2`, `| sed 1q`, `| awk 'NR==1{print;exit}'`.

**Proved:** appending `if false; then printf a | grep -E -q b; printf a | head; fi` to
`item_unregister.sh` in a copy — a file this case now scans — leaves the suite green, 213 ok,
exit 0 (`scratchpad/mB.out`). Zero members today across every `scripts/*.sh`, so this is latent
reach, not a live bug — but it is a static terminator whose reach *is* the class boundary, and
`| grep -E -q` is what the next reader writes.

`case 20-sorts`'s `\bsort\b` + `LC_ALL=C ` prefix test has no equivalent gap (it over-reports
rather than under-reports: `LC_ALL=C  sort` with two spaces is flagged). Adding
`item_unregister.sh` changed neither allowlist — it contains no `sort` and no piped early-exit
consumer — and the third file did earn its place: `item_retract_s3.sh:88`'s `sort -u` was the
member it found.

### 7. [LOW] `catalogue_release-check.sh:1155` — case 20m's assertion does not check what its
description claims, which is the shape round 5 just fixed in 20b

```sh
expect_out "names the added id" "cannot publish a build that ADDS items"
```

The pattern is the **heading**; the id is printed on the next line by
`printf '  %s\n' $added >&2`. A regression that made `added` empty, or printed the wrong
variable, would keep the heading and pass. Round 5 fixed exactly this in case 20b by asserting
the heading *and* the id beneath it with `awk`. 20m (and 20n, at `:1167`) got the heading only.
One line each, modelled on 20b:

```sh
expect_eq "and it listed the added id under that heading" \
  "$(awk '/cannot publish a build that ADDS items/{f=1;next} f&&/bbbb_ch_ff04/{print "yes";exit}' "$OUT")" yes
```

### Checked and sound

- **The read-back's placement.** `fail=1` at `:909` is upstream of the `[ "$fail" -eq 0 ]` gate
  at `:1133` and therefore of step 6 — verified by reading, and case 21b pins the general
  property via `LIVELIC`. `|| echo 000` under `set -e`/`pipefail` is correct: the substitution
  cannot abort the loop, and `000` fails toward refusal. Cost on 23 items is 23 HEADs; it cannot
  run before the sync (the bucket legitimately lacks the added documents then), so "after the
  write" is the only correct placement.
- **`added` is computed correctly and early enough.** `comm -13 live local` = in build, not
  live; both sides collation-aligned (`fetch_live_ids` sorts in Python codepoint order,
  `local_ids` is `LC_ALL=C sort`); the refusal is the first arm after `live_ids`, upstream of the
  orphan block, the version gate, the validator and every byte written. No other path writes
  `collection.json`: the full path syncs items with `--exclude 'collection.json'` then `cp`s it
  last (and `--exclude 'collection.json'` is the last matching filter rule, so it wins), the
  `--only` path `cp`s one item document, and the `--skip-sync` `cp` is now guarded.
- **Case 20w discriminates.** `set_retired "   "` → `printf '%s\n' $RETIRED_ITEMS` word-splits
  to nothing → `retired_ids=""`, `n_retired=0`; restoring `[ -n "$RETIRED_ITEMS" ]` would exit 1
  with the "do not combine" message and both assertions fail. The hoisted normalisation runs
  before both flag refusals and before the shape guard, which is the right order.
- **Case 20b's fix is correct.** The `awk` sets its flag on the containment heading and matches
  the id only after it; the generic orphan listing is printed *before* that heading, so it cannot
  satisfy it.
- **Case 20n's knob is precisely aimed.** `FAKE_BUCKET_MISSING` 404s only a `-w` HEAD of
  `<id>.json`; the asset probe uses `-I` without `-w` and the body branch is untouched, so the
  only arm it can redden is the new read-back.
- **Missing `reset_tree` after 20m/20n is harmless** — neither calls `set_retired`/`set_news`,
  the tree was reset at the end of 20k, and 21a's `set_retired` is a real change so its
  `commit && tag -f` cannot short-circuit (a no-op `set_retired` would abort the harness under
  `set -e`; not reachable in the current ordering).

---

## Mechanism E

**Not closed.** Walking both scripts for every invariant whose entire enforcement is the order
or presence of statements:

| # | invariant | state |
|---|---|---|
| E1 | the published `collection.json` never links an object absent from the bucket | **partially closed** — read back per id at `:896-912`, but over `local_ids` (a proxy for the links, finding 4) and by existence only (finding 5) |
| E2 | `RETIRED_ITEMS ⊆ orphans` | implied by construction (accepted) |
| E3 | the version stamp precedes validation | closed — read back at `:737-739`, asserted by case 2 |
| E4 | `collection.json` is the last JSON object the bucket receives | closed — asserted by line number (`line_coll_cp > line_json_sweep`, case 2) |
| E5 | step 6 runs only after `fail` has been evaluated for everything else | closed — case 21b, M8 |
| E6 | **the in-band delete is scoped to `$COLLECTION`** | **OPEN** — one env assignment, no read-back, no assertion; mutation stays green (finding 1) |
| E7 | **the bucket's item documents are the documents just registered** | **OPEN** — enforced by step 3 running at all; `--skip-sync` omits it and only the `added` half is refused (finding 2) |
| E8 | **every asset href a published item carries resolves in the bucket** | **OPEN** — enforced by step 2 preceding step 3 plus `set -e`; read back for one asset of one item only (`probe_item`, `:889`). The order of the two syncs is not even asserted by the harness, unlike E4's pair |
| E9 | **`local_ids` equals `collection.json`'s `rel: item` link set** | **OPEN** — established by `item_create.py` writing both in one run; nothing reads it back, and it is the premise E1's own message asserts (finding 4) |
| E10 | exactly one `EXIT` trap in the script | open, trivial — a second `trap … EXIT` silently replaces `rm -f "$only_bucket"`; cost is a leaked temp file. Noted for completeness, not worth a guard |

Method: read both scripts end to end and classified every consequential statement whose
correctness depends on what runs before/beside it rather than on a test of the result; then
mutated the two cheapest (E6, and `20-pipes`/`20-assertions`' reach) in `cp -r` copies and
re-ran the full suite to see whether anything noticed. E6, E7, E8 and E9 are the open members.

---

## Verdict

**The loop must continue.** Findings 1-4 are each a defect inside a round-5 fix or inside the
instrument a round-5 fix relies on, mechanism E has four open members, and the class-D
terminator is demonstrably unable to fail for 40 of its 76 inputs. Three of the four open E
members (E7, E8, E9) share one root — the full-release path reads the bucket's collection
document and nothing else — so the enumeration to run before declaring E closed is "every
bucket object this release's documents reference, against what the release actually read back".
