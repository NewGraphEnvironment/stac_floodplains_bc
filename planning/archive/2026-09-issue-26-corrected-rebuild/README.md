# #26 — Published items were over-mapped: the corrected rebuild

Merged as [PR #52](https://github.com/NewGraphEnvironment/stac_floodplains_bc/pull/52)
(`3749de2`), released as **v1.1.0** on 2026-09-03.

Every published floodplain item was built with the `flooded` bankfull units defect —
`fl_flood_surface()` fed hectares and millimetres into Hall et al. coefficients taking km² and
cm/yr, so bankfull depth was 3.5926x too large and a `ff04` item was a waterline at ~14x
bankfull depth. The corrected rebuild was already staged upstream; this issue marked the two
areas that could not be re-run, guarded the marker, and published.

## Measurement

**The catalogue's geometry, corrected.** Compared exactly — each item's own
`floodplain_ff0*_km2` on the live API against the rebuilt property:

- **13 items changed**, 7 unchanged, 3 new. Twelve shrink by **1.5% to 33.5%**
  (`tabr_ch_ff04` 232.69 → 154.63 km², `pcea_bt_ff04` 1067.59 → 1051.96); the thirteenth,
  `necr_ch_ff04`, moves 0.01 km².
- 20 items → **23**; `PROVENANCE_FLOOR` 0 → **21**.

**Three figures in the issue and in the first draft of the release note were wrong**, each from
restating a prior document rather than measuring:

| claimed | measured |
|---|---|
| 18 items shrink | 13 — eighteen was the count of upstream *re-runs*, six of which moved nothing |
| 5–33% | 1.5–33.5% — from the issue's summary line, contradicted by its own per-item table |
| `file:checksum` distinguishes replaced data | **false** — 140 assets across the 20 common items, **zero** unchanged |

That last one is the one that mattered. The COG and RAT rewrites touch every byte, so the
checksum answers "are my bytes current" and cannot answer "did the geometry change". The
release note had told consumers otherwise.

**The pgstac link premise, answered.** #47 published `rel: license` and `rel: derived_from`
from a source read of `INFERRED_LINK_RELS`, explicitly unmeasured against `images.a11s.one`.
This release settles it — the API serves both.

## Evidence

- `findings.md` — the measurement record, the 8-state guard enumeration, and the release outcome
- `review-round1.md` / `-round2.md` / `-round3.md` — 20 findings across three rounds, all fixed,
  none dismissed
- `scripts/catalogue_release-check.sh` 100 → **111** assertions; cases 9k/9l/9m added and each
  proved to discriminate by breaking what it tests in a scratch copy
- Release log: every step-5 assertion passed first run — version, licence, both link hrefs,
  `sci:citation` and the deprecation markers, on the API *and* the bucket

## The wrong turns worth keeping

Each review round found defects **inside** the previous round's fixes, and the shape repeated:

1. Round 1: `check_deprecated` asserted the whole catalogue on every invocation, silently
   redefining `--only` as "works for the two marked items only".
2. Round 2: the `--partial` fix dropped an arm that was subset-safe, so a stray marker could
   reach pgstac as a permanent false "stale" claim.
3. Round 3: **the same mistake on the mirror arm.** The `& seen` insight had been applied to one
   direction and not the other.

The partition that matters — does an arm name an id the tree *contains*? — is written into
`check_deprecated`'s docstring, because it is what all three rounds got wrong in one direction
or another. Six of seven arms are subset-safe; one is not; only that one is dropped.

Two smaller ones: the proof harness restored `meta.json` but never rebuilt, leaving `data/stac`
polluted (the release gate would have refused it, which is the guard working); and a restored
bug reported `WRONG GUARD (rc=0)` because the proof mutated the builder's literal where the
guard is about the validator's.

## Left open

`mcgr_ch_ff04` and `pine_bt_ff04` remain over-mapped, blocked on floodplains#76, and publish
`deprecated: true`. The marker **self-clears**: when they are rebuilt, `item_validate.py`
refuses the release until they are removed from both literals. `v2.0.0` is reserved for that
release, recorded in `NEWS.md`'s header — a decision that previously existed only in
conversation, in none of #26, #19, the archived PWFs or the project memory.
