# Review — PR #43 (branch `41-readme-coverage-table`)

Reviewed 2026-09-02 against the live API. Files: `scripts/readme_coverage-table.py` (new),
`README.md` (Coverage section), `scripts/README.md` (release step 6).

## What was measured

- Page-completeness guard tested against both answers: `limit: 5` returns a `next` link
  (guard fires), `limit: 1000` and `limit: 20` return `root`/`self` only (guard passes).
  `numberReturned: 20`, no `numberMatched`, as the comment states.
- Bucket `collection.json` carries 20 `rel: item` links; the API served 20 features. Match.
- Anchors: `TABLE_START` matches exactly line 29, `TABLE_END` exactly line 51. The two other
  tables (`| Step | Script | What |`, `| Script | Does |`) match neither. README has no `\r`
  and none of the extra separators `str.splitlines()` honours, and ends in exactly one `\n`,
  so the read/splitlines/join/write round-trip is exact.
- `--write` run twice: identical sha256 after both runs, and byte-identical to the committed
  README. `git checkout -- README.md` afterwards; tree clean.
- Sign/rounding: `round()` returns `int`, so no negative zero is possible; an unsigned
  `-0.4` prints `0`, a signed `0` prints `+0`. All 20 rows reproduce the committed values
  (e.g. `-738.2 -> -738`, `485.5 -> +486`, `-174.5 -> -174` under banker's rounding).
- Sort: `(region, wsg, flood_factor, species)` alphabetical; `summaries.region` is
  `['columbia','fraser','peace','skeena']`, so the docstring's "order the collection lists
  regions" agrees with the code today because both are alphabetical.
- `flood_factor` arrives as `int` (`4`/`6`), so `f"floodplain_ff0{ff}_km2"` resolves.
- No security surface: two public GETs and one POST, no credentials, the only write is
  `README.md` resolved from the script's own path.

## Findings

- **[fragile]** `README.md:19-25` / `scripts/readme_coverage-table.py:106-113` — the
  prose above the table hardcodes every number the script computes and does not write:
  "**20 STAC items** across **19 watershed groups**", the region list, "last run at release
  **v1.0.0**, 2026-09-02", and "every item but `morr_ch_ff06`". `write()` replaces only the
  block between the anchors, and `main()` has `n_items`, `n_wsg`, `version` in hand and
  prints them to stdout rather than into the file. After the next full release, step 6 of
  the recipe updates the table and leaves the caption contradicting it (wrong count, wrong
  version, a missing region) — the rendered-copy-drifts case in CLAUDE.md, arriving on the
  very first re-run. Also: step 6 sits after `git push origin vX.Y.Z`, so the tagged commit
  always carries the *previous* release's table; the "last run at release vX" note is
  therefore stale by construction unless it is hand-edited each time.

- **[fragile]** `scripts/readme_coverage-table.py:93-96` — `ff04_by_wsg.setdefault(...)`
  takes `floodplain_ff04_km2` from whichever of a group's items the API returned **first**.
  The search sends no `sortby`, so that order is not guaranteed. It is safe today only
  because `morr_co_ff04` and `morr_ch_ff06` both publish `357.69`; the "one physical
  floodplain" claim in the comment is an assumption about the data, never asserted. If a
  future two-item group publishes species-specific ff04 extents, the km² total becomes
  order-dependent and `--write` stops being idempotent, silently. One line closes it:
  assert every item of a WSG agrees on `floodplain_ff04_km2` before summing.

- **[fragile, low]** `scripts/readme_coverage-table.py:64-66` — the count cross-check
  passes on `0 == 0`. Reaching that needs the API to serve zero features *and* the bucket
  collection to carry zero item links, which the release guards make unlikely, but the
  result would be `--write` replacing all 20 rows with a bare header and a `**0**` total.
  A `if not feats: raise SystemExit(...)` before the comparison is the absolute assertion
  CLAUDE.md asks for beside any cross-check ("an empty result set is not a pass").

No bugs found in the shipped path: the guards fire in the correct direction when tested,
the anchors are unique, and the write is byte-idempotent against the live catalogue.
