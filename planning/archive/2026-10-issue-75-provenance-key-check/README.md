# #75 — Provenance key check: verify each item finds its scenario, not a key-shape whitelist

**Closed by** PR (branch `75-provenance-key-check-verify-each-item-fi`), commits `9f9f88d`..`e190157`.
**Issue:** [#75](https://github.com/NewGraphEnvironment/stac_floodplains_bc/issues/75).
**Spawned:** [#79](https://github.com/NewGraphEnvironment/stac_floodplains_bc/issues/79),
[#80](https://github.com/NewGraphEnvironment/stac_floodplains_bc/issues/80),
[floodplains#133](https://github.com/NewGraphEnvironment/floodplains/issues/133).

## Outcome

`fp_prov_sections()` refused any `floodplain` / `landcover` provenance section key that did not
match `^[a-z]{2}_ff[0-9]{2}$`, scanning **every** key in the section rather than the one it was
looking up — so one unrecognised sibling stopped a whole watershed group. It now checks that **the
item finds its key**: the item's own `scenario` must be a key of any of those two sections that has
keys, refused by name against the keys present. The re-keying failure the whitelist existed for is
still refused, because every item's own lookup misses; a key naming a scenario this repo does not
publish is no longer examined. Two states that satisfy a name check and cannot be read — a
duplicate key and a null-valued key — are refused too, both found in review after being measured
publishing a wrong value and seven nulls respectively.

This unblocked publishing, which floodplains#125 had frozen on it. Nothing was published here:
`PROVENANCE_FLOOR` and `PROV_CENSUS` are exact literals re-taken on the build the next release is
cut from, and the census is knowingly stale by exactly DUNC.

## Measurement

`all_ff04` keys were already on disk in `bulk`, `kisp`, `morr`, `dunc`, and
`Rscript scripts/fp_provenance-check.R` **halted** on the real `bulk` file — so the repo's own
provenance guard-test had no producer-file coverage at all, and the `neexdzii` fold pin, the only
assertion proving the fold rule against producer bytes, had been dead since 2026-10-13.

Across all 23 rostered targets, every target's scenario is present in both its sections: **zero
misses**, so the replacement passes on the whole real tree. The safety premise behind refusing a
non-empty section that lacks the key — that such a target has no rasters and is skipped before any
provenance call — re-measured true in all 22 areas carrying a record, with the `rasters/<scenario>/`
set **equal** to the landcover key set and zero violations.

| run | result |
|---|---|
| `fp_provenance-check.R` | 87 assertions, 0 failed, **0 skipped** (was: halted) |
| `stage_years-check.R` | 14/0 (`ufra`), 13/0/1 (`AREA=bulk`, new) |
| `prov_fields-check.py` · `year_sets-check.py` | 44/0 · 16/0 |
| `WSG=bulk test_pipeline.R` | PASS — `bulk_all_ff04`, ff04 **659.99 km²**, 7-year span, 12/12 provenance fields |
| `WSG=morr test_pipeline.R` | PASS — `morr_all_ff04`, ff04 **479.32 km²**, species `all` matched against three network sections |
| `WSG=ufra test_pipeline.R` | PASS — the species-group control (`ALLOW_DRIFT_SKEW=1`, #69) |

Both whole-network figures match floodplains#125's own run log (660.0, 479.3), from two different
toolchains. `stage_years-check.R` reports a three-year item's `meta.json` **byte-identical** to the
pre-change build, so no staged output moved.

## Evidence

`planning/archive/2026-10-issue-75-provenance-key-check/` — `findings.md` holds the upstream
measurements, the two defects verification found, and the code-check loop's anatomy;
`review-round{1..4}.md` are the reviewers' own reports.

## The wrong turns, kept

**An agent edit destroyed a user decision.** The `#75` body gained a "Decided (2026-10-14)" section
at 15:50 UTC requiring staging to write only each item's own layers. The plan had been built from a
read taken before it, and a later `gh issue edit` of that body dropped the section — exactly what
`feature-workflow.md`'s "re-read the issue body before the baseline" exists to prevent. Recovered
verbatim from the issue's `userContentEdits` via GraphQL, restored, acknowledged in a comment, and
split out as #80.

**The first costing of #80 was wrong and was retracted.** It was put to the user as "republish 23
items on a bucket with no rollback"; a full release republishes everything anyway, and a moved
`file:checksum` breaks nothing. The honest cost is a multi-layer writer plus one determinism
measurement, and the real justification is that `bulk_all_ff04` ships BULK's **coho** floodplain
inside the whole-network item.

**Five code-check rounds, three of which found a defect inside the previous fix.** The last one was
on the live publish path and four earlier readings had missed it. What terminated the loop was
re-stating the enumeration on the axis that generated the misses — what a variable *holds* rather
than what it is *named*. `findings.md` has the table.

**Two defects the verification found that were not in the change**: `test_pipeline.R` hardcoded
MORR's retired two-target shape and failed a build `item_validate.py` had already passed; and
`dunc_all_ff04` cannot publish because neither its link log nor `inputs$link$sha` carries a commit
(floodplains#133).
