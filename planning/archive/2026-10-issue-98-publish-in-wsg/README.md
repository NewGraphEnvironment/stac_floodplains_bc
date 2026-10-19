# #98 — publish `in_wsg` / `in_open_water`, and read the headline metrics over `in_wsg`

**Outcome.** Upstream floodplains#144 split every whole-network vector layer along the
watershed-group polygon and flagged each piece `in_wsg`. This repo now derives every headline
figure twice — over `in_wsg` for the unsuffixed property, over every row for a new
`*_footprint_*` sibling — publishes both on all 23 items, describes the three new columns
where a consumer reads them, and guards the pair. Released as v2.1.0 (Phase 6, outside the PR).

The shaping finding is that **the two metric families moved in opposite directions**, so a
single blanket `& in_wsg` would have been right for one and wrong about which figure was at
risk. The pre-split transition layer *was* clipped, so scoping loss/gain/net to `in_wsg` HELD
every published value; the delineation layer never was, so `floodplain_ffNN_km2` was already
whole-footprint and became the smaller figure.

## Measurement

Taken on the build a release was cut from (full `run_pipeline.sh`, 23 groups, 108 COGs, exit 0,
tree verified unmodified for the whole run). Against the **live API**, item by item:

- `in_wsg` `gross_loss_ha` / `gross_gain_ha` / `net_ha` equal live on **23 of 23**, exactly.
- `*_footprint_km2` equals live's unsuffixed area on **23 of 23**, exactly.
- `bbox` and `proj:bbox` moved on **0 of 23**; `geometry` moved on **23 of 23** (+8 DUNC to
  +364 FRAN coordinate values, 0.00–0.13%) without the ground moving.
- `PROVENANCE_FLOOR` and `PROV_CENSUS` did not move; `METRIC_SCOPE_CENSUS` measured 23/23.

Deliberate value change: `floodplain_ffNN_km2` on all 23 items. BULK 659.99 → 646.81;
PCEA 843.34 → 491.38 (41.7% of its floodplain outside its own group). 22 groups sit between
0.8% and 3.3% outside.

PCEA is the case that argues for publishing both scopes: its two nets disagree on the
**direction** of change, `net_ha` −2.3 ha against `net_footprint_ha` +54.1 ha.

The provincial picture, measured in BC Albers (`neighbour-measure.R`, three independent runs
agreeing): of the 519.16 km² by which the ff04 footprint exceeds the ff04 in_wsg extent, 50.58
(9.7%) is another item's own ground and **468.57 (90.3%) is published by nobody**. The union of
the 23 in_wsg pieces equals their sum, so the unsuffixed total counts no ground twice — and it
is a total of the covered groups, not of the province.

## The review, and what it cost

Six reviewer agents (plan review + five `/code-check` rounds), past `agent-operations.md` §2's
bound. 38 findings, **19 inside a previous round's fix**. One class:

> A claim written by restating a source — the upstream issue body, a sibling copy, or an
> earlier draft of itself — then checked for the PRESENCE of what it names rather than
> re-derived from the artifact it is attached to.

Terminated by turning the enumeration into a guard rather than by a quiet round:
`scripts/claim_drift-check.py` pins the claim set across all nine copies (156 arms, each proved
by mutation) and found five more problems on its first run, two of them regressions made
minutes earlier. Three defects it or the rounds caught that would otherwise have shipped: a
guard of mine that could never pass and blocked the release; a published description that made
a consumer 3–10% wrong; and a guard blind to the mirror of the failure it was built for (an
inverted `in_wsg` filter passed every arm on all 23 items).

Two of my own measurements were withdrawn rather than defended — a geometry residual that did
not reproduce across two runs, neither having recorded its CRS, and a `PARS` attribution that
was my own substitution for the upstream log's `PARA`.

## Evidence

`planning/archive/2026-10-issue-98-publish-in-wsg/` — `findings.md` holds every measurement
with its date and method, `review-round{1..5}.md` the reviewer reports, `claim-enumeration.txt`
the 70-claim numeric sweep, `neighbour-measure.R` the Albers script the 519.16/50.58/468.57
figures come from.

Closed by PR (see `git log --grep '#98'`); released as v2.1.0.
