# Review round 3 — #74 (the mechanism)

Reviewed `844ba81...HEAD` on `74-move-the-nge-item-fields-to-standard-or`. Working tree clean
before and after; every mutation below was made in a copy of `scripts/` under the scratchpad
and deleted afterwards.

Drivers re-run as the baseline (all from the unmodified tree):

```
uv run python scripts/prov_fields-check.py      44 assertions, 0 failed
uv run python scripts/year_sets-check.py        16 assertions, 0 failed
uv run python scripts/attribution_drift-check.py  ATTRIBUTION.md matches item_create.py
bash scripts/catalogue_release-check.sh         ALL PASS
```

---

## The mechanism

Of the thirteen findings in rounds 1 and 2, **six were one shape: a comment, a message or a
printed line asserting a property the code does not have** — r1#3 (`01_stage.R` still asserting
the retired null contract), r1#5 (the fixture comment stating a false fact about
`update_tags(None)`), r1#6 (`PROV_CENSUS`' comment pointing at numbers nothing printed), r2#3
(two comments claiming the publish map is the only place the old names survive), r2#4
(`PROV_FIELDS`' comment saying "derived"), r2#5 (a message naming one of two remedies). A
further three were the same shape in a sharper form: **the prose IS program input** — r2#1 (a
markdown span ran as a command substitution), the defect inside r2's own fix (a quoted phrase
truncated the program), and r2#2 (an assertion whose needle matched output printed before the
branch it named). Two were the copies-and-joins shape (r1#1, r2#6). Two were ordering/scope.

So the mechanism is not "N copies pairwise joined" — that one was *found* and closed. It is:

> **This branch's load-bearing invariants are stated in prose that sits beside the code but is
> not derived from it, and in one place that prose is itself parsed by bash. The only
> mechanical join between prose and code added in round 2 is an enumeration asserted to be
> complete — and it is not.**

That last clause is this round's finding: `prov_fields-check.py:293-304` claims "every character
bash still expands inside double quotes is listed here, and every `$` must be one of the three
interpolations the program is written to receive". It lists three characters and then matches
`$` only when followed by an identifier. `$(…)` — command substitution, the *same* defect as
the backtick that already shipped — matches neither arm. Proven below.

### Every place the mechanism reaches, and whether it sits above or below its source

**Program text inside a shell-expanded string** (one site, and it is the dangerous one):

| site | verdict |
|---|---|
| `catalogue_release.sh:291-345` — the `--only` preflight program, the argument of a double-quoted `python3 -c` | **ABOVE its source.** The guard that is supposed to pin it misses `$(…)`, `$1`…`$9`, `$?`, `$$`, `$#`, `$@`, `$*`, `$!` — see finding 1 |

**Copies of the twelve staged names and their nine published destinations** — enumerated, with
the join that pins each:

| # | copy | joined to | by | verdict |
|---|---|---|---|---|
| 1 | `fp_provenance.R` (upstream leaves) | 2 | `stopifnot`, every stage run | below |
| 2 | `01_stage.R:52-69` `PROV_FIELDS` | 1, 3, 4, 7 | 1 stopifnot; 3/4 `meta[f]` KeyError (one-way, subset only); 7 set equality | below |
| 3 | `02_raster_tag.py:91` `PROV_FIELDS` | 5 | `prov_fields-check.py:303`, static set equality | below |
| 4 | `item_create.py:186-220` map + list | 5 | `prov_fields-check.py:300`, static full equality | below |
| 5 | `item_validate.py:458-485` the contract | 3, 4, 6 | the three static arms above | below |
| 6 | `catalogue_release.sh:295-307` `NEW`/`SOFTWARE`/`PREFIXES` | 5 | `prov_fields-check.py:307-315` (added round 2) | below |
| 7 | `test_pipeline.R:160-172` `prov_map`/`prov_software`/`meta_core` | 2 and the published item | two set equalities, both directions, at run time | below |
| 8 | `item_create.py:634` bare `"link:run_uid"` | **nothing** | — | **ABOVE** — finding 4 |
| 9 | `prov_fields-check.py:82-126` `STAGED` + `publish()` | 4 for the map | static; the writer's half-pair `raise` is deliberately unmirrored (the honest 0-red row) | below, with a named gap |
| 10 | `NEWS.md` table / `CLAUDE.md` / `scripts/README.md` | nothing | — | **ABOVE** — findings 2, 3 |

Order is not part of the contract anywhere that matters: both `NGE_PROVENANCE_NULL` producers
(`02_raster_tag.py:131`, `item_validate.py:894`) `sorted()`, so the set-equality join at
`prov_fields-check.py:303` is sufficient. The `item_create.py` comment that claims otherwise is
finding 5.

**Assertions whose needle could match earlier output** — re-walked all of the new ones in
`catalogue_release-check.sh`. Case 12's was fixed in round 2 and is now a count of two
*absences*; cases 15/16/17's needles (`carries provenance this build does not:`,
`A renamed or re-shaped provenance contract is a FULL-release change`,
`provenance gained since the bucket copy:`) are each printed by exactly one branch and nowhere
earlier. No further instance. Case 17 additionally asserts the absence of the case-16 message.
Clean.

**Fixtures that cannot reach the failure mode they name** — re-walked. `tags_drop` pops the key
(r1#5's fix); `catalogue()` carries all three live populations including the all-absent one;
case 16's `nge` bucket shim rewrites real declared names, not synthetic ones (r2's fixture fix).
One residual, named honestly in `findings.md`: `publish()` mirrors the writer rather than
importing it, so mutating `item_create.py`'s half-pair `raise` turns nothing red. The backstop
(`check_processing_stamp`'s `<version>+<sha>` arm) is proven, so this is a documented gap, not a
hole. No new instance.

---

## Findings

### 1. **[bug]** `scripts/prov_fields-check.py:293-304` — the enumeration that closed the shell-expansion class misses command substitution, so a `$(…)` in the preflight program passes both drivers and runs on every `--only` preflight

The hazard list enumerates `` ` ``, `"` and `\`. The `$` arm is
`re.findall(r"\$\{?([A-Za-z_][A-Za-z_0-9]*)", _body)`, which matches `$NAME` and `${NAME}` only.
Measured:

```
'$(date)' -> []      '$1' -> []      '$?' -> []      '$$' -> []
'$STAC_DIR' -> ['STAC_DIR']          '${ONLY}' -> ['ONLY']
```

`$(` is a command substitution bash performs inside double quotes — the identical mechanism to
the backtick that already ran on every preflight (r2#1). The comment above the block says "every
character bash still expands inside double quotes is listed here, and every `$` must be one of
the three interpolations", which is the claim the regex does not support.

Reproduced end to end. In a copy of `scripts/`, one line added to the preflight program body:

```python
MARKER = '$(touch /tmp/PWNED_MARKER)'
```

Result:

```
uv run python scripts/prov_fields-check.py   ->  44 assertions, 0 failed
  ok    the preflight program survives bash: no backtick, quote or stray $
bash scripts/catalogue_release-check.sh      ->  ALL PASS
ls -l /tmp/PWNED_MARKER                      ->  -rw-r--r--  0  (bash created it)
```

Both guards green and bash ran the command. (`$1` is partly covered by accident — `set -u` makes
it an unbound-variable error, and a separate run with `POS = '$1'` added turned
`catalogue_release-check.sh` red with 28 failures. `$(…)` has no such accidental backstop, and
neither does `$?`/`$$`/`$#`/`$@`/`$*`, which expand to a value rather than erroring.)

Fix: add `"$("` to the literal hazard tuple, and make the `$` arm a subtraction rather than a
match — scan every `$` and require each to begin one of the three allowed `${?NAME}` forms, e.g.

```python
for m in re.finditer(r"\$", _body):
    if not re.match(r"\$\{?(STAC_DIR|ONLY|only_bucket)\}?", _body[m.start():]):
        _hazards.append(f"a bash expansion at offset {m.start()}: {_body[m.start():m.start()+12]!r}")
```

That is the form the enumeration claims to have. The present one is an allowlist of three names
layered over a pattern that cannot see the expansion forms that have no name.

### 2. **[fragile]** `CLAUDE.md:145-147` — "the only thing joining those three" is stale after round 2's own fix

> "…statically compares the publish map in `item_create.py` and the field list in
> `02_raster_tag.py` against the validator's copies, which is the only thing joining those
> three."

`prov_fields-check.py` now parses **three** files and pins **four** copies: it also slices
`catalogue_release.sh`'s preflight and compares `NEW`, `SOFTWARE` and `PREFIXES`
(`prov_fields-check.py:307-315`). Round 2's own commit message says so ("The same slice pins the
FIFTH copy of the publish map"), and r2#6's fix note records that the docs said "the only thing
joining those three" — but CLAUDE.md:145-147 was not among the lines that commit edited (it
touched CLAUDE.md:114-118 only). A reader counting copies from CLAUDE.md gets the pre-round-2
number, which is the number that let the fifth copy go unpinned in the first place.

### 3. **[fragile]** `scripts/README.md:232-236` — same claim, same staleness

> "It also parses `item_create.py` and `02_raster_tag.py` and compares their literals against
> the validator's: the three copies are deliberately not shared…"

It parses `catalogue_release.sh` too, and there are four copies on the publish side. Also
`prov_fields-check.py:222` ("The three copies of the field list…") contradicts
`prov_fields-check.py:281` ("The fifth copy…") inside one file; :281 is the correct one.

### 4. **[fragile]** `scripts/item_create.py:634` — a sixth copy of a published key name, as a bare literal, joined to nothing

```python
_untraceable = [i.id for i in items if "link:run_uid" not in i.properties]
```

Every other reference to that key in the build goes through `PROV_PROPERTIES`. If the published
name of `link_run_uid` ever moves, this print silently reports `0/23 traceable` — a progress
signal that reads as a total upstream loss — and nothing fires, because
`prov_fields-check.py` compares `PROV_PROPERTIES` and `PROV_SOFTWARE` but never scans for bare
published-key literals. One character: `PROV_PROPERTIES["link_run_uid"] not in i.properties`
(the `meta[f]`-style KeyError then makes a renamed staged field loud too).

### 5. **[fragile]** `scripts/item_create.py:215-218` — the stated reason for writing `PROV_FIELDS` out as a list does not hold in that file

> "Written out rather than derived from the map, because the ORDER is what
> `NGE_PROVENANCE_NULL` and every printed list read in, and a set has none."

In `item_create.py`, `PROV_FIELDS` is used **only** by the module-level `assert` on the next
line, which compares `set(PROV_FIELDS)`. `NGE_PROVENANCE_NULL` is `02_raster_tag.py`'s, and it is
built with `sorted()` (`02_raster_tag.py:131`), as is the validator's expectation
(`item_validate.py:894`). No printed list in `item_create.py` reads `PROV_FIELDS` either. So the
order this comment declares load-bearing is unobserved here, and a future edit that preserves
the order instead of the set is preserving the wrong invariant. Same class as r2#4.

### 6. **[fragile]** `scripts/item_validate.py:536-538` — the census comment's claim about what the other two scripts print is false for one row

> "01_stage.R and item_create.py print only the ITEM-level count, which is the floor, so neither
> of them answers this."

`item_create.py:636-637` also prints `link run traceable (link:run_uid): N/M`, which is exactly
the census row for `link_run_uid` — the one row that is not 21. Minor, but this is the comment
r1#6 was already a finding against, and the replacement sentence introduced a new unchecked
claim about a sibling script.

### 7. **[fragile]** `planning/active/findings.md:111` — "43 assertions, 0 failed" is 44 today

Measured just now on the unmodified tree: `44 assertions, 0 failed`. The arithmetic in the
parenthesis (`38 + 2 + 3 = 43`) does not reconcile with the file. The mutation table below it is
labelled "re-measured 2026-10-13 after round 2", so a reader takes the count as current.

---

## The three concrete checks

### 1. NEWS.md / CLAUDE.md / scripts/README.md / ATTRIBUTION.md against the code

Verified true:

- NEWS' twelve-row rename table against `item_create.py:186-220` — exact, including both halves
  of the `link` entry and the "split on the LAST `+`" note (`rpartition("+")` at
  `item_validate.py:775`).
- "Twelve fields, nine published keys" — `PROV_KEYS = set(PROV_PROPERTIES.values()) |
  {SOFTWARE_PROPERTY}` is 9; `PROV_FIELDS` is 12; both asserted module-level in two files.
- "items list it in `stac_extensions`" / "`mcgr_ch_ff04` and `pine_bt_ff04` … do not declare the
  processing extension" — `item_create.py:533-534`, conditional on `any(k.startswith
  ("processing:"))`. I validated both published shapes with pystac against the live schemas:
  the full shape and the deprecated/no-processing shape both pass.
- "The GDAL tags inside each COG keep their names" — `02_raster_tag.py:91-102` unchanged in the
  diff except comments; `prov_fields-check.py:303` pins the set.
- "`NGE_PROVENANCE_NULL` — a comma-separated list of the fields that had no value… on
  `larl`/`kotl`/`sloc` that is `link_run_uid`" — consistent with
  `PROV_CENSUS["link_run_uid"] == 18` over 23 items minus the two all-absent ones.
- `ATTRIBUTION.md:26-28` — "the `landcover:*` provenance block, which the release's per-field
  census (#74) is what keeps present": both the floor and the census are asserted on a full
  release (`item_validate.py:697-719`), and `attribution_drift-check.py` still passes.
- CLAUDE.md:114-118 — "`canon()` in `catalogue_release.sh` is the one other reader that still
  knows the retired prefix". Confirmed by `git grep -n "nge:"` over `scripts/`: every other hit
  is a comment, a refusal fixture, or `FIELD_PREFIXES` not containing `nge`. `README.md`,
  `README.Rmd` and `styles/` carry zero hits.
- CLAUDE.md:281 — "One trap in this script, so there is nothing for a second one to replace":
  `grep -n 'trap ' scripts/catalogue_release.sh` returns exactly one.

False or stale: findings 2, 3, 6 above. One phrasing worth watching but not reported as a
finding: NEWS' "**API consumers see no change**" is true only of the null→absent change it sits
under; the section opener already says a filter naming an old property stops matching, so the
scope reads correctly in place.

### 2. The release path end to end for the first renamed FULL release (23 items)

Walked `catalogue_release.sh` start to finish. Nothing in it assumes the old shape, and the two
expectations are jointly satisfiable:

- **Step 0.** The orphan comparison is by id only. `PROVENANCE_FLOOR=21` is carried as a comment
  edit only (`:45`). The `--only` arms are skipped. Note the intended consequence, which is
  correct: the shape arm (`:363-371`) will **refuse every `--only` release until the first full
  renamed release has run**, because each bucket copy still holds twelve `nge:` keys. That is the
  documented ordering, and `catalogue_release-check.sh` case 16 pins it.
- **Version gate / stamp.** `collection_version.py` adds `version` (no colon) and `VERSION_EXT`.
  `check_version_stamp` and `check_field_prefixes` both handle the stamped document — `version`
  carries no colon so the prefix table never sees it, and `sci:citation` is the collection's only
  namespaced top-level field with `SCIENTIFIC_EXT` declared.
- **Step 1.** `--expect "$n_local"` = 23, `--expect-provenance 21`. `check_provenance`'s FLOOR arm
  wants `traced == 21`; its CENSUS arm wants `link_run_uid == 18` and the other eleven `== 21`.
  Both describe the same population — 21 items carry provenance, three of them without
  `link_run_uid` — so they are consistent, not competing, and `prov_fields-check.py`'s control
  demonstrates exactly that tree passing (`traced=21 seen=23`, `census == PROV_CENSUS`).
  `check_deprecated` is also satisfiable: 21 unmarked items each carry `flooded` 0.5.0 and the two
  marked ones carry no `flooded` entry.
  One structural redundancy, not a defect: `census["link_sha"]` and `census["link_version"]` are
  equal by construction (`prov_present` gives both fields the one entry string), and
  `item_create.py:495-505` raises on a half-present pair, so the census cannot distinguish those
  two rows. The `<version>+<sha>` arm at `item_validate.py:774-781` is what covers the gap.
- **Step 5.** The full-release read-back reads `license`, `sci:citation`, both link hrefs, the
  collection `version` (API and bucket) and the `deprecated` markers. **It does not read any
  renamed property back from the API** — the per-item `live_state` compare is inside
  `if [ -n "$ONLY" ]` (`:656`). So the first release to publish nine new property keys verifies
  none of them on the wire. This is pre-existing shape rather than something the branch broke,
  and CLAUDE.md does not overclaim it (it scopes step 5's read-back to the licence block and the
  version). Flagging it as the one gap a reader should know about before cutting that tag: a
  cheap `--only` run on any already-renamed item afterwards exercises the full property compare.

### 3. `check_field_prefixes` against the real documents

**There is no build on disk** — `data/stac` holds one asset directory (`ufra_ch_ff04/`) and zero
`*.json`, so I could not run the check over real items and did not guess from a stale one. What I
did instead:

- Enumerated every namespaced field the build writes: item properties `proj:epsg`, `proj:bbox`,
  `proj:shape`, `proj:transform` (`item_create.py:466-469`) plus the nine provenance keys; per
  asset `file:checksum`, `file:size` (`:336`) and `classification:classes` (`:387`, `:405`);
  collection top-level `sci:citation` (`:684`). Every prefix is in `FIELD_PREFIXES`, and every
  prefix with a schema has that schema in the item's or collection's `stac_extensions`
  (`PROJECTION_EXT`/`FILE_EXT`/`CLASSIFICATION_EXT` unconditional at `:528`, `PROCESSING_EXT`
  conditional at `:533`, `SCIENTIFIC_EXT` on the collection at `:683`). `deprecated`, `version`,
  `datetime`, `start_datetime`, `end_datetime`, `wsg`, `species`, `scenario`, `flood_factor`,
  `region` and the five metric properties carry no colon, so the guard skips them by design.
- **`collection.json` at release time:** `collection_version.py` adds `version` and `VERSION_EXT`
  and nothing namespaced, so the stamp adds no work for this guard. The Collection branch of
  `check_field_prefixes` reads the doc root and `summaries`; the summaries keys are
  `scenario`/`species`/`region`/`flood_factor`, none namespaced. Clean.
- Proved the shapes validate under pystac against the live extension schemas (both the
  processing-declaring item and the deprecated/no-processing item).
- `prov_fields-check.py`'s control already exercises `check_field_prefixes` over all three
  populations plus the two refusal arms (an `nge:` property and an `nge:` **asset** field), and
  `year_sets-check.py` (16/0) shows the validator rewrite did not break the sibling driver's
  fixtures.

So: reasoned and pystac-proven, not measured against a real tree. Worth one `run_pipeline.sh` +
`item_validate.py` pass on a full build before the tag, which is the release flow anyway.
