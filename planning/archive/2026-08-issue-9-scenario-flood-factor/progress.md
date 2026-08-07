# Progress — Expose scenario (flood factor) as a queryable STAC item property (#9)

## Session 2026-08-06

- Plan-mode exploration; phases approved by user, along with two design choices: add a numeric
  `flood_factor` alongside the `scenario` string, and add collection `summaries` (the collection has
  none today).
- Key finding: this closes a contract `floodplains/README.md` already asserts — `wsg`/`species`/
  `scenario` are each meant to be both a STAC property and a gpkg column. Only the gpkg half was
  enforced here.
- Created branch `9-expose-scenario-flood-factor-as-a-querya` off main.
- Next: Phase 0 baseline, then Phases 1-4.
