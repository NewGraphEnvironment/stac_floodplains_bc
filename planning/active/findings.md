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

## Errors Encountered

| Error | Resolution |
|-------|------------|
