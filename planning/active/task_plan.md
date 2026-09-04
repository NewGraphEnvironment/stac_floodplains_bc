# Task: Published floodplain items were built with the flooded bankfull units defect and are over-mapped (#26)

Every floodplain product in the live catalogue was built with the `flooded` bankfull units
defect (fixed in `flooded` 0.5.0). `fl_flood_surface()` fed hectares and millimetres into
Hall et al. coefficients that take km² and cm/yr, so bankfull depth was **3.5926x** too
large: a `ff04` item is a waterline at ~14x bankfull depth, not the functional floodplain
its id claims. Areas cannot be scaled — the items had to be rebuilt.

**That rebuild is already on disk.** `data/stac` holds 23 items, 21 carrying
`nge:flooded_version = "0.5.0"`, no `PARTIAL_STAGE` marker. This issue is what remains:
mark the two items that could not be re-run, and publish.

**Measured 2026-09-03/04:**

| fact | value |
|---|---|
| local build | 23 items; live 20; **0 orphans** |
| new (not rebuilds) | `thom_ch_ff04`, `lnth_ch_ff04`, `unth_ch_ff04` |
| carrying a non-null `nge:` value | **21** of 23 → `PROVENANCE_FLOOR=21` (already set) |
| carrying **zero** non-null `nge:` values | exactly `mcgr_ch_ff04`, `pine_bt_ff04` |
| `nge:flooded_version` | `0.5.0` on 21, null on those same 2 |
| item `stac_extensions` | 3 on all 23 (projection, file, classification) |

`mcgr` and `pine` cannot be re-run (floodplains#76: MCGR absent from `fresh`; PINE diverges
10.8% from the bcfp reference). Holding the release for them would block 18 corrections
indefinitely, so they publish **marked** rather than withheld.

**Decisions already made, not re-opened here:** publish 23 items with the 2 marked
(airvine, 2026-09-03); `PROVENANCE_FLOOR=21`; #46 and #47 land first as merged code with no
release between — both done, so one tagged release carries all three.

**Version — v1.1.0.** `v2.0.0` is reserved for the release where *all* data is corrected,
and `mcgr`/`pine` are not (airvine, 2026-09-04). This decision was never written down
anywhere — not in #26, #19, the archived PWFs or memory — which is why it had to be
recalled rather than read. Phase 4 records it.

## Phase 0: Clear the decks

- [ ] `/planning-archive` #47's PWF to `planning/archive/2026-09-issue-47-collection-licence/`. Its code shipped in PR #51; its **Phase 6 was this release**, and that work transfers here rather than being tracked in two places
- [ ] Confirm `data/stac` is still the 23-item corrected build and the tree is clean before anything is written

## Phase 1: Mark the two items that cannot be re-run

`scripts/item_create.py`.

- [x] `DEPRECATED_ITEMS = {"mcgr_ch_ff04", "pine_bt_ff04"}` — a hardcoded literal a human sets, the same shape as `PROVENANCE_FLOOR` (#32) and for the same reason: an expectation derived from the data cannot be contradicted by it
- [x] On exactly those items, set `deprecated: true` and add `VERSION_EXT` (`version/v1.2.0`) to that item's `stac_extensions`. The other 21 carry neither — the extension defines `deprecated` with `default: false`, so absence is a statement here, unlike the `nge:` nulls (#31/#36) where it is not
- [x] Comment why a positive marker is needed at all: both already differ by carrying null on all twelve `nge:` properties, but **the API drops nulls**, so from outside a consumer sees only that two items *lack* a field
- [x] Regenerate: `uv run python scripts/item_create.py`

## Phase 2: Guard it, and make it self-clear

`scripts/item_validate.py`. A new `check_deprecated(base)`, absolute like `check_provenance`.

- [x] **Set equality**, not containment: exactly `DEPRECATED_ITEMS` carry `deprecated: true`. Catches both a marker that spread and one that was dropped
- [x] **Every id in the literal exists in the build** — a stale id after a rename would otherwise make the set compare vacuous on a name nothing publishes
- [x] **Biconditional**: an item declares `VERSION_EXT` iff it carries `deprecated`. The extension's Item branch has no `required`, so declaring it with no field validates clean — the #34/#35 trap, and pystac cannot see the other direction at all
- [x] **Self-clearing** — the point of the phase. Refuse when an item marked deprecated carries a **non-null `nge:flooded_version`**. This is written data that outlives the fix: when floodplains#76 unblocks and `mcgr` is rebuilt, nothing would remove it from the literal and it would publish as deprecated forever. The first corrected build then fails the release until the entry is deleted
- [x] Say in the comment what that guard actually encodes — "deprecated **here** means not-rebuilt". It couples the marker to the absence of provenance, which is true by construction today and would misfire on an item deprecated for some other reason while carrying provenance
- [x] Run it **before** `check_checksums`, as `check_citation_premise` does, so a proof cannot be short-circuited by the 670 MB re-read (#46)

## Phase 3: Restore each bug and prove the guard fires

- [x] Positive control: clean tree, validator green, the new summary line prints
- [x] Mutate the **source** (`item_create.py`'s literal, or `meta.json` for the provenance arm), rebuild, validate, and **grep the output for that guard's own message** — never the exit status (#46, and it caught a false premise in #47)
- [x] One proof each: the literal emptied; a third id added; an id that is not in the build; `deprecated` set without `VERSION_EXT`; `VERSION_EXT` without `deprecated`; and a deprecated item given a non-null `nge:flooded_version` (the self-clear)
- [x] Assert each mutation took before believing what follows, and record the table in `findings.md`

## Phase 4: Release bookkeeping

- [x] `NEWS.md`: fold the `## Unreleased` block (already carrying #46, #40, #32, #47) into a `## v1.1.0 (YYYY-MM-DD)` entry that leads with the geometry correction — 18 items rebuilt, per-item before/after from the issue's table, 3 new Thompson items, 2 published deprecated
- [x] **Record the version convention** in `NEWS.md`'s header, beside the existing "a tag means the catalogue is in this state": `v2.0.0` is reserved for the release where every area is corrected. This is the decision that was lost; write it where the next person reads it
- [x] Verify `PROVENANCE_FLOOR=21` is still what the build prints (it is, but the floor is exact in both directions, so re-read it rather than trust)
- [x] `/code-check` — 3 rounds, 20 findings, all fixed, none dismissed. Each round found defects inside the previous round's fixes; round 3's headline was round 2's own mechanism recurring on its mirror arm. Harness 100 -> 111 assertions. Three factual errors caught in the release note itself

## Phase 5: Cut the release

Publishes to `s3://stac-floodplains-bc`, versioning **Suspended — no rollback**.

- [x] Commit `NEWS.md`, tag `v1.1.0` by hand on that commit (as `stac_uav_bc` does; no `DESCRIPTION` here, so `/gh-pr-merge`'s bump path stays out of it)
- [x] `bash scripts/catalogue_release.sh` — validate → sync → register → verify. No orphans, so no `--allow-retract`
- [x] This is the first release where step 5's licence read-back runs for real, and the first test of whether `rel: license` / `rel: derived_from` survive pgstac's `get_links()` on this deployment — read from source, never measured here. A drop fails the release **after** the sync and the pgstac load
- [x] Push the tag only once the release has succeeded

## Phase 6: After the release

- [x] `python3 scripts/readme_coverage-table.py --write` — 23 items from the live API, committed past the tag by design (#41)
- [x] Confirm from the API: 23 items, `version: 1.1.0`, `license: CC-BY-4.0`, and `deprecated: true` served on exactly the two
- [x] Close #26 and #47 — #47 was deliberately left open at merge because its verification is a live-API read that only this release can satisfy
- [x] Update the `published-assets-stale-vs-main` memory: the catalogue is corrected except for two marked items, and `v2.0.0` awaits floodplains#76

## Validation

- [x] `bash scripts/catalogue_release-check.sh` green — 111 assertions, 0 FAIL; cases 9k/9l/9m added and each proved to discriminate
- [x] `uv run python scripts/item_validate.py` green on 23 items
- [ ] `/code-check` clean on each commit
- [x] PWF checkboxes match landed work; `/planning-archive` on completion
