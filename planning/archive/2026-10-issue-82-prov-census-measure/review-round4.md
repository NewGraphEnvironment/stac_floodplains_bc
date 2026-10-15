# Code-check round 4 — the round-3 fix commit (#82)

Reviewed 2026-10-15, 18:42–18:50Z (11:42–11:50 PDT). Branch
`82-produce-the-provenance-floor-and-census` at `912856d`, which is the whole subject: the
round-3 fix commit, comment- and prose-only. Scope as briefed: verify the corrected claims
against the producer tree now, check each carries its time, look for contradictions between
copies, and attack the third mechanism's enumeration.

**Verdict: no bugs. Nine findings, all `fragile`, all about claims rather than code** — which
is the right shape for a commit that changed no executable line. Two of them are material: an
**eleventh tree claim the triage table missed and which is false** (finding 1), and a
**recurrence condition over-claimed in five live copies, falsified by 22 counterexamples on
the same disk** (finding 2). One is time-critical: the **draft PR body still carries the
falsified claim as a section heading** (finding 6), and no PR exists yet.

---

## Step 1 — the tree, measured now

`Rscript scripts/prov_census-measure.R` from the repo root, **2026-10-15T18:42:53Z**, exit 0:

```
items on the roster: 23   staged: 23   carrying any provenance: 23   <- PROVENANCE_FLOOR
  link_run_uid 18;  the other eleven 23
producer v0.1.13-3-g760b8d9-dirty (760b8d9)
5 item(s) missing link_run_uid: kotl_all_ff04, larl_all_ff04, sloc_all_ff04, dunc_all_ff04,
                                mcgr_all_ff04
18 item(s) with all 12
```

**The numbers have not moved since 18:38Z.** The `peace` run reported in flight at 18:41Z has
not changed them: 23/23/23 is exactly what `CLAUDE.md:260-262` and `NEWS.md:52-55` record, and
every Peace group (`pcea`, `pars`, `pine`) already holds `rasters/all_ff04/`. So no sentence in
the commit is stale for having been overtaken again.

`../floodplains/data/dunc/provenance.json` (mtime 18:38Z), `network/all2`:

| leaf | value |
|---|---|
| `inputs.link.version` | `0.50.0` |
| `inputs.link.sha` | `null`, `sha_source: "unresolved_version_mismatch"` |
| `link_log` | **present**, `link_sha 8215d2d072f21c6c915612234b41ef3e47da747e` |
| `link_log.link_version` | `0.63.1` |
| `link_log.run_uid` | `null` |

So the corrected claim's core is true: the pair `item_create.py` refuses half-present is even.

## Step 2 — each corrected claim, against the code and the record

| claim | where | verdict |
|---|---|---|
| `link_version` from `inputs$link$version`, `link_sha` from `link_log$link_sha` | CLAUDE.md:254-256 | **true** — `fp_provenance.R:63-66` |
| the two publish as ONE `processing:software` entry and `item_create.py` raises on one without the other | CLAUDE.md:256-258 | **true** — `PROV_SOFTWARE = {"link": ("link_version","link_sha"), …}` (`item_create.py:209-213`), `raise SystemExit("… half-present …")` at `:506-519` |
| "aborts the whole build, not just its own item" | CLAUDE.md:252 | **true** — `run_pipeline.sh:67` invokes `item_create.py` **once** for the whole build under `set -euo pipefail` (`:14`) |
| DUNC stages: config in `columbia.yml`, both bundles, seven rasters | CLAUDE.md:256-257 | **true** — `config/regions/columbia.yml` `watershed_groups: [KOTL, LARL, SLOC, DUNC]`; `data/dunc/floodplain_landcover.gpkg` + `floodplain.gpkg`; seven `.tif` (3 floodplain + 3 classified + transition), the eighth being the `dem_all2.tif` cache |
| "The Columbia run of 2026-10-15 cleared it — measured 18:38Z, `link_sha 8215d2d0…`" | CLAUDE.md:259-261 | **true**, verified above |
| "the pair is even at 23" | CLAUDE.md:261 | **true** — `link_version` 23, `link_sha` 23 |
| "a build no longer aborts" | CLAUDE.md:261 | **inferred, not measured** — finding 4 |
| "was in exactly that state from 2026-10-14" | CLAUDE.md:257, both scripts | **over-stated start** — finding 9 |
| "the state recurs whenever upstream cannot resolve a sha" | CLAUDE.md:262-263 + 4 copies | **falsified as a sufficient condition** — finding 2 |
| NEWS: five measurements, "floor 20 … refusal … 21 … 22 … 23 … link_run_uid 18 and the other eleven 23" | NEWS.md:51-55 | **true**; 17:37Z→18:38Z is 61 min, five distinct outcomes, one a refusal. The 17:37Z shape (floor 20, `link_run_uid` 18, `link_config_sha256`/`link_sha` 19) is internally consistent with `mcgr`+`dunc` lacking `run_uid` and `dunc` then lacking all three log fields |
| NEWS: "while DUNC was in that state a rebuild aborted on it whichever region a release was for … and the Columbia run then cleared it" | NEWS.md:59-62 | **true** |
| script comments, both de-tensed to "was in exactly that state … until the Columbia run" | `prov_census-measure.R:36-39`, `prov_fields-check.py:338-342` | **true**, except the shared over-claim in finding 2 |
| `scripts/README.md`'s converted-ahead-of-run sentence | README:373-377 | **false at the stated offset** — finding 1 |

Guards still pass after the comment-only edits: `uv run python scripts/prov_fields-check.py`
→ **49 assertions, 0 failed** (18:45Z). `git show HEAD -- scripts/*` has **no** changed line
that is not a comment, so no arm could have moved.

The round-3 enumeration reproduces exactly: the grep in `findings.md:292-296` returns **68**
hits at `a37a0c2...HEAD`.

---

## Findings

### 1. **[fragile]** `scripts/README.md:374-375` — "two of them an hour later" is false, and it is the eleventh tree claim, returned by the triage's own grep and absent from its table

> Rostered targets sit in exactly that state whenever a group's config is converted ahead of
> its run — `kotl`, `larl` and `sloc` at 2026-10-15T17:37Z, **two of them an hour later** as
> the Columbia run landed — and reading one raises…

From the branch's own series, which the same commit wrote into `CLAUDE.md` and the script
header: 3 at 17:37Z, 2 at 17:58Z (+21 min), 2 at 18:16Z (+39 min), **1** at 18:33Z (+56 min),
**0** at 18:38Z (+61 min). Re-measured myself at 18:42:53Z: 23/23 staged, no skips, and all of
`kotl`/`larl`/`sloc` hold `rasters/all_ff04/`. So at the hour mark the count is zero, not two;
two held at +39 minutes.

Why it is a miss rather than a leftover: the round-3 grep **did** return this line (it is hits
122-123 of the 68), and the triage table in `findings.md:297-306` gives it no row — round 2 had
"fixed" it, so round 3 counted it closed. The table's ten rows are therefore not the ten tree
claims in the 68; this is an eleventh, and the one the brief predicted.

Remedy, one clause: "two of them 39 minutes later and none an hour later", or de-tense it the
way the other copies now are, pointing at the script header for the series.

### 2. **[fragile]** Five live copies over-claim the recurrence condition: "whenever upstream cannot resolve a sha" — measured, that is true of 23 of 23 staged items and none of them is half-present

Copies: `CLAUDE.md:262-263`, `scripts/prov_census-measure.R:39` ("reachable whenever"),
`scripts/prov_fields-check.py:341`, `planning/active/findings.md:324-325`, #89's Decided
bullet — plus the commit message of `912856d` and the floodplains#133 comment, neither of which
can be edited.

Measured 2026-10-15T18:45Z over every `network` section in `../floodplains/data/*/provenance.json`:
`inputs.link.sha` is `null` with `sha_source: "unresolved_version_mismatch"` on **all 23 `all2`
sections** — every whole-network section on the roster — and **all 23 publish**, because each
carries a `link_log` supplying the sha. The half-present state needs **both** sources empty,
which is what floodplains#133's own body measured (BULK/KISP/MORR share DUNC's `inputs.link`
exactly and publish).

As written, the sufficient condition is falsified by 22 counterexamples on the same disk, and
it names upstream's own token for a near-universal state. A future maintainer reading it would
expect the arm to be live on every item. Remedy: "whenever the log row is absent or carries no
`link_sha` **and** `inputs$link$sha` is null — the conjunction, which is what DUNC had and the
other 22 do not."

### 3. **[fragile]** `planning/active/findings.md:327-328` and the floodplains#133 comment undercount the `run_uid` carve-out by one — `mcgr` is the fifth

> `link_log` carries no `run_uid` even now, which is the modelled `kotl`/`larl`/`sloc` shape and
> is why `link_run_uid` stays at 18.

floodplains#133's comment states it outright: "so `link_run_uid` stays absent for **those
four**".

Measured 18:42Z: 23 − 18 = **five** items lack it — `kotl`, `larl`, `sloc`, `dunc` **and
`mcgr`** — and `link_log.run_uid` is `null` in all five records, non-null in `bulk`'s
(`20260901_234743-6628379d`). The repo's own script printed the five **by name** in the output
the comment was written from, 2 minutes earlier.

"stays at 18" is arithmetically right; the explanation beside it accounts for four of the five.
A carve-out is a number too. Remedy: name five, or say "the five items whose `link_log`
predates link#262's `run_uid`" and let the script's own line carry the ids. The #133 comment
needs a one-word edit — it is in a NGE repo, so no approval question.

### 4. **[fragile]** `CLAUDE.md:261` — "a build no longer aborts" is an inference; nothing ran a build

What was measured is narrower and is what the sentence should say: the half-present arm cannot
fire (pair even at 23) and `prov_census-measure.R` exits 0 on the full roster.
`prov_census-measure.R` deliberately declines the `sf`/GDAL/`drift` arms (its own header says
so), so a clean census is silent about them, and `run_pipeline.sh` was not run.

I probed the most likely residual rather than leaving it as an unknown: every one of the 23
staged targets records `drift 0.20.0` in its `landcover` section, equal to the installed
`drift` 0.20.0, so `01_stage.R:681-695` (`ALLOW_DRIFT_SKEW`) would not stop the build. The
mtime guard is covered too, because the census mirrors `fp_prov_rasters_current()` and passed.
That supports the claim; it does not establish it — the layer-key and foreign-`wsg` arms (#80)
and everything downstream of `01_stage.R` are untested on this tree.

Remedy: "the half-present arm no longer fires, and the census reads clean over all 23 — a
rebuild has not been run since." NEWS.md:62's "the Columbia run then **cleared** it" is already
correctly scoped to the condition, so only the CLAUDE.md sentence needs it.

### 5. **[fragile]** The enumeration grepped **added** lines in three paths, so four uncorrected copies of the same claim survive — two of them in the files it fixed, two in committed `planning/`

`git diff … | grep -E "^\+"` over `scripts/ CLAUDE.md NEWS.md` cannot see a pre-existing line,
and `planning/` was not in the path list. What it missed:

| where | text | state |
|---|---|---|
| `CLAUDE.md:238-240` | "DUNC cannot publish at all until floodplains#133 is resolved, so a release cut **today** would fail one step earlier" | undated, present tense, **20 lines above** the new paragraph saying a build no longer aborts. Pre-existing (`9096404`, 2026-10-14), untouched by the branch |
| `NEWS.md:68-70` (#76 entry, **Unreleased**) | "a full release is blocked upstream by floodplains#125 (…measured 2026-10-14), **floodplains#133 (DUNC) and MCGR's config state**" | the blocker list is undated and all three are clear on disk at 18:42Z: 23/23 stage, `mcgr` and `dunc` among them, every group holds `rasters/all_ff04/` |
| `NEWS.md:199-206` (#75 entry, **Unreleased**) | "DUNC is refused one step earlier by `item_create.py` … so a release cut **today** would fail before the census", beside "the current roster measures 17 / 20 / 20" | undated; same release's notes now carry three incompatible accounts of the same fact |
| `planning/active/task_plan.md:19-21` and `planning/active/findings.md:27-29` | "DUNC cannot publish until floodplains#133 … a release cut today fails one step earlier" | branch-added, committed, outside the grep's path list |

The NEWS pair is the one with a reader: lines 51-55, 68-70 and 199-206 all ship in the **same
Unreleased section**, and a reader going top to bottom gets 23/23 and cleared, then blocked by
#133, then 17/20/20 and blocked by #133. This is `code-check.md`'s **One fact derived twice**,
fly#97 row — "a figure held in N copies is N facts, and each review round fixes the copy it was
shown" — and **Written data outlives the fix**, which prescribes exactly the missing step:
*enumerate every artifact quoting it — repo prose, release notes, PR descriptions, issue bodies
in every repo you filed into.*

The `planning/` pair is arguably a dated session record and may be left; the defect is that the
enumeration **claimed completeness over "this branch's added prose"** while its path list
silently excluded two copies of the very claim being corrected. If they stay, say so in the
table rather than leaving them unseen.

Remedy for the enumeration itself, one line, no `^+` filter and no path list:

```bash
grep -rnE "cannot publish|blocked by floodplains#133|release cut today|link_sha. null" \
  CLAUDE.md NEWS.md scripts/ planning/active/
```

### 6. **[fragile]** The draft PR body still leads with the falsified claim, and no PR exists yet

`…/scratchpad/pr.md:49-59` carries it as an **H2 heading**:

> `## A build of today's tree aborts`
> "DUNC stages `link_version` with `link_sha` null … So `run_pipeline.sh` aborts on it whichever
> region a release is for … **A release cannot be cut from this tree**"

and, under Verification, "23 rostered / 20 staged / floor 20, `link_run_uid` 18,
`link_config_sha256` and `link_sha` 19" — undated, and three numbers out of date — plus a
placeholder path `planning/archive/.../findings.md`.

`gh pr list --head 82-produce-the-provenance-floor-and-census --state all` returned `[]` at
18:44Z, so nothing is published yet and `/gh-pr-push` would publish this as written. It is not
a tracked file, which is exactly why the diff-scoped enumeration could not see it.

### 7. **[fragile]** #89's body contradicts itself after the correction — three places, one of them a number presented for pasting

Checked 18:43Z. The "Decided" bullet now carries the correction and the 18:38Z clearing. Still
in the same body, below it:

- **"Verified state, 2026-10-15" table.** Columbia row: "`kotl`/`larl`/`sloc` still `bt_ff04`
  (not yet converted); `dunc` ready but **blocked by floodplains#133**". Peace row: "**1/3**;
  `pars` and `pine` have `primary_scenario: all_ff04` and **only `bt_ff04` rasters**". Measured
  18:44Z: all six of those groups hold `rasters/all_ff04/`, all six stage, and `dunc` is not
  blocked. The table's date is the same day as the correction, so the date cannot tell a reader
  which half to believe.
- **"floodplains#133 (DUNC), diagnosed precisely"** — "and **no `network/all2/link_log` section
  at all**". False since 18:38Z, and the direct contradiction of the bullet 40 lines above.
- **Step 3, release runbook** — "`prov_fields-check.py`'s asserted populations (**18/21/23
  today**)". The asserted populations are **18 / 3 / 2** (`prov_fields-check.py:204-208`: 18
  whole, 3 missing only `link_run_uid`, 2 with none). 18/21/23 is the census-and-roster triple
  under the populations' name, undated, in a runbook whose own "Do not" section says not to
  carry these numbers from the issue.

Minor, same bullet: "both bundles and **seven classified rasters**" — seven rasters, three of
them classified. `CLAUDE.md:256-257`'s "seven rasters" is the right form.

The convention is a body that reads correctly top to bottom
(`feature-workflow.md`, "Issue bodies get edited, not appended"), and #89 is the document the
next release is picked up cold from.

### 8. **[fragile]** `planning/active/findings.md:319` says "three files and an issue body" — it was four files

CLAUDE.md, NEWS.md, `prov_census-measure.R`, `prov_fields-check.py`. `progress.md:552` and the
commit message of `912856d` both say so ("`CLAUDE.md`, `NEWS.md`, **both scripts** and #89's
body"), and the triage table in the same document lists hits in four files. One-word fix; it
matters only because the count is the record of how wide the copy problem was, and this is the
mechanism that keeps mis-counting its own copies.

### 9. **[fragile]** "was in exactly that state **from 2026-10-14**" names the first measurement, not the start

`CLAUDE.md:257`, `prov_census-measure.R:37`, `prov_fields-check.py:339`. 2026-10-14 is when
floodplains#133 measured it. The state began when DUNC's record was written with `link_log:
null` — `config/dunc/area.yml` records a standalone run on **2026-10-12** under
`network_source: fresh`, where DUNC was absent from `fresh.log`, and the landcover section's own
`run.datetime_utc` is `2026-10-12T01:38:40Z`. Today's run overwrote the record, so the start is
no longer verifiable on disk, which is the reason to write what is known: "from at least
2026-10-14 (first measured)" or "from the 2026-10-12 standalone run".

---

## Observation, not a finding: what the Columbia run actually changed

Recorded because it bears on the framing "the Columbia run cleared it", and because the
measurement is cheap to lose.

floodplains#133's ask 1 — resolve `sha_source: "unresolved_version_mismatch"` — is **still
unresolved on disk**. What changed is that a second source appeared, and for four areas that
source's sha belongs to a **different link version** than the one published:

| area | published `link` entry would be | sha's own `link_log.link_version` |
|---|---|---|
| `dunc` | `0.50.0+8215d2d0…` | **0.63.1** |
| `kotl` | `0.50.0+322389a3…` | **0.45.1** |
| `larl` | `0.50.0+8c8c29b2…` | **0.45.1** |
| `sloc` | `0.50.0+322389a3…` | **0.45.1** |

The other 19 agree (`0.50.0` both sides). This is **pre-existing and already published** —
`kotl_bt_ff04`, `larl_bt_ff04` and `sloc_bt_ff04` are live with that shape — so it is neither
this branch's defect nor its job, and the repo's "floodplains#133 is still open as written" is
honest about it. It is worth a line in whatever closes #133, because `item_create.py:510-516`'s
own comment is about exactly this hazard ("a partial version string would claim a version
nobody ran"), and the whole-entry form claims one too.

## What would terminate the loop

Rounds 1-3 closed two enumerations by construction (source-text reads, build-condition
fidelity) and both held under round 3's attack. The third mechanism — one tree claim in N
copies — is **not** closed, and round 4 found its eleventh instance with the triage's own grep
output (finding 1) plus six more copies outside the grep's scope (findings 5, 6, 7). It closes
the way fly#97 closed: **every count about the moving tree lives in exactly one copy, and the
others carry count-free claims pointing at it.** `prov_census-measure.R`'s header is the
natural single copy, because it prints the series itself. A grep with no `^+` filter and no
path list is the mechanical check, and it must include the PR draft and the issue bodies, which
are not in `git diff` at all.
