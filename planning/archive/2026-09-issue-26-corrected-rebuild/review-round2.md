# Code-check round 2 — #26 deprecation markers

Reviewed: `git diff main` (all 18 files), `scripts/item_validate.py`, `scripts/catalogue_release.sh`,
`scripts/catalogue_release-check.sh` and `scripts/item_create.py` read in full, plus
`planning/active/review-round1.md`.

What I ran, so the negatives mean something:

- `bash scripts/catalogue_release-check.sh` → **ALL PASS**, exit 0.
- Enumerated all 8 `(flag, fv)` states of `check_deprecated` against the code — table below.
- Built a one-group tree and ran `check_deprecated` both ways (the `--partial` finding).
- `POST /search` and per-item `GET` against the **live** API, and compared every published
  figure and every `file:checksum` against `data/stac/`.
- Cross-checked `3.5926x` / `14x` / "Hall's field-validated 3" against `flooded/NEWS.md` and
  `flooded/R/fl_scenarios.R` — **all three are correct and sourced**; I went looking for an
  arithmetic error there and there is none.

Round 1 fixed 8 findings. Two of them contain new defects, and the release note contains a
claim a consumer would act on that is false.

---

## Findings

### 1. **[bug]** `scripts/item_validate.py:344-350` — `--partial` drops an arm that is safe on a subset tree, and kills restore-the-bug proof #2 on the `--only` path

Round 1 named the fix shape precisely:

> restrict them to ids the build actually contains: `(EXPECTED_DEPRECATED & seen)` vs `marked`,
> **plus `marked - EXPECTED_DEPRECATED` (which is safe on a partial tree and is the arm that
> catches a marker that spread)**.

The implemented fix drops *both* directions instead. `marked - EXPECTED_DEPRECATED` names only
ids that are in the build (`marked ⊆ seen`), so it holds on any tree — it needs no whole-catalogue
view at all.

Reproduced on a one-group tree (`bulk_co_ff04.json` + `collection.json`, `bulk` marked
`deprecated: true` with `nge:flooded_version` nulled):

```
partial=True : []
partial=False: [... 'bulk_co_ff04: marked deprecated but not in the expected set', ...]
```

So under `--only` an item publishing `deprecated: true` that the validator's literal does not
sanction goes through the gate, gets synced and upserted into pgstac, and publishes a permanent
"this data is stale" claim about a correct item — on a bucket with versioning Suspended.

This is exactly restore-the-bug proof #2 from `findings.md` ("a third id added to the builder's
literal" → `bulk_co_ff04: marked deprecated but not in the expected set`). That proof no longer
fires on the `--only` path, and nothing says so. `catalogue_release-check.sh` cannot see it
(`uv` is shimmed).

Fix: move `for i in sorted(marked - EXPECTED_DEPRECATED)` above the `if partial: return`, and
leave only `EXPECTED_DEPRECATED - marked` and `EXPECTED_DEPRECATED - seen` behind the flag.

---

### 2. **[bug]** `NEWS.md:49-51` — "every replaced object's checksum moves, so 'the data was replaced' can be told from 'the data is unchanged'" is false for this release

> Any figure a consumer holds for one of the twelve is now wrong; `file:checksum` (#22) makes
> that distinguishable, since every replaced object's checksum moves, so "the data was replaced"
> can be told from "the data is unchanged".

Measured against the live API, on three items the same paragraph classifies as **unchanged**
(`bulk_co_ff04`, `pars_bt_ff04`, `mcgr_ch_ff04` — the last one a *deprecated* item that
explicitly "could not be re-run"):

```
bulk_co_ff04 common assets: 7 | checksum SAME: [] | DIFF: [all 7]
pars_bt_ff04 common assets: 7 | checksum SAME: [] | DIFF: [all 7]
mcgr_ch_ff04 common assets: 7 | checksum SAME: [] | DIFF: [all 7]
```

Every asset of every item has a different `file:checksum` in this build than the one live — the
RAT embedding (#34/#35), the `NGE_` tag rewrite (#40) and the re-COG pass move the bytes on items
whose *geometry* did not move at all. A consumer following the release note's advice diffs 20
items' checksums, sees 20 items change, and learns nothing about which 12 (13, see #3) actually
have new geometry.

This is the one sentence in the entry that tells a consumer what to *do*, and it sends them to a
signal that cannot answer the question. The per-item table is the thing that distinguishes them;
say that, or say that checksums move on every item this release for reasons unrelated to geometry.

---

### 3. **[fragile]** `NEWS.md:29` and `NEWS.md:48` — thirteen items changed, not twelve; seven are unchanged, not eight

`necr_ch_ff04`'s `floodplain_ff04_km2` moves **396.52 → 396.51** (live vs this build). It is not
in the table and it is inside the "Eight items are unchanged" count.

Measured over `floodplain_ff0{2,4,6}_km2`, `gross_loss_ha`, `gross_gain_ha`, `net_ha` for all 20
live items: 13 differ, 7 are identical. The shrink is 0.0025%, below the stated 1.5% floor, which
is presumably why a rounded comparison missed it — but the entry's own framing is
per-item-auditable, and #26 asked to "record before/after area per item so the change is auditable
rather than silent".

Same class as the "18 items / 5-33%" figure round 1 caught, one order of magnitude down: the
corrected number is still derived from a comparison that is not exact equality.

---

### 4. **[fragile]** `scripts/catalogue_release.sh:660-689` — the new step-5 deprecation read-back is a `NONE == NONE` tautology in the harness, and the harness structurally cannot give it a negative case

The harness header states the rule about itself for the version and the licence:

> Case 2's "live version 9.9.9 verified" is tautological on its own — the curl shim serves the
> stamped fixture back — which is why cases 8 and 9 exist: they are what prove the compare bites.
> Its "licence verified" lines are tautological for exactly the same reason, and 9c-9j are their
> 8-and-9.

The deprecation read-back got no 8-and-9. `grep -n deprecat scripts/catalogue_release-check.sh`
returns two **comment** lines and zero assertions; nothing greps for `deprecation markers served`.

And it cannot get one as the shim stands. The `/search` handler emits
`{"features":[{"id": i} …]}` — it ignores `fields.include` entirely and never returns a
`properties` object — so `live_dep` can only ever be `NONE`. The fixture items carry no
`deprecated`, so `built_dep` is `NONE` too, and every full-release case (2, 8, 9, 9b–9j, 14)
passes on `NONE == NONE`. Adding a marked fixture item without changing the shim would make
**case 2, the positive control, fail spuriously**.

`code-check.md`: "A search that finds nothing has proven nothing until it has found something."

Two things I checked so this is a real gap rather than a suspected one:

- The **production** shape is sound. `POST /search` with
  `fields.include: ["id","properties.deprecated"]` against `images.a11s.one` returns a filtered
  `properties` object per feature (measured 2026-09-03, 20 features). So the check will work; what
  is missing is evidence that it *bites*.
- The `NONE` sentinel cannot collide. `item_create.py` emits ids of the shape `<wsg>_<sp>_ff0N`,
  all lowercase, so no id can ever be the literal `NONE`. (`--only`'s id shape check would accept
  an uppercase id, but nothing produces one.) `READFAIL` is likewise unreachable as an id.

Minimum fix: teach the `/search` shim to honour `properties.deprecated` (serve it from the
fixture item, as the `*/items/*` branch already does), mark one fixture item, then add the two
cases — served-drops-the-marker, and served-marks-an-item-the-build-does-not.

Related, one line: `scripts/README.md:63` (the step-5 row) still enumerates the version, the
checksum probe and the licence, and does not mention the deprecation read-back. Round 1's
documentation fix landed on the step-1 row only.

---

### 5. **[fragile]** `scripts/item_validate.py:338-342` — the converse arm asserts a proxy, and the first remedy in its message is the harmful one

```python
elif fv is None:
    problems.append(
        f"{item_id}: carries no nge:flooded_version, so it was not rebuilt on "
        f"flooded >= 0.5.0 and is still over-mapped, but publishes unmarked. Add it "
        f"to DEPRECATED_ITEMS and EXPECTED_DEPRECATED, or rebuild it")
```

"Lacks `nge:flooded_version`" is a proxy for "was not rebuilt on flooded ≥ 0.5.0". They coincide
on today's 23 items (measured: exactly `{mcgr_ch_ff04, pine_bt_ff04}` on both sides), which is
what the docstring rests on — but the property is *absence of a provenance record*, and the claim
is *about the geometry*. A group modelled on flooded 0.5.0 whose producer tree has no
`provenance.json` is correct and unprovenanced, and this arm fires on it. The remedy it offers
first is to publish `deprecated: true` on a correct item — a false statement to every consumer,
and the harder direction to take back (`code-check.md`, "a guard that fires correctly and then
points at the wrong fix"). The second remedy, "or rebuild it", does not help either: rebuilding
does not manufacture a `provenance.json`.

The message needs the third branch the self-clear arm already got in round 1: *if this item was
built on flooded ≥ 0.5.0 and simply carries no provenance record, this guard's proxy is wrong for
it and needs widening, not a marker.*

Second-order, worth one line: this silently retires a tolerance two docstrings still advertise.
`check_provenance` (`:445-447`) says "A null VALUE is expected and allowed — floodplains#33 is
forward-only … and publishing the null is the point of the issue", and `check_citation_premise`
(`:371-373`) says refusing on null "would be a guard failing toward abort on a build the floor
deliberately permits". After this arm, a null `nge:flooded_version` is release-blocking unless the
item is marked deprecated. Both statements now describe a policy the file no longer has.

---

### 6. **[fragile]** `scripts/item_validate.py:262-267`, `CLAUDE.md:100-101`, `scripts/README.md:59`, `NEWS.md:62-63` — four surfaces state that `--partial` drops only arms a subset tree cannot meet

> `partial` drops the two arms that need to see the WHOLE catalogue — the set compare and the
> literal's own ids.

One of the two does not need the whole catalogue (finding 1). `NEWS.md:62-63` goes further and
states unqualified that "`item_validate.py` refuses a build where the marker **has spread**, been
dropped, or been left on an item that has since been rebuilt" — which is false on the `--only`
path, the path #36 exists for.

`findings.md` names this class as explicitly **not** closed after four rounds on #47 ("a comment
or a printed line claims something the code does not do"), and this is instance five. Fixing
finding 1 makes all four sentences true again, which is the cheap direction.

---

### 7. **[fragile]** `scripts/catalogue_release.sh:674-681` — `built_dep` is the only read in step 5 with no `|| { …; fail=1; }`

```bash
built_dep=$(python3 -c "…")
```

Every sibling — `live_dep`, `live_version`, `bucket_version`, `live_licence`, `bucket_licence`,
`live_state` — carries `|| { echo …; fail=1; }` so that a read failure is *reported* and the
script still reaches its verdict line. Under `set -euo pipefail` a failing command substitution in
a plain assignment aborts the script on the spot: the bucket-licence check never runs, and neither
`RELEASE INCOMPLETE` nor `RELEASE COMPLETE` is printed. A log or a wrapper keyed on those strings
sees neither, on a release that has already synced and registered everything.

Give it the same shape as its siblings (`|| { echo "…"; built_dep="READFAIL"; fail=1; }` — and
note `READFAIL == READFAIL` would then compare equal, so it needs the same
`if [ "$x" = READFAIL ]` short-circuit `live_dep` has).

---

### 8. **[fragile]** `scripts/catalogue_release.sh:665-689` — a retracted deprecated item makes step 5 fail after everything is published

Registration is upsert-only, so an item dropped from the build stays live until an explicit
`item_unregister.sh`. On an `--allow-retract` release that drops a marked item, `live_dep` still
contains it and `built_dep` does not, so step 5 prints "the API serves deprecated on … but this
build marks …" and exits `RELEASE INCOMPLETE` — after the sync and the register, on a bucket with
no rollback.

This is the natural future flow for #26 (`mcgr`/`pine` retired rather than rebuilt if
floodplains#76 stays blocked), and the operator's remedy is a step the script already tells them
to run afterwards. Compare against `built_dep` restricted to `after_ids ∩ local_ids`, or subtract
the known orphans, so a deliberate retraction is not reported as a serving defect.

---

## The 8-state enumeration (question 2) — no silent pass

`flag = props.get("deprecated", _ABSENT)`, `fv = props.get("nge:flooded_version")`. Traced through
`:311-342`:

| `flag` | `fv` | verdict | which arm |
|---|---|---|---|
| `_ABSENT` | null | **refused** | `elif fv is None` — "publishes unmarked" |
| `_ABSENT` | value | pass | correct: rebuilt and unmarked |
| `False` | null | **refused** (twice) | `flag is not True` + `elif fv is None` |
| `False` | value | **refused** | `flag is not True` — "publish true or omit it" |
| `None` | null | **refused** (twice) | `flag is not True` + `elif fv is None` |
| `None` | value | **refused** | `flag is not True` |
| `True` | null | pass | correct: the marked state |
| `True` | value | **refused** | the self-clear |

Six of eight refused, and the two that pass are the two that should. The `if/elif` structure is
right: `elif fv is None` is only skipped when `flag is True`, which is exactly the branch the
self-clear covers. Non-`True` truthy values (`1`) fall to the `elif` as well as the shape arm, so
both fire. A missing `nge:flooded_version` **key** reads as null, which errs toward refusal
(`check_provenance`'s set equality reports the missing key separately).

`_ABSENT` and `doc.get("properties") or {}` are both correct as written. Note that the `or {}`
hardening landed in `check_deprecated` only — `check_citation_premise:383`, `check_provenance:474`
and `check_cog_tags:526` still use `doc.get("properties", {}).get(...)`, and
`check_citation_premise` runs **first** in `main()` (`:1495` vs `:1506`), so a `"properties": null`
item raises there before `check_deprecated`'s guard is reached. It exits non-zero either way, so
this is a message-quality issue, not a hole — listed for completeness, not as a finding.

## Default-strict on every path — confirmed

`--partial` is `action="store_true"` (default `False`), the function default is `False`, and there
is exactly one call site. The three other invocations of `item_validate.py`
(`run_pipeline.sh:66`, `test_pipeline.R:73`, `catalogue_release.sh:407`) pass no `--partial`.

## Harness assertions (question 5) — they discriminate

`n_partial_flag` reads the flag as an exact field off the shimmed `uv` argv log. Case 1 expects
`1` and case 2 expects `0`, each paired with an `n_uv == 1` premise, so removing `--partial` from
the `--only` branch turns case 1 red and adding it to the full branch turns case 2 red. Both bite.
The gap is not here — it is finding 4, the read-back that has no case at all.

## Numbers verified against the artefacts

| claim | verdict |
|---|---|
| 23 items in the build, 21 carrying `nge:flooded_version`, exactly 2 marked | ✅ measured |
| `PROVENANCE_FLOOR=21` | ✅ matches `catalogue_release.sh:60` |
| 20 live → 23, three new (`thom`/`lnth`/`unth`) | ✅ measured |
| all 12 published km² in the table | ✅ match the live API exactly |
| all 12 corrected km² in the table | ✅ match `data/stac/*.json` exactly |
| all 12 `retained` percentages | ✅ recompute to the printed figure |
| "1.5% to 33.5%" | ✅ `pcea` 1.46%, `tabr` 33.55% |
| both marked items null on all 12 `nge:` properties, 4 `stac_extensions` | ✅ measured |
| `3.5926x`, "roughly 14x", "Hall's field-validated 3" | ✅ all three sourced to `flooded/NEWS.md` (ff04 → 14.37) and `flooded/R/fl_scenarios.R` ("Hall et al. 2007 validated ff=3") |
| `v2.0.0` paragraph sits above `## v1.1.0` without becoming the top `## ` heading | ✅ `grep -n '^## '` → line 20 is `## v1.1.0` |
| "Twelve items shrink" / "Eight items are unchanged" | ❌ finding 3 |
| "every replaced object's checksum moves … can be told from" | ❌ finding 2 |
