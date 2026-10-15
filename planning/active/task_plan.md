# Task: Produce the provenance floor and census numbers instead of hand-deriving them each release (#82)

`PROVENANCE_FLOOR` (`scripts/catalogue_release.sh:61`) and `PROV_CENSUS`
(`scripts/item_validate.py:540`) are exact literals a human sets — deliberately, because an
expectation derived from the data cannot be contradicted by it. But nothing in the repo
*produces* the numbers a human is meant to set. The only routes are a full ~900 MB build
(`01_stage.R` prints the item-level count, `item_validate.py` prints a `census:` line) or a
throwaway script, which is what #75 wrote and did not keep. That is how the literals went stale:
they read `link_run_uid` 18 / `link_config_sha256` 21 / `link_sha` 21 while the roster measured
17 / 20 / 20 on 2026-10-14.

The issue's decision (airvine, 2026-10-15) is that it ships as a script, named
`scripts/prov_census-measure.R` — **`-measure`, not `-check`**, because every `*-check.{R,py}`
here asserts an expectation and this one produces one.

Measured on the real tree during planning, 2026-10-15: 23 rostered targets, 3 would not stage
(`kotl`/`larl`/`sloc` — config converted to `all_ff04` ahead of their run), 20 staging and all 20
carrying provenance, `link_run_uid` 18, `link_config_sha256`/`link_sha` 19. **Those numbers are
not written into any literal by this issue** — DUNC cannot publish until floodplains#133 is
resolved, so a release cut today fails one step earlier and writing today's numbers would encode a
broken record as the expectation (CLAUDE.md, #75). This issue ships the producer; #89's releases
use it.

## Phase 1 — the script

`scripts/prov_census-measure.R`, no arguments, no writes, no network, no database.

- [x] Header: what it produces, where each number goes, that it is a **measurement not a gate**,
      and the caveat that a tree mid-write (an upstream `run_region.R` in flight) yields a census
      of a half-finished roster — which the printed timestamp and producer HEAD make visible.
- [x] `PROV_FIELDS` parsed out of `01_stage.R`, never copied: `parse()`, find the single
      `PROV_FIELDS <- ...` assignment, `stopifnot` exactly one, `eval()` it, then
      `source("scripts/fp_provenance.R")`. Exactly the pattern at `fp_provenance-check.R:24-30`.
      A fifth copy of the field list is what #74 spent its rounds avoiding.
- [x] Roster walk mirroring `01_stage.R:135-160, 206-229`: `config/regions/*.yml` ->
      `watershed_groups` -> `config/<wsg>/area.yml` -> targets. `[[ ]]` throughout, never `$` —
      `area$targets` returns a `targets_retired:` block and `rc$watershed_groups` a retired roster
      (`01_stage.R:138-143, 217-222` record both measured cases).
- [x] Mirror the build's **selection**, in the build's order, so the census describes the set a
      build would stage: no `area.yml` -> skip the group; either bundle (`floodplain.gpkg`,
      `floodplain_landcover.gpkg`) absent -> skip the group; no `rasters/<scenario>/` or no
      `classified_<yyyy>.tif` in it -> skip that target. **Each skip is recorded and printed by
      name.**
- [x] `years` from `rasters/<scenario>/classified_<yyyy>.tif`, pattern **anchored at both ends**
      (`01_stage.R:402`) — unanchored, the `.tif.aux.xml` sidecar beside each raster matches and
      the year is counted twice. It is the one argument `fp_prov_item()` needs that is not in the
      record; it feeds the `landcover_key` fold.
- [x] Per staged target, inside `tryCatch`: `fp_prov_rasters_current()` then `fp_prov_item()`, and
      count a field as carried when its value is not NA. `fp_prov_read()` once per group, also in
      `tryCatch`.
- [x] **Refusal**: a failure is recorded, not fatal, so one group does not end the walk; then if
      any occurred, print every failure with its target id and **exit non-zero having printed no
      census**. The number becomes a release gate, so a count that is short for any reason other
      than the data is the dangerous direction — it would be pasted into `PROVENANCE_FLOOR` and
      then satisfied by a build that lost provenance. A `NULL` from `fp_prov_read()` is **not** a
      failure: that is the legitimate forward-only state and counts as an item carrying none
      (`fp_provenance.R:147-166` draws exactly this line).
- [x] Skipped targets are **not** a refusal: exit 0, with a banner naming them and saying a full
      release from this tree is refused by the `PARTIAL_STAGE` interlock unless `ALLOW_SKIPPED=1`.
      The build would stage the same set, so the census still matches the build it describes.
- [x] Output carries its own provenance: UTC timestamp, the resolved `$FLOODPLAINS_DATA`, the
      producer tree's `git describe --tags --always --dirty` and HEAD, and rostered / staged /
      skipped counts. A census printed without them is a number with no date, which is the state
      #75 found the literals in. The git read degrades to a stated "not a git tree" rather than
      failing — Phase 2's sandboxes are not repos, and neither is a copied data tree.
- [x] Output shape — ready to paste, in `PROV_FIELDS` order, plus the floor and the destination of
      each number.
- [x] Say in the script what it does **not** check, so nobody reads its exit 0 as "this build will
      stage": it does not open the GeoPackages (the build skips a bundle it cannot read, and
      refuses a layer carrying no usable key or another group's), and it does not run
      `fp_years_reconcile()`. Both of those make the build stage *fewer* items or stop outright —
      loud failures, not silent ones.

## Phase 2 — prove the refusal fires

The refusal is the design point, so it does not ship unproven. No new check script — the issue
asks for a measurement, and a check for the measurement is not what it asks for. Done by hand in a
sandbox and recorded in `findings.md` with the commands. The sandbox is
`stage_years-check.R:159-190`'s shape, minus its cwd games: `<sbx>/src/{config,data}` with a
synthetic one-group region yml, the real `area.yml` and `provenance.json` copied, rasters
symlinked — then run the script from the repo with `FLOODPLAINS_DATA=<sbx>/src/data` (`CONFIG_DIR`
is `dirname($FLOODPLAINS_DATA)/config`, so one tree serves both, and this script writes nothing,
so it cannot escape).

- [ ] Clean tree: exits 0, prints the census, numbers equal the roster walk done in planning.
- [ ] Unreadable `provenance.json` in one staged group: exits non-zero, no census printed, the
      failure names that group.
- [ ] `schema_version` bumped past the reader's pin: same disposition.
- [ ] A raster touched newer than its landcover run stamp: same disposition (the mid-write state).
- [ ] An area with no `provenance.json` at all still counts as an item carrying none and the
      census still prints — the forward-only control, so the refusal cannot be reading absence as
      failure.

## Phase 3 — say what it is, where it is read

- [ ] `scripts/README.md`: its own short section beside the three check-script sections, stating
      in as many words that it **produces** an expectation rather than asserting one, so a passing
      run is never read as a gate. The three numbers it feeds, and that it needs
      `$FLOODPLAINS_DATA` but no build.
- [ ] `CLAUDE.md`: name it in the `PROVENANCE_FLOOR` / `PROV_CENSUS` paragraphs as where the
      re-taken numbers come from. The stale-literal paragraph stays as written — this issue does
      not re-take them.
- [ ] `NEWS.md`: an entry under `## Unreleased`.
- [ ] Issue #89, step 3: drop the "until that exists, read it off `01_stage.R`'s output" clause and
      name the script. Body edited, not appended.

## Phase 4 — reconcile with `prov_fields-check.py`

`prov_fields-check.py:207-210` hard-asserts `PROV_CENSUS == {link_run_uid: 18, rest: 21}` and
builds an 18 + 3 + 2 item fixture to match. Re-taking the census turns that red, which is correct
but says nothing about the second and third hardcodes.

- [ ] The measure script's paste-ready block names **all three** destinations, including
      `prov_fields-check.py`'s fixture populations, so a re-take cannot move two of three.
- [ ] `prov_fields-check.py` gains a comment naming `prov_census-measure.R` as the producer of the
      numbers it asserts, and a static arm that the measure script carries no copy of the field
      list — the same instrument it already uses to join the four publish-side copies of the field
      map.

## Validation

- [ ] `Rscript scripts/prov_census-measure.R` on the real tree: exits 0, census matches the
      planning measurement, header names the producer HEAD.
- [ ] Phase 2's sandbox arms behave as stated.
- [ ] `Rscript scripts/fp_provenance-check.R` and `uv run python scripts/prov_fields-check.py`
      still clean (nothing in the reader or the validator literals moved).
- [ ] `grep -n "PROV_FIELDS" scripts/prov_census-measure.R` shows a parse, not a vector.
- [ ] `/code-check branch` clean (three-round floor)
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
