# #61 — the classified year set became a property of the item

Closed by **PR #62** (`9503cca`), with a release-blocking defect in its own new guard fixed
by **PR #63** (`9a3d98b`). Issue #61 closed 2026-09-05.

`scripts/01_stage.R` declared `YEARS <- c(2017, 2020, 2023)` and four downstream decisions
read it. The span is a fact about the producer's run, not a contract this repo chose, so it
is now discovered from the `classified_<yyyy>.tif` actually staged, per item, with the
producer's `landcover.<scenario>.inputs.years` as the check. That direction is the whole
design: sourcing both sides from provenance would have reduced `fp_fold_year_digests` to one
file's `years` agreeing with the same file's `classified_content_sha256`, written by one
upstream step moments apart. `TRANSITION_SPAN` stays a literal and became the anchor — the
year set is data, the span is a contract.

The collection now carries two populations, and `ALLOWED_YEAR_SETS` in `item_validate.py` is
the literal a human sets that says which are sanctioned (airvine, 2026-09-05). Delete the
three-year tuple when `floodplains#79` finishes and the guard tightens back on its own.

**This changed code, not data.** Publishing the annual areas is #59.

## Measurement

The acceptance criterion was "every existing three-year item byte-identical". The local A/B
it implies is not runnable: `01_stage.R:80-81` wipes `data/` on every run, so a reference
tree is present or absent depending on what was staged last — and absent reads as a pass —
and installed `drift` was 0.13.0 against a recorded 0.8.0 on 18 of 22 landcover sections, so
a full "before" build stops at the first area. Measured three ways instead, weakest first:

1. `ufra_ch_ff04`'s `meta.json` restaged byte-identical to the pre-change build,
   `sha256:22c2460f77b6b7f0da3a2c23cf0290cddf81429e657a692fc3e7b2eaac0e68e3`. Now a standing
   assertion in `stage_years-check.R`, double-gated (upstream's `produced_datetime` and this
   machine's sf/GDAL/PROJ triple) so a re-run reads as "re-take the pin".
2. Both populations round-trip stage → tag → COG → style → build → validate: `WSG=lnth`
   (7 years, 14 assets, 13 style rows) and `WSG=ufra` (3 years, 10 assets).
3. **Ground truth at the consumer**: the rebuilt `ufra_ch_ff04.json` against the LIVE item at
   `images.a11s.one` — 10 assets each, identical key sets, **0 asset fields moved** (href,
   `file:checksum`, `file:size`, roles, type, title), **0 properties moved**, geometry and
   bbox identical. An absent live property counts as equal to a published null, because
   pgstac stores it and the API omits it.

Determinism on the axis the fixtures could not previously reach: `04_gpkg_style.py` is a true
no-op on the third pass over a seven-year GeoPackage, and both determinism checks pass with
`ITEM=lnth_ch_ff04` (8 styled feature layers instead of `sloc_bt_ff04`'s 4).

**The population moved during the session.** `floodplains#79` converted areas one at a time
while the work was in flight — `necr` 19:14, `lnth` 19:17, `kotl` 19:46, `bulk` 19:52 UTC —
which rotted two fixtures inside one hour. Both are now gated on their own area's
`produced_datetime`. Anything in this repo pinning a value taken from a producer file needs
that gate, or it fails as "the code broke" when it means "upstream re-ran".

## What the reviews cost and bought

Three rounds, 19 findings, all real, all fixed. Round 3 returned **after** #62 merged and
found a release-blocking bug inside round 2's fix: the new whole-directory stray-file arm did
not model the release's own sync excludes, so a `.DS_Store` or a GDAL PAM sidecar — files
that provably cannot ship, and that appear on their own — would have **refused a release**.
The control fixture added in the same edit could not reach it, writing neither.

Round 3 also named the mechanism behind all three rounds, which is the durable part:

> A statement's scope is set by what it **reads**, and it drifts as soon as the statement is
> written from something other than the thing it describes.

In code that is an assertion description wider than its predicate; in prose a figure copied
from a sibling document rather than re-derived. Same failure — the source of the claim is not
the subject of the claim, so nothing in the artifact can contradict it. Five of round 3's
eight findings were still that shape and two sat inside earlier fixes, which is why the
review ended on `review-round3.md`'s enumeration rather than another sampling pass.

## Corrections to the issue as filed

- **"Style writer produces seven QMLs" was false.** `styles/` holds three committed QMLs and
  `04_gpkg_style.py` maps them by layer prefix, so a seven-year GeoPackage gets seven
  `layer_styles` **rows** from one `classified.qml`. `style_qml-write.py` needed no change.
- `item_validate.py:141-155` does not carry year prose — that range is `EXPECTED_CITATION`.

## Found on the way, and fixed here

`test_pipeline.R` had been unable to validate **any** watershed group since #26 landed —
`EXPECTED_DEPRECATED` names two items and a one-group tree is always missing at least one,
including each of those two, which are missing each other. Reproduced on `main`. Fixed with
`--partial`, because this issue's own acceptance criterion is not testable without it.

## Corrected after the fact

The review's note that `lnth`'s `floodplain_landcover.gpkg` carries an extra
`patch_watercourse_*` table was **narrower than the truth**, and the framing mattered: it read
as an artifact of the annual span. Measured across all 23 areas while archiving —
**18 carry one**, `ufra` (three-year) included, and `kotl` (annual) does not. So it varies
independently of the year set, it is already published, and it is not something
`floodplains#79` introduces. Filed as #65; the fact is now in `CLAUDE.md`'s collection model.

A finding measured on one item is a claim about one item. This one was written down as though
it were about a population, and the population disagreed.

## Evidence

- `task_plan.md` — the approved phases; `findings.md` — what was measured before the baseline
  and the errors that cost a retry; `progress.md` — the session log with the per-round tables.
- `review-round1.md` / `review-round2.md` / `review-round3.md` — the three reviews in full,
  including round 3's Enumeration A/B, which is the record of *why* the review terminated.
- Check scripts on `main`: `scripts/fp_provenance-check.R` (72), `scripts/stage_years-check.R`
  (14), `scripts/year_sets-check.py` (16).
