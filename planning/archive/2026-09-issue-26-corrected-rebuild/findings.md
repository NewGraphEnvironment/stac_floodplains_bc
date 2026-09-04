# Findings — Published items are over-mapped (#26)

## Measured before planning (2026-09-03/04)

| fact | how |
|---|---|
| local build 23 items, live 20, **0 orphans**, 3 new (`thom`/`lnth`/`unth`) | `POST /search` vs `data/stac/*.json` |
| 21 of 23 carry a non-null `nge:` value | sweep of item properties |
| exactly `mcgr_ch_ff04` + `pine_bt_ff04` carry **zero** non-null `nge:` values | same sweep |
| `nge:flooded_version` is `0.5.0` on 21, null on those same 2 | same sweep |
| all 23 items declare exactly 3 `stac_extensions` | same sweep |
| no `PARTIAL_STAGE` marker; `data/raw` holds 23 group dirs | `ls` |

So the corrected rebuild the issue asks for **already exists on disk** — this issue's
remaining work is the deprecation markers and the release, not a re-stage.

## The version decision was never written down

`v1.1.0` now; `v2.0.0` reserved for the release where *every* area is corrected, and
`mcgr`/`pine` cannot be (floodplains#76). Decided by airvine 2026-09-04.

Searched before asking, and it is worth recording that the search came back empty: #26's
body, #19 (versioned releases), all 24 issues and their comments, every archived PWF, and
the `published-assets-stale-vs-main` memory all record the **23-items / floor-21 /
deprecated-markers** decisions and **none** of them records a version number. The user had
to recall it. Phase 4 writes it into `NEWS.md`'s header, which is where the next person
looks.

Same class as the issue-body drift `newgraph.md` warns about, one level out: a decision made
in conversation and never landed in a file is indistinguishable from a decision never made.

## Why a positive marker, when the two already differ

Neither `mcgr` nor `pine` has an upstream `provenance.json`, so both publish null on all
twelve `nge:` properties while every rebuilt group carries `nge:flooded_version = "0.5.0"`.
That separates them in the build — but **the API drops nulls** (#31/#36, measured
2026-09-02), so a consumer sees only that two items *lack* a field, and absence is not a
statement.

`deprecated: true` from the Version Extension is the positive statement. Note the asymmetry
that makes this sound: the extension defines `deprecated` with `default: false`, so for the
other 21 items **absence is** a statement, backed by the spec — unlike the `nge:` nulls,
where it is not.

## The extension cannot enforce the field

`version/v1.2.0`, Item branch: `properties: {"$ref": "#/definitions/fields"}` with **no
`required`**. `fields` declares `version`, `deprecated`, `experimental`, all optional. So an
item declaring the extension with no `deprecated` validates clean — the #34/#35 trap again,
and the reason every assertion in Phase 2 is absolute and hardcoded rather than derived.

## The pgstac link premise, answered by the release

#47 published `rel: license` and `rel: derived_from` on the strength of reading
stac-fastapi-pgstac's `INFERRED_LINK_RELS` — and recorded, explicitly, that this was **not**
measured against `images.a11s.one`, because no collection there published such a link. The
v1.1.0 release settles it. The API now serves:

```
link rels: ['derived_from', 'queryables', 'items', 'license', 'parent', 'root', 'self']
```

Both survive. The reasoning was right, and it is now a measurement rather than a source read.
Step 5 is what would have caught the other outcome — after the sync and the pgstac load, which
is the cost that was named at the time and accepted.

## Release outcome — v1.1.0

Every step-5 assertion passed on the first run: version, licence, both link hrefs,
`sci:citation`, and the deprecation markers, on the API **and** the bucket copy. Confirmed
afterwards from the API rather than from the release's own output:

| | |
|---|---|
| items served | 23 |
| `version` / `license` | `1.1.0` / `CC-BY-4.0` |
| `providers` | 6 |
| `deprecated: true` | exactly `mcgr_ch_ff04`, `pine_bt_ff04` |
| `tabr_ch_ff04` ff04 | **154.63 km²**, was 232.69 |

The tag was pushed only after the release succeeded, per the recipe: a pushed tag asserts the
catalogue is in that state, and a failed release would have left a public tag for a state that
never went live.

## Code-check round 3 — the same mechanism, one arm over

Round 3's headline finding is round 2's own fix recurring on its mirror. Round 2 taught me that
an arm naming an id the tree **contains** is subset-safe, and I applied that to
`marked - EXPECTED_DEPRECATED` and not to `EXPECTED_DEPRECATED - marked`, whose
`& seen` half is safe by identical reasoning.

Reproduced: a subset tree holding `mcgr_ch_ff04` present, rebuilt and unmarked is **CLEAN**
under `--partial` and refused without it. That is precisely the documented future flow — mcgr is
rebuilt, someone deletes it from `item_create.py`'s literal and not from `item_validate.py`'s —
and `--only` is the path an operator would use for a single-item republish. Step 5's read-back
sits inside `if [ -z "$ONLY" ]`, so nothing downstream would have caught it either.

| finding | verdict | action |
|---|---|---|
| `--partial` disabled `EXPECTED_DEPRECATED - marked` entirely | **real, reproduced** | split on `& seen`; only "named in the literal, absent from the tree" is now dropped. Also removed a duplicate message on full releases |
| three doc surfaces said `--partial` drops "the arms asking about absent ids" — plural, and one of them did not | real | all three say "exactly one arm" and are now true |
| `served &= built_ids` had **zero** coverage — deleting it left the harness green | real | case **9m**: retract the marked fixture item under `--allow-retract` |
| the comment justifying that intersection said orphans are "already the id comparison's business" — but that comparison gates its message *and* `fail=1` on `[ -z "$ALLOW_RETRACT" ]` | real | comment now states the cost out loud: a retracted marked item is reported by nothing, so retracting one wants an explicit `item_unregister.sh` |
| `fv is not None` was a proxy — `nge:flooded_version = "0.4.0"` passes unmarked | real | `_corrected()` compares against `MIN_FLOODED_VERSION = (0, 5, 0)`. Enumerated: `0.4.0`, `0.4.9`, null, `unknown` and `5` all refuse unmarked; `0.5.0`, `0.6.1`, `1.0.0` pass |
| the `\|` delimiter comment cited a line that validates `$ONLY`, not item ids | real | cites what actually constrains ids |

Nothing dismissed.

### Where the guard now stands, enumerated

Seven arms. Six name an id the tree contains and run on any tree; one asks about ids absent from
the tree and is the only thing `--partial` drops:

| arm | subset-safe | runs under `--partial` |
|---|---|---|
| `deprecated` present and not `true` | yes | yes |
| extension declared iff `deprecated` present | yes | yes |
| marked ⇒ not corrected (self-clear) | yes | yes |
| not marked ⇒ corrected (converse) | yes | yes |
| `marked - EXPECTED_DEPRECATED` | yes | yes |
| `(EXPECTED_DEPRECATED & seen) - marked` | yes | yes |
| `EXPECTED_DEPRECATED - seen` | **no** — asks about absent ids | no |

That partition is the thing to check when an arm is added, and it is what the previous two
rounds each got wrong in one direction.

## Code-check round 2 — two bugs inside round 1's fixes, and a false claim to consumers

| finding | verdict | action |
|---|---|---|
| `--partial` dropped `marked - EXPECTED_DEPRECATED` too, though that arm names only ids the tree contains | **real, reproduced** | moved above the early return. A marker on an item outside the literal now fails under `--only` as well — letting it through would upsert a permanent false "stale" claim, the direction with no rollback |
| NEWS told consumers `file:checksum` distinguishes replaced data — **false for this release** | **real, measured** | replaced with what actually discriminates |
| thirteen items changed, not twelve; seven unchanged, not eight | **real** | `necr_ch_ff04` moves 396.52 → 396.51. My "corrected" figure still came from a 0.05% tolerance rather than an exact compare |
| the converse arm's first remedy was the harmful one | real, fragile | message now says explicitly: do not mark it merely to clear this — fix the provenance |
| the deprecation read-back was `NONE == NONE` in the harness with no reachable negative case | real, fragile | shim echoes `properties.deprecated`, one fixture item marked, cases **9k/9l** added (both directions) |
| `built_dep` had no `\|\|` guard — a failure aborts mid-verify with no verdict printed | real, fragile | guarded like every other read in step 5 |
| under `--allow-retract` a dropped marked item stays live and would report RELEASE INCOMPLETE after the sync | real, fragile | served set reconciled against the build's ids; orphans stay the id comparison's business |
| three doc surfaces described `--partial` as dropping only unreachable arms | real, fragile | all corrected |

Nothing dismissed.

### The checksum claim is the one that mattered

`file:checksum` was published in #22 precisely so a consumer could tell replaced bytes from
unchanged ones, and the v1.0.0 notes lean on it. Measured across five items — three whose
geometry is identical and two whose geometry changed — **7 of 7 assets have a new checksum on
every one of them**. The RAT, tag and COG rewrites (#33/#34/#35) touch every byte, so checksum
movement says "your bytes are stale", which is what it is for, and cannot say "the geometry
changed".

The release note now says so, and points at the two things that do answer: the item's own
`floodplain_ff0*_km2` against the published table, and `nge:flooded_version`.

This is the third factual error caught in this one release note — 18→12→13 items, 5-33%→1.5-33.5%,
and the checksum discriminator. Every one came from restating a prior document rather than
measuring: the issue's summary line, then my own corrected-but-still-tolerant comparison, then
#22's design intent. **A release note is the one document a consumer reads to decide whether
their cached figures are still good; every number in it wants deriving from the artefact.**

## The deprecation guard's full state space, enumerated

Not reasoned — each row run through `check_deprecated` against a one-item fixture, so the
claim "no silent pass" is a measurement:

| `deprecated` | `nge:flooded_version` | verdict |
|---|---|---|
| absent | `0.5.0` | **pass** — rebuilt and unmarked, the normal case |
| absent | null | refused (converse arm: over-mapped but unmarked) |
| `true` | `0.5.0` | refused (self-clear: marked but rebuilt) |
| `true` | null | **pass** — marked and not rebuilt, the two known items |
| `false` | either | refused — the extension's default says nothing, and publishing it on some items makes absence ambiguous |
| `null` | either | refused — the API would drop it, so it reads as absent to every consumer |

Two passing states, both correct. Enumerating the space is what makes "closed" a measurement
rather than a claim, per `code-check.md` on convergence — the same discipline that closed the
`licence_of` class on the previous PR.

## Code-check round 1 — three real bugs, one of them in the release note itself

| finding | verdict | action |
|---|---|---|
| `check_deprecated`'s whole-catalogue arms ran on every invocation, so `--only` refused any one-group tree | **real, reproduced** | `--partial` flag; the release passes it under `--only`. Default stays strict, so a forgotten flag refuses rather than waves through |
| the self-clear was one-way (`marked -> not rebuilt`); nothing enforced the converse | **real, reproduced** | both directions. An unmarked over-mapped item adds **zero** to the provenance floor's count, so an exact floor of 21 is satisfied by 21 provenanced items whatever ships beside them — the floor could never have caught it |
| `NEWS.md`'s **index** held the false "18 items shrink by 5-33%" while the worktree held the correction | **real** | re-staged. A plain commit would have put the false figure in the release note a tag is cut on |
| the self-clear message's only remedy was "un-deprecate it" | real, fragile | message now names both paths, including "this guard is the wrong one and needs widening, not silencing" |
| `deprecated` was never read back from the API | real, fragile | step 5 compares the served marked-set against the built one — the field's entire purpose is that a consumer sees it |
| `props.get("deprecated")` collapsed absent and JSON null; `doc.get("properties", {})` raised on `"properties": null` | real, fragile | `_ABSENT` sentinel and `or {}`. Proved: `deprecated: null` is reported, `properties: null` no longer raises |
| `scripts/README.md` and `CLAUDE.md` did not mention `check_deprecated` | real, fragile | both updated |
| NEWS said "replaces all of it" four lines above "Eight items are unchanged" | real | reworded to "every item it can" |

Nothing was dismissed as a false positive.

### The `--only` bug is the one worth remembering

It is a guard whose *scope* was a coincidence. Every arm was written against the full-catalogue
tree the release normally validates, and three of the five happen to hold on any subset. The
two that do not — the set compare and the literal's own ids — silently redefined `--only` as
"works for the two deprecated items only". `catalogue_release-check.sh` could not see it: its
own header says `uv` is shimmed, so `item_validate.py` never runs there.

Proved both ways rather than reasoned: a one-group `bulk_co_ff04` tree returns 4 problems
without the flag and CLEAN with it.

### And the converse arm is the one the floor could not cover

`PROVENANCE_FLOOR=21` is exact in both directions, which reads as though it pins the whole
shape — but an item carrying **no** provenance contributes 0 to the count. Adding a 24th
over-mapped, unmarked item leaves the floor satisfied at exactly 21 and every other guard
green. Reproduced with a copied item; now refused.

## A figure in the release notes was wrong
, and it came from the issue's own summary

The first draft of the v1.1.0 entry said **"18 items shrink by 5-33%"**. Both numbers were
wrong. Measured 2026-09-03, each item's own `floodplain_ff0*_km2` on the live API against the
same property in this build:

- **12** items change, not 18. The "18" is the count of upstream *re-runs*, which is a
  different quantity — six of those were already correct in the live catalogue, so re-running
  them moved nothing.
- The shrink range is **1.5% to 33.5%**, not 5-33%. `pcea_bt_ff04` shrinks 1.5% and
  `tabr_ch_ff04` 33.5%.

The bad figure has a lineage worth recording: it is the issue body's own summary sentence
("over-mapped by 5-33%"), which was copied into the `published-assets-stale-vs-main` memory,
and from there into the release notes — three documents agreeing, none of them a measurement.
That is the "documents that share an ancestor corroborate nothing" trap exactly, and the
issue's *own per-item table* disagreed with its summary line the whole time.

Caught by re-deriving every claim in the entry from the artefacts before a reviewer saw it. A
false number in a release note is not cosmetic: it is the one document a consumer reads to
decide whether their cached figures are still good.

The corrected entry ships the per-item table rather than a range, which is what the issue asked
for — "record before/after area per item so the change is auditable rather than silent".

## Restore-the-bug results — 7 of 7

Each mutation applied to the **source** (`item_create.py`, `item_validate.py`, or
`meta.json`), rebuilt where relevant, then validated, with the output grepped for **that
guard's own message** — never the exit status.

| mutation | message matched |
|---|---|
| `DEPRECATED_ITEMS = set()` | `mcgr_ch_ff04: expected deprecated: true, not marked` |
| a third id added to the builder's literal | `bulk_co_ff04: marked deprecated but not in the expected set` |
| a nonexistent id added to `EXPECTED_DEPRECATED` | `gone_xx_ff04: named in EXPECTED_DEPRECATED but absent from the build` |
| `deprecated` set, `VERSION_EXT` not appended | `version extension half-applied — extension absent, deprecated present` |
| `VERSION_EXT` appended, `deprecated` not set | `version extension half-applied — extension declared, deprecated absent` |
| `deprecated = False` published | `deprecated is False — publish true or omit it` |
| `meta.json` gives MCGR `flooded_version 0.5.0` | `marked deprecated but carries nge:flooded_version '0.5.0'` — **the self-clear** |

### The one that came back WRONG GUARD, and why the proof was at fault

Case 3's first form added `gone_xx_ff04` to **`item_create.py`**'s `DEPRECATED_ITEMS` and
reported `*** WRONG GUARD (rc=0)` — the validator passed outright.

Correct behaviour, wrong proof. The "id exists in the build" arm is about the **validator's**
`EXPECTED_DEPRECATED`. A nonexistent id in the builder's copy marks no item, so `marked` is
unchanged, the set compare passes, and there is nothing to catch. Retargeted to the literal
the guard is actually about.

**What that leaves genuinely uncovered, stated rather than papered over:** a nonexistent id in
`DEPRECATED_ITEMS` *alone* is dead config — it publishes nothing and no guard sees it. Every
drift that reaches the published output is caught:

| drift | caught by |
|---|---|
| id in builder only, and an item exists | `marked - EXPECTED_DEPRECATED` |
| id in validator only | `EXPECTED_DEPRECATED - marked` |
| id in both, no such item | `EXPECTED_DEPRECATED - seen` |
| id in builder only, no such item | **nothing** — marks nothing, harmless |

Only the last is uncovered, and it cannot change a published byte. Recorded because "the guard
does not cover this" is worth writing down when it is a deliberate boundary rather than a gap
nobody noticed — and because rc=0 on a restored bug is exactly the shape that reads as a pass.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| The proof harness left `data/stac` polluted. `restore()` writes `meta.json` back but does **not** rebuild, so after the last case `mcgr_ch_ff04.json` still carried the mutated `nge:flooded_version 0.5.0`. Surfaced only because the next run's output named it. | Rebuild after the harness, always. The release path was never at risk — `check_deprecated`'s self-clearing arm refuses exactly that state, so a release from the polluted tree would have failed the gate rather than published. But the guard caught it *as a defect* when it was an artefact, which is the confusing direction. A harness that mutates inputs must restore the **outputs** too, or say out loud that it does not. |
| A restored bug reported `*** WRONG GUARD (rc=0)` — the validator passed | The proof mutated `item_create.py`'s literal where the guard is about `item_validate.py`'s. See above; the guard was right and the proof was wrong. `rc=0` on a restored bug is the shape that reads as a pass, which is why each case greps for its own message. |
