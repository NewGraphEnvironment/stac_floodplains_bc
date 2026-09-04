# Code-check round 1 — #26 deprecation markers

Reviewed: `git diff main` (commit `733e0b7` + the staged/unstaged NEWS and PWF edits),
`scripts/item_create.py`, `scripts/item_validate.py` read in full,
`planning/active/findings.md`, and `scripts/catalogue_release.sh`.

Every claim below was reproduced against the tree, not reasoned from the code.

---

## Findings

### 1. **[bug]** `check_deprecated` refuses every `--only` release from a one-group tree

`scripts/item_validate.py:317-324`, called unconditionally at `scripts/item_validate.py:1472`.

The set-equality arm (`marked != EXPECTED_DEPRECATED`) and the literal-exists arm
(`EXPECTED_DEPRECATED - seen`) are **full-tree** assertions, but `item_validate.py` runs on
whatever `--base` holds. `catalogue_release.sh` documents the `--only` input as a partial
tree in two places — line 399 (*"`--only` republishes one item from a tree that may hold one
group, which cannot meet a full-tree floor"*) and line 256 (*"this build may hold one
group"*) — and gates `--expect-provenance` on exactly that. `check_deprecated` got no such
gate.

Reproduced on a two-file tree (`bulk_co_ff04.json` + `collection.json`):

```
PROBLEM: mcgr_ch_ff04: expected deprecated: true, not marked
PROBLEM: pine_bt_ff04: expected deprecated: true, not marked
PROBLEM: mcgr_ch_ff04: named in EXPECTED_DEPRECATED but absent from the build
PROBLEM: pine_bt_ff04: named in EXPECTED_DEPRECATED but absent from the build
```

That is `exit 1` at step 1 of `catalogue_release.sh`, before the sync — so the single-group
pilot path (#36, the one `catalogue_release-check.sh` exists to pin) is dead for any group
other than mcgr/pine. This is the mirror direction `code-check.md` names under "A guard that
fails toward pass": it refuses a correct release on correct input.

`catalogue_release-check.sh` cannot see it — its own header (line 65) says
*"item_validate.py is shimmed away (uv exits 0)"*.

Fix shape: scope the two full-tree arms to a full release. Either take the same flag the
floor takes (`--expect-provenance is not None` is already the "this is a full release"
signal in `main()`), or restrict them to ids the build actually contains:
`(EXPECTED_DEPRECATED & seen)` vs `marked`, plus `marked - EXPECTED_DEPRECATED` (which is
safe on a partial tree and is the arm that catches a marker that spread).

---

### 2. **[bug]** The self-clearing arm has no mirror — a stale item that is in *neither* literal ships unmarked, and the exact provenance floor cannot see it

`scripts/item_validate.py:307-315` asserts `marked ⇒ nge:flooded_version is None`
("deprecated means not-rebuilt"). Nothing asserts the converse
`nge:flooded_version is None ⇒ marked` — which is the direction #26 exists to prevent: an
over-mapped item published looking current.

The obvious objection is that `PROVENANCE_FLOOR=21` is **exact** and would catch it. It does
not, because an item with no provenance contributes **zero** to `traced`. Reproduced: a
synthetic 24th item copied from `mcgr_ch_ff04` with `deprecated` and the version extension
stripped:

```
check_deprecated -> []
check_provenance -> [] traced 21 seen 24
```

Both green. A build containing a group staged from an upstream tree with no
`provenance.json` — exactly how mcgr and pine got here — publishes over-mapped, unmarked,
with every gate passing and nothing on screen to prompt the operator, because the number
they compare against (21) has not moved.

The same hole opens if someone deletes an id from **both** `DEPRECATED_ITEMS` and
`EXPECTED_DEPRECATED` while the item is still stale.

This is closable without circularity, and the data already supports it. Measured on the
current build, `{id : nge:flooded_version is None}` is **exactly** `{mcgr_ch_ff04,
pine_bt_ff04}` — the literal and the data-derived set agree today, so the assertion costs
nothing to add and is not `x == x`: one side is a human's literal, the other is read from the
build. Asserting set equality both ways is what makes "deprecated HERE means not-rebuilt"
a biconditional rather than a one-way implication, which is what the docstring already
claims it encodes.

---

### 3. **[fragile]** The self-clearing arm's message offers only one remedy, and following it walks back through the guard

`scripts/item_validate.py:311-315`. The message is unconditional:

> *"delete it from DEPRECATED_ITEMS in item_create.py and EXPECTED_DEPRECATED here rather
> than publishing a corrected item labelled stale"*

The docstring (`:278-282`) honestly states the coupling — *"it would misfire on an item
deprecated for some other reason while carrying provenance"* — but the **message an operator
reads at 2am does not**. The day someone legitimately deprecates an item that has provenance
(a retired watershed group, a re-scoped scenario, an item superseded by a successor), the
guard fires correctly and then tells them to un-deprecate it. That is `code-check.md`'s
"a guard that fires correctly and then points at the wrong fix", and the check to apply is
*what would someone do on reading this*.

Cheap fix: add the second branch to the message — "if this deprecation is deliberate and
unrelated to #26, the marker/provenance coupling in `check_deprecated` is what needs
revisiting, not the item." One sentence, and it moves the stated boundary from the docstring
to where it is read.

---

### 4. **[fragile]** Nothing reads the marker back from the API — the one lesson #47 round 1 paid for is not carried over

`grep -n deprecat scripts/*.sh` returns **nothing**. Step 5 of `catalogue_release.sh` reads
`version`, `license`, the `rel: license` link and `sci:citation` back from the API *and* the
bucket, and the archived #47 README names why:

> *"Step 5 exists precisely because publishing a field is not serving it — and href
> rewriting through `urljoin` is the one thing pgstac does to a link it keeps."*

`deprecated: true` is a field whose **entire purpose** is that a consumer sees it — the
release note says so explicitly ("the API omits nulls, so absence alone is not a statement
and the marker is the positive one"). It is validated on disk and never once observed
downstream. CLAUDE.md's own measurement is that non-null values round-trip byte-for-byte, so
this is expected to pass — which is exactly the argument that was made for `license` before
it was measured and found to be a presence check, not a value check.

Two lines in step 5 (`curl $API/items/mcgr_ch_ff04 | jq '.properties.deprecated'` per marked
id, asserting `true`) closes it, and it is the only check in the whole path that observes the
feature from where the consumer stands.

---

### 5. **[fragile]** A published `deprecated: null` is accepted silently

`scripts/item_validate.py:295-306`. `flag = props.get("deprecated")` collapses *absent* and
*JSON null* into the same state, so an item carrying `"deprecated": null` with no version
extension passes all four arms. Not reachable from `item_create.py` today — but the guard's
own subject is that a published null is invisible from the API (CLAUDE.md, measured
2026-09-02 on #36), and this is the one place the distinction would matter. `"deprecated" in
props` beside the `is None` test separates the three states.

Same line: `props = doc.get("properties", {})` returns `None` for an explicit
`"properties": null` and raises `AttributeError` out of the function rather than reporting a
problem. pystac's validate runs first in `main()` and would reject it, so this is only
reachable when `check_deprecated` is called directly — low, but it is a traceback where every
sibling check returns a message.

---

### 6. **[fragile]** Three documentation surfaces enumerate the validator's checks and none mentions this one

- `scripts/README.md:28` — the Validate row lists what `item_validate.py` asserts.
- `scripts/README.md:59` — the step-1 row explicitly enumerates *"`check_collection_metadata`
  and `check_citation_premise` also run here"*. `check_deprecated` now runs there too and is
  absent.
- `CLAUDE.md` — has a paragraph for the provenance floor, the version stamp, the class
  labels, the styles and the licence. Nothing records that two items publish
  `deprecated: true`, that `DEPRECATED_ITEMS` is a hand-set literal of the same shape as
  `PROVENANCE_FLOOR`, or that the marker self-clears. A reader picking this repo up in six
  months learns it only from the code.

This is the same class round 3 of #47 caught ("three doc surfaces describing the premise
guard as checking one property of two"), one release later. Cheap, and this repo's
convention is that CLAUDE.md is the durable record.

---

### 7. **[bug]** The **staged** `NEWS.md` carries a false figure that the working tree has already fixed

`git status` is `MM NEWS.md`. The index holds:

```
NEWS.md:29: **18 items shrink by 5-33%**
```

The working tree holds the corrected `**Twelve items shrink, by 1.5% to 33.5%**` with the
per-item table. A plain `git commit` (no `-a`, no re-`git add`) ships the **index** version —
the false one — into the release note that a tag is cut on.

For the record, the staged figure is wrong in both halves, measured independently here from
`data/stac/*.json` against #26's published-km² column:

| claim | measured |
|---|---|
| 18 items shrink | **12** (six of the eighteen re-runs are 100% retained) |
| 5–33% | **1.5% – 33.5%** (`pcea` 1.5%, `kotl` 4.5% fall below the stated floor; `tabr` 33.5% above the ceiling) |

The working tree's table reproduces my computation row for row, so the fix is correct — it
just is not staged. **Re-stage `NEWS.md` before committing.**

---

### 8. **[fragile]** Residual NEWS claims that survive the fix

Verified against the tree; these are in the *working-tree* version:

- **`NEWS.md:22`** — *"this release replaces all of it"* is contradicted four lines later by
  *"Eight items are unchanged"* and by two items that are not replaced at all. The headline is
  the sentence a consumer takes away; it currently overstates by 8 of 20.
- **`NEWS.md:58`** — *"would have blocked 18 corrections indefinitely"* sits under a table
  that now says twelve. 18 is the re-run count, 12 is the correction count; the paragraph
  above defines the word one way and the bullet uses it the other.
- **`NEWS.md:20`** — the entry is dated `(2026-09-03)` while the preamble it sits under
  records a decision dated **2026-09-04** and `progress.md` logs `## Session 2026-09-04`. The
  release gate (`catalogue_release.sh:368`) matches `"## v$VERSION"` or `"## v$VERSION "*`,
  so the date is not checked — it is just wrong in a document whose whole job is to be the
  record.
- **`NEWS.md:13-18`** — the `v2.0.0` reservation is placed in the file **preamble**, above the
  first `## ` heading. That is correct for the release gate (it greps `-m1 -E '^## '`, which
  still finds `## v1.1.0`), but it means the note stays above every future entry, including
  above `v2.0.0` itself once cut. Consider a follow-up to retire it at that point.

**Verified correct**, so these need no action: `3.5926x` and the `ff04` 14.37x figure
(`flooded/NEWS.md` 0.5.0); "strict subset … 0 cells gained anywhere" (same source);
`PROVENANCE_FLOOR=21` (`catalogue_release.sh:60`); 23 local items; the three new groups are
all `region: fraser`; both marked items carry **zero** non-null `nge:` values while all 21
others carry `nge:flooded_version = "0.5.0"`; twelve `nge:` properties.

Also checked and clear: `flooded` **0.6.0** fixes a *second* silent units defect in
`fl_valley_confine()` (`field` defaulting to `channel_width`), but its NEWS states every
`floodplains` caller passed `area_field` explicitly — so items built on 0.5.0 are not
affected by it, and "rebuilt upstream on `flooded` >= 0.5.0" stands.

---

## Answers to the specific questions

**Q1 — can `check_deprecated` pass on input it should refuse?** Yes, one concrete input:
a 24th item with all-null `nge:` properties, no `deprecated`, and no version extension —
reproduced above, both `check_deprecated` and `check_provenance(floor=21)` return `[]`
(finding 2). `deprecated: null` with no extension is a second, unreachable-today one
(finding 5). Non-bool `deprecated` is handled correctly: `flag is not True` reports it *and*
withholds it from `marked`, so the set compare fires too. An id colliding with the collection
is not reachable — the `type != "Feature"` skip runs first. `properties` missing is safe
(`{}` default); `properties: null` raises rather than reports.

**Q2 — is the self-clearing arm correct in both directions?** No. It is a one-way implication
(finding 2) and its remedy assumes the only reason to deprecate is #26 (finding 3). The
misfire case *is* stated — in the docstring, not in the message the operator acts on.

**Q3 — is the placement right?** Yes, and nothing meaningful short-circuits it. Upstream of
it in `main()` sit the pystac-validate loop, the item-count check, the collection-count check
and `check_citation_premise` — all document-level, none touching the 670 MB re-read, so a
restore-the-bug proof for this guard genuinely reaches it. The one thing to know is that
`items != expected` (line 1445) does short-circuit, so a mutation that also changes the item
count would fire the count check instead — which is why the harness's grep-for-the-message
discipline matters here too.

**Q4 — NEWS factual claims.** See findings 7 and 8. The staged figure is false and measured
so; the working-tree figure is correct and matches my independent computation exactly.

**Q5 — failing toward pass / silent success elsewhere in the diff.** Findings 2, 4 and 5.
The `item_create.py` side is clean: `exts` is a fresh list per call, `properties["deprecated"]`
is set after the `nge:` update with no key collision, `deprecated` is not `NGE_`-prefixed so
`check_cog_tags` is unaffected, and it is not in `REQUIRED_NGE_PROPERTIES` so
`check_provenance`'s set equality is unaffected. The printed summary line
(`item_validate.py:1478-1480`) claims exactly what the code checks — set equality, the
extension declared, and no `nge:flooded_version` — with no overclaim.

---

## Priority

Blocking for the release: **1** (breaks `--only`), **7** (a false number in a tagged release
note). Fix before merge: **2**, **3**. Fix before or with the release: **4**. Housekeeping:
**5**, **6**, **8**.
