# #82 — Produce the provenance floor and census instead of hand-deriving them

## Outcome

`scripts/prov_census-measure.R` ships: one argument-free command that walks the watershed-group
roster the way `01_stage.R` does, drives this repo's own provenance reader, and prints
`PROVENANCE_FLOOR`, `PROV_CENSUS` and `prov_fields-check.py`'s fixture populations paste-ready,
from `$FLOODPLAINS_DATA` with no build, no writes, no network and no `sf`/GDAL/`drift`. It is
named `-measure` rather than `-check` because it **produces** an expectation where every sibling
asserts one, and `scripts/README.md` says so in as many words so a passing run is never read as a
gate. It refuses — no census, non-zero — on any failed read, on a run that stages nothing (a floor
of 0 was once true and is also what a reader that found nothing produces), on an accounting
mismatch and on `WSG_ONLY`. `prov_fields-check.py` gained four arms that fail at **paste** time
rather than at the next release, and #90 was filed for the roster-walk duplication the script
deliberately defers.

Two things the work learned that outlived it. **The reader-call order is load-bearing, not
tidiness**: `01_stage.R`'s skips sit above its first `fp_prov_*` call and its record read sits
above its bundle skip, and getting either backwards makes the script print a census for a tree
whose build stops, or refuse one a build is happy with. And **a half-present
`processing:software` entry aborts the whole build, not just its own item**, because
`run_pipeline.sh` calls `item_create.py` once under `set -euo pipefail` — so while DUNC carried
`link_version` without `link_sha`, floodplains#133 gated every region's release, which is what
#89's "DUNC is not a gate" was wrong about. Its body is corrected; floodplains#133 carries the
measurement as a comment.

The review was unusually productive: four `/code-check` rounds, 19 findings, nine of them inside
an earlier round's fix, and three distinct mechanisms each closed by enumeration rather than by a
quiet round — build fidelity (38 rows from `01_stage.R`), tokens pinned by a text search that also
appears in prose (8 source-text arms, 14 mutations), and counts about a moving upstream tree
restated in N copies (12 instances, found only once the sweep dropped its `^+` filter and its path
list and reached the PR draft and the issue bodies).

## Measurement

The census, through the shipped script, moved **five times in 61 minutes** on 2026-10-15 while
`run_region.R columbia` landed group by group upstream — one tree, one command:

| UTC | result |
|---|---|
| 17:37 | floor 20, 20 staged, 3 skipped (`kotl`/`larl`/`sloc`) |
| 17:58 | **refusal**, no census — KOTL's rasters written, its landcover section not yet stamped |
| 18:16 | floor 21, 21 staged, 2 skipped |
| 18:33 | floor 22, 22 staged, 1 skipped |
| 18:42 | floor 23, 23 staged, none skipped; `link_run_uid` 18, the other eleven 23 |

That is the argument for an exact literal re-taken on the build a release is cut from, and it is
why the output carries its own timestamp and the producer's HEAD. It also **falsified a claim this
branch had already written into four files and an issue body** — that a build aborts on DUNC —
when the run wrote DUNC a `link_log` at 18:38Z. The claim was true when measured and the guard it
produced stays; every copy now says when it held. A second claim was falsified outright: "the
state recurs whenever upstream cannot resolve a sha" is wrong as a sufficient condition, because
all 23 `all*` sections carry `inputs$link$sha: null` and all 23 publish — the log row supplies it,
so the state needs **both** sources empty.

What changed because of it: `PROVENANCE_FLOOR` and `PROV_CENSUS` are **not** re-taken here (a
number from a tree in flight is not an expectation), #89's release recipe now names one command
instead of three hand-derivations, `CLAUDE.md`'s "it cannot be cut yet: 13 of the 23 rostered
groups" was re-measured to all 23 staging, and the moving numbers now live only in the script that
prints them and in `findings.md`, which is dated by construction.

## Evidence

`findings.md` carries the full record: the planning probe, the ten sandbox arms with their
commands, the three enumeration tables, and the mutation tables (five arms proven to fire, then
six, then fourteen across four rounds). `review-round1.md` through `review-round4.md` are the
reviewers' own reports. No run logs: the script makes no writes, and every measurement in here is
one command over `$FLOODPLAINS_DATA` at the stated minute.

Closed by: PR for `82-produce-the-provenance-floor-and-census`
