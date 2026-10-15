# Code check — round 1 (#89, v2.0.0 whole-network cutover)

Reviewer: code-review subagent. Date: 2026-10-15.
Scope: `/tmp/cc89/diff.txt` + full text of the seven changed scripts, against
`CLAUDE.md`, the soul code-check conventions, and the **live** catalogue.

**Verdict: no blocker. Nothing below would make the release fail halfway or succeed
while doing the wrong thing.** Four low-severity findings, all `fragile`, three of
them documentation quantities this branch's own rewrite missed.

---

## What I verified, in both directions

These are measurements, not readings of the diff. All taken 2026-10-15 in the repo
and against `https://images.a11s.one`.

| claim | how checked | result |
|---|---|---|
| `RETIRED_ITEMS` == the live item set, exactly | POST `/search` fields=[id] vs the literal | 23 live, `live-not-retired: []`, `retired-not-live: []` |
| the literal is 23 tokens, one bare assignment | `grep '^RETIRED_ITEMS='` + word-split count | 23 |
| every retired id is named in the tagged NEWS top section, delimited | reproduced the script's own `awk '/^## /{n++} n==1'` + its exact `grep -qE` | `unnamed in NEWS: none` |
| NEWS top heading is `## v2.0.0` | `sed -n 1,30p NEWS.md` | `## v2.0.0 (2026-10-15)` is the first `^## ` line; the blockquote above it is not a heading |
| group-survival arm passes | live `properties.wsg` (22 groups) vs build `properties.wsg` (23) | `lost: []`, `new: ['DUNC']` |
| build == 23 items, all `<wsg>_all_ff04`, disjoint from live | `ls data/stac` | yes |
| `collection.json` `rel:item` links == the file set (step 5's new arm) | parsed both | 23 == 23, equal |
| collection is unstamped pre-release (the release stamps it) | `version` key | absent — correct, step 0 stamps it |
| `summaries` consistent with the new README/CLAUDE.md text | read | `scenario:["all_ff04"]`, `species:["all"]`, `flood_factor:[4]` |
| `PROVENANCE_FLOOR=23` is exact | counted published provenance over all 23 built items | 23 of 23 carry a record |
| `PROV_CENSUS` is exact | counted per published field over the 23 built items | `link:run_uid` **18**; `link:config_sha256`, `processing:datetime`, all five `landcover:*`, and `processing:software.{link,flooded,drift}` all **23**; every `software.link` carries `+<sha>`, so `link_version`/`link_sha` are both 23 — matches the literal field for field |
| `EXPECTED_DEPRECATED = set()` is true of the build | scanned for a `deprecated` key | none of 23 carries one |
| the `_corrected` arm is satisfiable | read `processing:software.flooded` | `{'0.7.0': 23}` |
| `EXPECTED_STYLE_CATEGORIES` | `grep -c '<category '` on the committed styles | classified **10**, transition **91** — matches |
| `EXPECTED_RAT_ROWS` arithmetic | `transition_rat()` is the full cross product, `from*1000+to` | 10 classes → 10 rows / 100 transitions; codes are 0,1,2,4,5,7,8,9,10,11 so `src*1000+dst` stays collision-free with 0 in the table |
| style/RAT category arithmetic | 100 − 10 diagonal + 1 catch-all = 91; was 81 − 9 + 1 = 73 | consistent |
| nothing else filters code 0 | `grep 'code != 0\|code == 0\|No Data'` across `scripts/` | only the two new comments |
| the published figures do not move with the class table | `tree_transition_metrics()` keys on the upstream layer's `from_class`/`to_class` **strings**, not on `classes$code` | loss/gain/net unaffected by keeping code 0 |
| no second copy of the changed collection description | grepped the new sentence | one copy only (`item_create.py:681`) |
| no other reader of `RETIRED_ITEMS` | repo-wide grep | only `catalogue_release.sh`, `catalogue_release-check.sh`, CLAUDE.md prose |
| `README.Rmd`'s `dep` chunk survives an empty marker set | read it | guarded by `if (length(d) > 0)`; `deprecated` is built as `isTRUE(p$deprecated)` so the column exists and is all-`FALSE` |
| `SPECIES` covers `all` | `readme_functions.R:25` | `all = "whole network"` |
| `catalogue_release-check.sh` is not on the build path | `grep check run_pipeline.sh` | only `style_drift-check.py` runs there, so the empty-literal assertion cannot block this release |
| S3 retraction prefixes cannot over-reach | `item_retract_s3.sh:189-195` | uses `s3://$BUCKET/$id/` with the trailing slash; no old id is a prefix of a new one (`bowr_ch_ff04` vs `bowr_all_ff04`) |

### On question 1 — is the literal safe through every reader?

Yes. Walked all of them:

- `printf '%s\n' $RETIRED_ITEMS` (unquoted, `:93`) — 23 tokens, all `[a-z0-9_]`, no
  glob metacharacter, no whitespace-only member, so the word-split and the format
  reuse produce exactly 23 lines.
- `grep . | LC_ALL=C sort -u` then `grep -c .` — `n_retired=23`.
- the charset/leading-`-` shape guard loop runs before any reader of an id.
- the anchored sed twin in `catalogue_release-check.sh:904`
  (`re.subn(r'(?m)^RETIRED_ITEMS=.*$', …, count=1)`) still matches exactly one line:
  the new comment block says ``CLEAR THIS BACK TO ""`` but no comment line begins
  `RETIRED_ITEMS=`, so nothing shadows the assignment.
- **sort-order agreement** across every `comm`: `retired_ids` and `build_wsgs` use
  `LC_ALL=C sort`, `live_ids`/`after_ids`/`final_ids` are Python-sorted. For pure
  lowercase-ASCII + `_` + digits those two orders are identical, including the
  adjacent pair `morr_ch_ff06` / `morr_co_ff04`. Checked rather than assumed.
- the NEWS delimited `grep -qE "(^|[^A-Za-z0-9_-])$id([^A-Za-z0-9_-]|\$)"` — the ids
  appear in NEWS as `` `id`, `` and both backtick and comma are outside the class.

### On question 2 — does emptying the deprecation literals disable a guard?

No guard that could fire today is lost. Enumerated all seven arms of
`check_deprecated`:

1. `deprecated` must be `true` or omitted — **live**
2. version extension ⇔ `deprecated` present — **live**
3. marked **and** rebuilt (self-clear) — vacuous (nothing is marked)
4. `marked - EXPECTED_DEPRECATED` — **live**, and now strictly stronger: *any*
   marker is refused
5. `(EXPECTED_DEPRECATED & seen) - marked` — vacuous
6. `EXPECTED_DEPRECATED - seen` — vacuous
7. `elif not _corrected(fv)` — **live**, and it is what covers the direction #26
   exists for

The release's step-5 read-back (`dep_state`) also still runs and compares the served
marked set against the built one, so `NONE` is asserted rather than assumed.

One nit: the new comments in both `item_create.py` and `item_validate.py` say *"two of
its five arms are vacuous"*. It is three of seven by the enumeration above. The
conclusion they draw is right; the count is not. Not worth a commit on its own, but
`code-check.md`'s "treat `every`, `each`, `all N` as words to check" applies.

---

## Findings

- **[fragile]** `scripts/catalogue_release.sh:1017-1018` (step 6) — a partial delete
  aborts the release *before* step 7, with no recovery text.
  `bash scripts/item_unregister.sh $to_delete` is a bare simple command under
  `set -euo pipefail`. `item_unregister.sh` emits 23 separate `DO $$ … $$;` blocks into
  one `psql -v ON_ERROR_STOP=1` run with no enclosing transaction, so an error that is
  not `NO_DATA_FOUND` on, say, id 12 leaves 11 ids deleted, stops psql, and takes
  `catalogue_release.sh` down on `set -e`. Step 7 — which the script's own comment calls
  *"The ONLY evidence the delete happened"* — never runs, and neither does the
  `RELEASE INCOMPLETE … this is recoverable / re-run this release` block at
  `:2057-2070`. The operator sees a raw psql error and nothing about the half-finished
  state. **This is the one genuine half-way window in the release, and v2.0.0 is the
  first run that reaches it with a non-empty literal.** It is recoverable (no sync
  passes `--delete`, the bucket still holds every retired document, and the preflight's
  bucket witness treats already-deleted ids as a re-run), but only if the operator knows
  that, and this is exactly the path where the script otherwise goes out of its way to
  say so. Minimal fix: `bash scripts/item_unregister.sh $to_delete || { … print the
  same recovery text …; exit 1; }`.
  Mechanism: `code-check.md`, "A wrapper's exit is not the work" / `code-check-shell.md`,
  "A destructive setup and its undo must not share one timeout-able command".

- **[fragile]** `scripts/item_validate.py:473` (`MIN_FLOODED_VERSION = (0, 5, 0)`) — the
  now-sole over-mapping guard sits two minor versions below the correctness the release
  claims. With `EXPECTED_DEPRECATED` empty, arm 7 (`not _corrected(fv)`) is, by the
  branch's own comment, *"the only thing standing between the catalogue and an unmarked
  over-mapped item"*. But `NEWS.md` and CLAUDE.md both justify this cutover's geometry
  with **`flooded` 0.7.0's pinned grid** (floodplains#117 / flooded#67), not with the
  0.5.0 bankfull-units fix. An item rebuilt on 0.5.0 or 0.6.0 would publish unmarked and
  pass every arm while sitting on the pre-#117 DEM grid. The literal's own comment now
  reads *"all 23 carry flooded 0.7.0"*, which makes the gap easy to miss on the next
  read. Not a defect in this release (all 23 are 0.7.0, measured), and arguably
  pre-existing scope — but the branch is what made this arm load-bearing on its own, so
  either raise the floor to `(0, 7, 0)` or state in the comment that the floor
  deliberately covers only over-mapping and not the grid pin.

- **[fragile]** stale quantities this branch's rewrite missed. The diff carefully
  rewrote CLAUDE.md, NEWS.md and README.Rmd for 10 classes / 100 transitions, and left
  six restatements behind. `CLAUDE.md` is instructions, and `scripts/README.md:440` is
  the reference table an operator reads:
  - `CLAUDE.md:402` — *"The transition raster's 81 `from -> to` combinations"* → 100.
  - `scripts/README.md:440` — *"categorized on `class_name`, 9 io-lulc classes"* → 10.
  - `scripts/item_validate.py:1274` — *"the uniform 81-row scheme"* → 100-row.
  - `scripts/item_validate.py:~1296` — *"01_stage.R drops code 0 from drift's table …
    while the RAT still has its 9 rows"* — this one now describes the **opposite** of
    what the code does, in the docstring of the guard (`check_pixel_values`) that the
    removed filter was the reason for.
  - `scripts/item_validate.py:1745` — *"For `transition` 64 of 72 ship off by design"* →
    the denominator is 90 now.
  - `scripts/readme_functions.R:156` — *"ff04 for most, ff06 for `morr_ch_ff06`"* — that
    id is being retired by this release.
  None changes behaviour. Flagged because `agent-operations.md` §3 ("when one instance
  is stale, grep for the sentence, not the file") is the rule this is an instance of, and
  because the `item_validate.py:~1296` one inverts a stated fact inside a guard's
  docstring.

- **[fragile]** `scripts/catalogue_release.sh:84-86` — the "clear this back" instruction
  is enforced by a check nothing runs, and a forgotten clear misdiagnoses the *next*
  release. `catalogue_release-check.sh:927` asserts `^RETIRED_ITEMS=""$`, but that
  harness is not invoked by `run_pipeline.sh` or by the release, so nothing mechanical
  forces the post-release clearing commit. If it is forgotten and
  `item_retract_s3.sh` has already run (which `NEWS.md` commits to), the next release's
  `not_live` arm HEADs each id, gets 404, and exits with
  *"RETIRED_ITEMS names an item that was never published"* — a refusal, so the direction
  is safe, but the message names the wrong cause and the stated remedy ("check the
  literal against what the collection serves") sends the operator the long way round.
  Worth one sentence in the comment, or an arm that distinguishes "retired by a previous
  release" from "never existed".

---

## Not findings (checked and dismissed)

- **Code 0 and the transition encoding.** `src*1000+dst` with codes
  `{0,1,2,4,5,7,8,9,10,11}` stays injective (every `dst < 1000`), so adding 0 adds 19
  rows and collides with none. The transition COG's nodata is `-2147483648`, so the new
  value `0` (`No Data → No Data`) is not confusable with it.
- **Published figures moving because of the class table.** They do not;
  `tree_transition_metrics()` reads `from_class`/`to_class` label strings off the
  upstream transition layer.
- **`classes[, cols]` dropping to a vector** after the `code != 0` filter was removed —
  four columns are selected, so `drop` does not apply, and the `setequal` floor directly
  below would catch it anyway.
- **`props$deprecated` partial-matching** in `README.Rmd` (`code-check-r.md`, "`$` on a
  list partial-matches") — the column is constructed unconditionally in
  `readme_functions.R:278`, so there is no absent-key case to partial-match into.
- **`catalogue_release-check.sh` failing with the literal set** — out of scope per the
  brief, and confirmed off the build path.
- **`sloc_all_ff04` as the new determinism default** — the item exists in the build, so
  neither sibling check hits the "an id nothing stages" failure the old comment warned
  about.
- **prov_fields-check.py fixture retake.** Re-derived every number: 18 full + 5 part + 2
  none = 25 seen / 23 traced; `per_section` 23/23/23; the census arm's `18` + `{23}`;
  `floor=23`; "set it to 24" (the +1 item makes the eleven non-`run_uid` fields 24);
  floor-behind 22 / floor-ahead 24; "PROV_CENSUS says 23" in all three loss arms. All
  move consistently, and all match the measured build.
