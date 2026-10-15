# Code review — round 1 — `76-retire-the-per-species-floodplain-items`

Reviewer: code-review subagent, 2026-10-14. Scope: the branch diff against `main`
(`scripts/catalogue_release.sh`, `scripts/item_retract_s3.sh`,
`scripts/catalogue_release-check.sh`, `scripts/README.md`, `CLAUDE.md`, `NEWS.md`, and the
four default-moving script edits).

Verification performed here: `bash scripts/catalogue_release-check.sh` → **ALL PASS**;
`bash -n` on all four edited/new shell scripts → clean (no `shellcheck` on this machine);
two targeted mutation runs of the harness against a patched copy of the release script in
the scratchpad; and three small shell/curl semantics measurements, noted inline.

## Findings

### 1. [bug] `scripts/README.md:165,171` — the documented Replacement recipe passes `--allow-retract`, which switches off the two guards this branch exists to add

The **Replacement** recipe (the cutover this whole branch is for) says:

```
# 4. tag, then release: it validates, syncs, registers, verifies, THEN unregisters the
#    retired ids and re-verifies that the collection serves exactly this build
bash scripts/catalogue_release.sh --allow-retract
```

and then asserts at `:171` that "`--allow-retract` is still passed at step 4 … neither alone
retracts anything."

Both claims are wrong against the code on this branch:

* **The literal alone does retract.** `catalogue_release.sh:443` only refuses on
  `unaccounted = orphans − RETIRED_ITEMS`; when the literal names every orphan that set is
  empty and no flag is needed. Harness case 21a is the proof — it runs `run_release` with
  **no** flag, and the delete fires (`n_delete == 1`).
* **`--allow-retract` disables the group arm.** `:464` is `if [ -z "$ALLOW_RETRACT" ]`, so the
  "no live watershed group is lost" arm is skipped. That is the arm whose own comment
  (`:457-463`) calls it "the ONLY arm that survives `ALLOW_SKIPPED=1`" — i.e. the only thing
  standing between a 10-of-23 build and a collection that silently drops 13 groups onto a
  bucket with versioning Suspended.
* **`--allow-retract` disables step 7's equality arm.** `:999` is
  `if [ -z "$ALLOW_RETRACT" ] && [ "$final_ids" != "$local_ids" ]`. Equality is the stated
  purpose of step 7 — `scripts/README.md:72` and `CLAUDE.md` both say it is what stops a
  group serving both its whole-network item and the species one it replaced. Following the
  recipe, nothing checks it.
* **It also disables step 5's containment arm** (`:733`, same `[ -z "$ALLOW_RETRACT" ]`), so
  the post-register membership comparison is off too.

Net effect of following the recipe as written: the cutover release deletes 17 public item ids
with the group arm, the step-5 membership arm and the step-7 equality arm all inert. The only
surviving retirement checks are `still` (`:990`) and the per-id 404 loop (`:1004`).

The same sentence is in `CLAUDE.md` ("The literal says which, the flag says a smaller
collection is intended, and neither alone retracts anything"), two lines after it correctly
says the release "unregisters exactly those in step 6". Worth fixing in both: drop
`--allow-retract` from the Replacement recipe (step 4 becomes a bare
`bash scripts/catalogue_release.sh`), and consider having the script **refuse** the
`--allow-retract` + non-empty-`RETIRED_ITEMS` combination outright, the way it already
refuses `--only` + non-empty literal at `:141`. Harness case 21f deliberately uses the
combination to isolate the still-served arm, so a refusal would need that case re-shaped.

### 2. [bug] `scripts/item_retract_s3.sh:113` — the pre-delete summary aborts the script silently when an item's `<id>/` prefix is already empty

```sh
summary=$(aws s3 ls "s3://$BUCKET/$id/" --recursive --region "$REGION" --summarize 2>/dev/null \
  | awk '/Total Objects:/ {o=$3} /Total Size:/ {s=$3} END {printf "%s object(s), %s bytes", o+0, s+0}')
```

`aws s3 ls` exits **1** when a prefix matches no objects (long-standing AWS CLI behaviour; not
re-measured here). The script runs under `set -euo pipefail`, so the failing left-hand side of
the pipe fails the whole pipeline, the assignment inherits that status, and the script exits —
with stderr already discarded by `2>/dev/null`, so nothing is printed.

Measured (scratchpad):

```sh
set -euo pipefail
fakeaws() { return 1; }
echo before
summary=$(fakeaws 2>/dev/null | awk 'END {printf "%s object(s)", 0}')
echo "after: $summary"
# → prints "before", then exits rc=1. "after" never runs.
```

Consequences:

* The abort happens **after** `echo "deleting from s3://$BUCKET … — permanent"` has printed, so
  the operator sees the destructive banner and then an unexplained exit 1.
* `aws s3 rm "s3://$BUCKET/$id.json"` (the second half of the retraction) never runs, so the
  root item document is orphaned in the bucket permanently. That document is exactly what
  `catalogue_release.sh:423`'s already-retired arm keys on, so a later release keeps reporting
  the id as "already retired by an earlier run".
* This is the re-run case the comment at `:127-129` explicitly anticipates ("the release may
  have been run twice, or an earlier attempt may have got this far"), and the state is also
  reachable for an item whose assets were never uploaded.

The harness cannot see it: the `aws` shim (`catalogue_release-check.sh:177-180`) is
`. _log aws "$@"` and always exits 0, so case 22e's positive control exercises the success
path only. Suggested fix: `summary=$( … ) || summary="0 object(s), 0 bytes"`, or drop
`2>/dev/null` so the failure is at least visible.

### 3. [fragile] `scripts/catalogue_release-check.sh:215-226` — the search-stage knobs do not land on the calls the comment names, and case 21a (the positive control) passes with step 5's containment arm broken

The shim comment says "Three stages, because a retirement release searches three times: the
preflight, the post-register membership compare, and the post-delete re-read."

Measured, by keeping `$WORK` and dumping case 21a's shim log: a retirement release makes
**five** `*/search` calls, because `fetch_live_wsgs()` (`catalogue_release.sh:465`) and the
deprecation read-back (`:906`) are also `POST /search`:

| call | `_n` | set served | release call site |
|---|---|---|---|
| 1 | 0 | `FAKE_LIVE_IDS` | `:303` preflight `fetch_live_ids` |
| 2 | 1 | `FAKE_LIVE_IDS_AFTER` | `:465` `fetch_live_wsgs` (group arm) |
| 3 | 2 | `FAKE_LIVE_IDS_FINAL` | `:707` `after_ids` — the post-register compare |
| 4 | 3 | `FAKE_LIVE_IDS_FINAL` | `:906` deprecation read-back |
| 5 | 4 | `FAKE_LIVE_IDS_FINAL` | `:987` step 7 re-read |

So in case 21a the post-register compare is handed the **post-delete** set: `after_ids`
already equals the build, `extra` is empty, and the containment arm at `:732-737` is never
entered. The case is modelling a catalogue that lost the item before step 6 deleted it.

Verified by mutation: with `:732` replaced by `surplus="$extra"` (equality instead of
containment) in a copy of the script, the **full suite reports exactly one failure** — case
21c's `expect_out "names what is still served"` — and case 21a, "the positive control", stays
green on all five of its assertions. That mutation is a release that can never retire anything
in production (every retirement would die at step 5 with "LIVE BUT NOT IN THIS BUILD, AND NOT
RETIRED BY IT"), and the positive control does not notice; only 21c notices, and it notices by
a *different* assertion failing than the one aimed at it.

The step-5 containment arm also appears nowhere in `findings.md`'s mutation table (M1 is the
step-0 containment arm, a different one). Suggested fix: key the stage on the request shape
rather than a bare call counter — only `fields.include:["id"]` searches advance it, or gate
`FAKE_LIVE_IDS_FINAL` on a marker the ssh shim writes when `delete_item` is seen. Then 21a
should have `LIVE_AFTER` include the retired id, so the containment tolerance is exercised in
the green direction.

### 4. [fragile] `scripts/catalogue_release.sh:393` — `RETIRED_ITEMS` entries get no id-shape guard, and one shape reads as "already retired"

`$ONLY` is shape-checked three lines after it is parsed (`:127-129`), and
`item_unregister.sh:31-33` checks each id it is handed. `RETIRED_ITEMS` gets neither on the way
in: `retired_ids=$(printf '%s\n' $RETIRED_ITEMS | grep . | sort -u)` is unquoted (so also
glob-expanded against `$REPO`), and the entries then reach `curl "$S3_BASE/$id.json"` (`:423`)
and `curl "$API/items/$id"` (`:1005`).

The one that matters is the already-retired arm, because curl normalises dot segments out of a
path. Measured against a local listener:

```
$ curl -s -o /dev/null 'http://127.0.0.1:18099/bucket/../collection.json'
GET /collection.json HTTP/1.1
```

So a literal entry of `../collection.json` HEADs the bucket's own `collection.json`, gets 200,
and is reported as "already retired by an earlier run of this release" — the release then
proceeds, `to_delete` is empty, step 7's 404 loop normalises to a path that 404s, and
`RELEASE COMPLETE` prints with "retired 1 item(s)" having retired nothing. Fails closed on the
bytes, but it is a guard answering "yes, that was already done" about something that never
existed. A `case` arm mirroring `:127-129` over each `retired_ids` entry closes it, and makes
the literal consistent with the two other id entry points.

### 5. [fragile] `scripts/catalogue_release.sh:999` — step 7 compares a Python-sorted list against a shell-sorted list with `!=`

`final_ids` comes from `fetch_live_ids()`, i.e. Python `sorted()` (code-point order).
`local_ids` (`:290-292`) comes from the shell's `sort`, which collates by `LC_COLLATE`. Step 7
compares them as **strings**, so an order difference for an identical set reports "after the
retirement the served set is not this build" and exits 1 — after step 6's delete has already
run, which is the one place a false failure costs the operator a recovery.

Measured on this machine (`LC_ALL=en_US.UTF-8`): `sort` and Python agree on id-shaped inputs
including `bulk_co_ff04` / `bulk_coa_ff04` and `morr_al_ff04` / `morr_all_ff04`, so macOS is
not exposed. The exposure is a glibc release host, where `sort` in a UTF-8 locale discounts
`_` at the primary level — and the script's own header advertises that "a release can be cut
from any machine with creds and tailnet access". Every other comparison in the file goes
through `comm`, which at least collates both sides the same way; this is the first plain
string compare between the two sources. `LC_ALL=C sort` on `:292`, or testing
`comm -3` emptiness instead, removes it.

### 6. [fragile] `scripts/catalogue_release-check.sh:921` — case 21b's last assertion restates the one above it

```sh
expect_eq "nothing was deleted" "$(n_delete)" 0
expect_out "and step 6 was never reached" "$(printf 'RELEASE INCOMPLETE')"
```

The second line greps for `RELEASE INCOMPLETE`, which the assertion two lines earlier already
greps for; it carries no information about step 6. The real evidence is the `n_delete` line.
Either drop it or assert on something step 6 emits, e.g. that `=== 6: RETIRE ===` is **absent**
from `$OUT`.

## Checked and clean

Recorded so a later round does not re-derive these.

* **Delete placement.** `:955` (`[ "$fail" -eq 0 ] || exit 1`) is upstream of step 6 and
  downstream of every `fail=1` arm (asset probe, checksum probe, version, bucket version,
  licence × 2, deprecation, membership). Case 21b confirms zero `delete_item` payloads on a
  failing probe.
* **Delete scope.** `to_delete = retired_ids ∩ live_ids` (`:974`) is bounded by the literal,
  and the literal is bounded by: not-in-build (`:403`), live-or-in-bucket (`:420-431`),
  orphan containment (`:442`), group survival (`:464`), named in the tagged `NEWS.md`
  (`:567`), and `--only` refusal (`:141`). `item_unregister.sh` re-validates each id and
  always passes `COLLECTION`, which `:976` supplies explicitly (neither `COLLECTION` nor
  `HOST` is exported).
* **`comm` directions.** Mis-sorted inputs can only make `comm -23` *over*-report (so
  `unaccounted`/`surplus`/`lost` fail toward refusal) and can only make `comm -12`
  *under*-report (so `to_delete` can never exceed the literal). Walked the merge by hand.
* **Empty-list handling.** Every `printf '%s\n' "$x"` / `comm` pair survives an empty `$x`
  (one blank line, suppressed by `comm` because both sides carry it, and stripped by command
  substitution). Every new `grep -c` carries `|| true`. `retired_ids` / `n_retired` are
  normalised at top level (`:93-94`) so the `--only` path cannot hit `set -u`.
* **`awk '/^## /{n++} n==1'`** (`:568`) extracts exactly the top section: `^## ` does not match
  `# ` or `### `, so the preamble is skipped and subsections inside the entry are kept. The
  version gate at `:538-547` has already pinned the first heading to `## v$VERSION`.
* **`item_retract_s3.sh` prefix construction.** `s3://$BUCKET/$id/` keeps its trailing slash
  (`:126`), `$id` is shape-guarded at `:61` (which rejects `.`, so `..` cannot pass) with `-*`
  caught first at `:57`, and the root document is removed by exact key, not recursively. Case
  22e asserts both targets from the shim argv log.
* **Single `trap`.** `catalogue_release.sh:343` is still the only one, so nothing replaces it.
* **`build_wsgs` guard.** `build_wsgs=$(for … done | sort -u) || { … }` does fire on a python
  failure inside the loop — `pipefail` is in effect inside the command-substitution subshell,
  so the pipeline status is non-zero. Measured; not a defect.
* **`properties.wsg` on every item.** `item_create.py:463` writes it unconditionally and
  `item_validate.py:444` lists it as required, so `fetch_live_wsgs()`'s raise-on-missing is
  structurally safe rather than a one-item measurement.
* **Sync split.** The item sweep carries `--exclude 'collection.json'` and the collection goes
  up in a separate `aws s3 cp` after it (`:680-682`); case 2 asserts the ordering by shim-log
  line number, which is the right instrument.
* **R / Python default moves** (`test_pipeline.R`, `stage_years-check.R`, and the two
  `sloc_bt_ff04` comments) are comment-and-default-only and consistent with
  `scripts/README.md:481`'s updated env table.
