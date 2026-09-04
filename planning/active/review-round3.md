# Code-check round 3 — #26 deprecation markers

Scoped to **round 2's fixes**. Reviewed `git diff main` (11 files), plus
`scripts/item_validate.py`, `scripts/catalogue_release.sh` and
`scripts/catalogue_release-check.sh` read in full against the working tree — which has moved
past the diff I was handed (the step-5 read-back is now **one** `python3` with **one**
`json.load` per file, and the BAD message already splits the two sides through `_d`; both
concerns in the brief's Q3 were already fixed before I got here).

Everything below was **run**, not reasoned:

- `bash scripts/catalogue_release-check.sh` on the unmutated tree → **ALL PASS**, exit 0.
- Four restore-the-bug mutations of `catalogue_release.sh`, each run through the full harness.
- `check_deprecated` driven directly over seven hand-built trees, both modes.
- The proposed fix for finding 1 applied to a copy and re-run over all seven trees **and**
  the real `data/stac`.
- Every number in the `v1.1.0` entry recomputed from the **live API** (20 items) against
  `data/stac/` (23 items) — including a full 140-asset checksum sweep, not a sample.

**Convergence: the class round 2 opened is NOT closed.** One arm still sits on the wrong side
of the `--partial` line, and the enumeration below shows which one and why. Round 2 fixed the
instance; the mechanism recurred one arm over.

---

## Findings

### 1. **[bug]** `scripts/item_validate.py:355-358` — `--partial` still disables an arm for ids the tree **contains**, and it is the arm that catches the two literals desynchronising

Round 2 moved `marked - EXPECTED_DEPRECATED` above `if partial: return` on the argument that
it "names only ids the tree actually contains, so it holds on ANY tree". That argument applies
to **half** of the arm still behind the flag:

```python
if partial:
    return problems
for i in sorted(EXPECTED_DEPRECATED - marked):        # <- only the ids ABSENT from the
    problems.append(f"{i}: expected deprecated: true, not marked")   #    tree need a full view
```

`EXPECTED_DEPRECATED - marked` needs the whole catalogue only for ids **not in the tree**.
Restricted to `(EXPECTED_DEPRECATED & seen) - marked` it names only ids the tree contains — the
exact form round 1 prescribed (*"restrict them to ids the build actually contains:
`(EXPECTED_DEPRECATED & seen)` vs `marked`"*), which round 2 adopted for the other direction
and not for this one.

**Measured.** A subset tree holding `mcgr_ch_ff04`, unmarked, carrying a non-null
`nge:flooded_version`:

```
-- S2 mcgr present, unmarked, fv non-null
  partial=True : CLEAN
  partial=False: ['mcgr_ch_ff04: expected deprecated: true, not marked', ...]
```

Same result with a second, healthy group beside it (S3), so it is not an artefact of a
one-item tree.

**Why it matters, and why `--only` is the likely path.** The two literals are hand-set in two
files, and `EXPECTED_DEPRECATED - marked` is the *only* guard that fires when
`item_create.py`'s copy is edited and `item_validate.py`'s is not. The documented future flow
for #26 is precisely that edit: the docstring at `:279-283` says *"when floodplains#76 unblocks
and MCGR is rebuilt … the first corrected build fails the release until the id is deleted from
the literal"*. An operator deleting it from `DEPRECATED_ITEMS` only, and republishing through
the single-group pilot path (`--only mcgr_ch_ff04`, which is what #36 exists for), gets a
CLEAN gate — and publishes an item whose geometry may not have moved, unmarked, looking
current. That is the failure #26 was opened to prevent, on a bucket with versioning Suspended.

Step 5's read-back cannot catch it either: the deprecation block is inside
`if [ -z "$ONLY" ]` (`catalogue_release.sh:646`), so under `--only` nothing observes the marker
from the consumer's side.

The converse arm covers this **only while `fv` is null**, which is true of `mcgr`/`pine`
today and stops being true the moment the producer emits a `provenance.json` for them.

**Fix, verified.** Move it above the early return with `& seen`:

```python
for i in sorted((EXPECTED_DEPRECATED & seen) - marked):
    problems.append(f"{i}: expected deprecated: true, not marked")
if partial:
    return problems
for i in sorted(EXPECTED_DEPRECATED - seen):
    ...
```

Applied to a copy and re-run: S2/S3 become `['mcgr_ch_ff04: expected deprecated: true, not
marked']` under `partial=True`; the healthy fixture stays CLEAN both ways; and
`data/stac` stays **CLEAN both ways**. It also *removes* a duplicate message on a full
release — an id in the literal but absent from the build currently reports both "not marked"
and "absent from the build", and with `& seen` reports only the accurate one (S1/S7).

---

### 2. **[fragile]** `CLAUDE.md:102`, `scripts/README.md:59`, `scripts/item_validate.py:263` — three surfaces state something S2/S3 disproves

- `item_validate.py:263` — *"`partial` drops the two arms that need to see the WHOLE
  catalogue"*
- `CLAUDE.md:102` — *"`--partial`, which drops only the two arms that ask about ids **absent**
  from the tree"*
- `scripts/README.md:59` — *"drops only the arms asking about ids absent from the tree"*

`EXPECTED_DEPRECATED - marked` asks about ids that are **unmarked**, which includes ids present
in the tree. This is round 2 finding 6 recurring on the arm round 2 did not move, and
`findings.md` already names this class as explicitly not closed after four rounds on #47.
Fixing finding 1 makes all three sentences true again — the cheap direction.

(`NEWS.md:70`'s *"the marker … been dropped"* survives, because for the two real items `fv` is
null and the converse arm catches it. It becomes false the day either gains a provenance
record.)

---

### 3. **[fragile]** `scripts/catalogue_release.sh:691` — `served &= built_ids` is load-bearing and has **zero** coverage

This one line is round 2 finding 8's entire fix. Two mutations, both run:

| mutation | harness result |
|---|---|
| delete `served &= built_ids` | **ALL PASS** — nothing notices |
| delete the whole step-5 deprecation block | 6 FAILED (case 2's read-back, 9k ×3, 9l ×2) |

So the block is well covered and the line inside it is not. And it is not decoration — I added
a case that exercises the mode it exists for (a full `--allow-retract` release where the build
drops the marked fixture item while the shim still serves it marked) and ran it both ways:

```
=== WITH the intersection ===        === WITHOUT ===
  ok    exit 0                         FAIL  exit 0 (got '1', want '0')
  ok    RELEASE COMPLETE               ... RELEASE INCOMPLETE, after the sync and register
```

That is the exact defect round 2 reported, reproduced by removing the fix. Every other change
in this diff has a restore-the-bug proof; this one does not, and the harness already has the
machinery (`FAKE_LIVE_IDS`, `FAKE_LIVE_DEPRECATED`, `ALLOW_RETRACT`). Note when placing it:
my probe case perturbed case 10 downstream, so it needs `PARTIAL_STAGE` and the fixture
restored before the next case, as 9j already does for `collection.json`.

---

### 4. **[fragile]** `scripts/catalogue_release.sh:671-672` — the comment justifying the intersection names a guard that is switched off in the one mode the intersection is for

> *"Orphans are already the id comparison's business above, which names them and offers
> `item_unregister.sh`."*

`catalogue_release.sh:512`:

```bash
if [ -n "$extra" ] && [ -z "$ALLOW_RETRACT" ]; then
  echo "LIVE BUT NOT IN THIS BUILD:"; ...; fail=1
fi
```

Under `--allow-retract` — the *only* mode in which the intersection changes the outcome —
orphans are neither named nor counted. So a deliberately retracted `mcgr_ch_ff04` stays live
serving `deprecated: true`, step 5 prints `deprecation markers served: pine_bt_ff04`, and the
release prints `RELEASE COMPLETE` with nothing anywhere saying an item was left behind still
claiming to be stale. The accommodation is right; the reader's reason to trust it is not.
One line — echo the retracted set out loud under `--allow-retract` — closes it.

---

### 5. **[fragile]** `scripts/item_validate.py:337` — `fv is not None` is a proxy for "rebuilt on flooded >= 0.5.0", and only the *null* half of the proxy is stated

The converse arm's message (round 2's rewrite) is honest about the null direction: *"carries no
`nge:flooded_version`, so nothing here can tell whether it was rebuilt on flooded >= 0.5.0"*.
Nothing says the same about the non-null direction, and the code never reads the **value**: an
item publishing `nge:flooded_version = "0.4.0"` passes unmarked through both modes. That is an
over-mapped item shipping looking current — #26's own failure, one version string over.

Measured today: all 21 provenanced items carry exactly `"0.5.0"`, so the gap is not live. It is
cheap to close — `_SEMVER` is already compiled at `item_validate.py:46` — and closing it would
make CLAUDE.md's *"marked **iff** it lacks `nge:flooded_version`"* and `NEWS.md`'s *"`0.5.0`
means corrected"* the same statement, which they currently are not.

---

### 6. **[fragile]** `scripts/catalogue_release.sh:700` — the delimiter comment cites a check that does not cover its subject

> ``# `|` is a safe delimiter: the id shape check at the top of this script rejects it.``

The shape check (`:102-103`) validates `$ONLY` only. The ids being joined here come from
`$STAC_DIR/*.json` and from the API, neither of which passes through it. Unreachable in
practice — `item_create.py` emits `<wsg>_<sp>_ff0N` — but the stated reason is not the reason.
`fmt` joining on a character no id can contain (or emitting JSON) is the honest form.

---

## Answers to the specific questions

**Q1 — is round 2's `--partial` split correct? Is any arm on the wrong side?** One is. The
complete arm set, and where each sits:

| # | arm | names ids… | safe on a subset? | current side |
|---|---|---|---|---|
| 1 | `flag is not _ABSENT and flag is not True` | in tree | yes | always ✅ |
| 2 | `has_ext != (flag present)` | in tree | yes | always ✅ |
| 3 | self-clear: `flag is True and fv is not None` | in tree | yes | always ✅ |
| 4 | converse: `flag is not True and fv is None` | in tree | yes | always ✅ |
| 5 | `marked - EXPECTED_DEPRECATED` | ⊆ marked ⊆ seen | yes | always ✅ (round 2) |
| 6 | `EXPECTED_DEPRECATED - marked` | **mixed** — `& seen` is in tree | **partly** | partial-only ❌ |
| 7 | `EXPECTED_DEPRECATED - seen` | absent by definition | no | partial-only ✅ |

Seven arms, one misplaced, and the misplacement is *partial* (row 6 splits cleanly into a
subset-safe half and a full-tree half). That is the enumeration, not a claim of convergence:
**the class is open until row 6 is split.**

**Q2 — does the converse arm's message match what the code does?** Yes for the null branch,
including the third remedy round 2 asked for ("fix the provenance instead"). It leaves the
non-null branch's proxy unstated — finding 5. The self-clear message at `:339-345` matches
its code exactly, both branches.

**Q3 — trace the step-5 python.** The working tree's version is a single reader; the two-`json.load`
shape described in the brief is gone. Checked:

| case | behaviour |
|---|---|
| `collection.json` in the glob | skipped by `d.get('type') != 'Feature'` ✅ |
| a file that will not parse / has no `id` | raises → non-zero → `pipefail` → `READFAIL`, `fail=1`, verdict line still printed ✅ |
| `curl` fails, or returns non-JSON with a 200 | same path ✅ |
| inner command succeeds but prints nothing | unreachable (`print` is unconditional); would fall to `*)` → `fail=1`, i.e. **toward refuse** ✅ |
| response missing `features` | `KeyError` → `READFAIL` ✅ |
| served set is empty while the build marks two | `BAD NONE\|mcgr… pine…` → `fail=1` ✅ (this is case 9k) |
| `served &= built_ids` masking a real mismatch | bounded: anything outside `built_ids` is an orphan, which `:509-515` refuses **unless** `--allow-retract` — findings 3 and 4 |

**Q4 — do 9k/9l discriminate? Does marking `bbbb` break anything?** Both discriminate:
deleting the step-5 block turns 9k red on all three assertions and 9l red on two, plus case 2's
read-back — 6 FAILED. Both `n_partial_flag` assertions bite in both directions (removing
`--partial` from the `--only` branch → case 15 red; adding it to the full branch → case 2 red).
Marking `bbbb` breaks nothing: every `--only` case runs against `aaaa_ch_ff04` (lines 551-640),
`bbbb` appears only as the untouched-sibling assertion and in the live-id lists, and the harness
is ALL PASS. Case 15's provenance read-back and cases 6/7's item read-back all read `aaaa`.

**Q5 — NEWS.md, every number re-derived.** All correct. Measured against the live API (20
features) and `data/stac` (23 items), compared **exactly**, not to a tolerance:

| claim | measured |
|---|---|
| 23 items, 20 live, 3 new, no item dropped | 23 / 20 / `lnth`,`thom`,`unth` / **0 orphans** ✅ |
| three new groups are Thompson, region fraser | all three `region = fraser` ✅ |
| thirteen change, seven unchanged | 13 / 7, over `floodplain_ff0{2,4,6}_km2`, `gross_loss_ha`, `gross_gain_ha`, `net_ha` ✅ |
| all 13 table rows (published, corrected, retained) | every row reproduces to the printed digit ✅ |
| "1.5% to 33.5%" | `pcea` 1.46%, `tabr` 33.55% ✅ |
| `necr_ch_ff04` 396.52 → 396.51 | ✅ |
| `PROVENANCE_FLOOR` 21 | 21 items carry ≥1 non-null `nge:` ✅ (`catalogue_release.sh:60`) |
| exactly `mcgr`+`pine` marked, `fv` null on exactly those two | ✅ |
| `nge:flooded_version` `0.5.0` on all 21 | one distinct value, `0.5.0` ✅ |
| the two marked items declare 4 extensions, the rest 3 | ✅ |

**The new checksum paragraph is true, and now measured over the whole population** rather than
the five items round 2 sampled: **140 assets across all 20 common items, 0 with an identical
`file:checksum`.** So *"every asset on every item has a new checksum in this release, including
items whose geometry is identical"* is literally correct, and *"it cannot answer 'did the
geometry change'"* follows.

**Q6 — any harness assertion that would still pass if its guard were deleted?** One, and it is
finding 3: `served &= built_ids`. Every other assertion added in rounds 1–2 was mutated and
went red.

**Q7 — anything failing toward pass or silent success?** Finding 1 (a CLEAN gate on input the
full gate refuses) and finding 4 (a retraction that leaves a marked orphan live, silently). The
step-5 reader itself fails toward **refuse** on every input I could construct, which is the
right direction.

---

## Verified correct, so no action

- The `--partial` and full-release summary lines at `item_validate.py:1514-1526` claim exactly
  what runs — the "iff" holds under `--partial` because both directions are per-item arms, and
  "each declaring the version extension" is what arm 2 asserts.
- `item_create.py`: `exts` is a fresh list per call; `deprecated` is not `NGE_`-prefixed
  (`check_cog_tags` unaffected) and not in `REQUIRED_NGE_PROPERTIES` (`check_provenance`'s set
  equality unaffected). The real tree is CLEAN through `check_deprecated` in both modes.
- `--partial` is `store_true`, default `False`, one call site; `run_pipeline.sh`,
  `test_pipeline.R` and the full-release branch pass no flag.
- The `dep_state` search is the third `/search` of a full release, so it reads
  `FAKE_LIVE_IDS_AFTER` in the harness and the post-registration set in production —
  consistent with `after_ids`, which it is compared against indirectly.
- `limit: 1000` matches `fetch_live_ids`; a truncated page would drop a served marker and fail
  **loud**.
