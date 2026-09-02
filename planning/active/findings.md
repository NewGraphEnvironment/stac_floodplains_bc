# Findings — Versioned catalogue releases: STAC Version Extension stamp + NEWS.md + git tags (#14 item 3) (#19)

## Issue context

## Problem

#14 delivered the converged catalog system but **deliberately deferred item 3 of its own proposal**:

> 3. **Versioned releases** — STAC Version Extension stamp on the collection + `NEWS.md` + git tags; a `catalogue_release.sh` orchestrating rebuild → validate → sync → register → verify

The orchestration half shipped (`scripts/catalogue_release.sh`). The **versioning** half did not, and #14 is now closed with "versioned releases" in its title — so the history reads as though this landed. It didn't.

Concretely, today you cannot ask the live catalog *which release it is*. You can see 17 items and their figures, but nothing ties that state to a commit. When a published number changes, there is no way to say "that was v1.2.0, this is v1.3.0" — which is exactly the question a report citing these figures will eventually raise.

It is also why this repo's release verification is weaker than `stac_uav_bc`'s. Theirs asserts the live collection's `version` matches the release just published; ours can only compare id sets, **because there is no version to compare**. That was a deliberate consequence of deferring, recorded at the time, not an oversight.

State today: `git tag -l` is empty, no `NEWS.md`, and the collection carries no `version` field or version extension (`stac_extensions` is absent entirely on the collection; items declare only Projection).

## Proposed solution

1. **Stamp the collection.** Add `https://stac-extensions.github.io/version/v1.2.0/schema.json` to the collection's `stac_extensions` and a `version` field, sourced from the git tag (`git describe --tags --abbrev=0`, `v` stripped). `stac_uav_bc`'s `item_create.py` does exactly this in ~10 lines; its live collection currently reports `"version": "1.0.1"`.
2. **`NEWS.md`** with a `## vX.Y.Z (YYYY-MM-DD)` entry per release, matching the `stac_uav_bc` format.
3. **Git tags per release**, cut on the NEWS-entry commit (uav tags the NEWS commit, then runs the release, then commits the verification evidence).
4. **Strengthen `catalogue_release.sh` verify** — assert the live collection's `version` matches the release, in addition to the existing set-identity check. This is the payoff: the release becomes self-verifying rather than only self-consistent.
5. **Rename `05_stac_register.py`.** It registers nothing since #14 — it only builds JSON. The rename was deliberately deferred to here so its ~10 references move once rather than twice. `item_create.py` matches the converging convention (soul#62).

## Consequence worth flagging before starting

`/gh-pr-merge` gates release bookkeeping on `DESCRIPTION`/`NEWS.md` existing. Every merge in this repo so far has printed *"non-versioned repo — skipping release bookkeeping"*. Adding `NEWS.md` switches that on: future merges will auto-bump semver and cut tags. That is the intent, but it changes the merge workflow and should not be a surprise.

## Not the same as #17

Version says **which release** an item belongs to; provenance (#17) says **which inputs** produced it. Two items can share a version and differ in provenance if the landcover source drifted between runs. Both belong, at different granularities.

## Acceptance

- `curl https://images.a11s.one/collections/stac-floodplains-bc | jq .version` returns the tag just released
- A release whose stamp does not reach the API **fails** rather than reporting success
- `NEWS.md` and `git tag -l` agree with the live version
- `05_stac_register.py` renamed with all references updated

Follow-on from #14 (item 3). Relates to NewGraphEnvironment/soul#62, NewGraphEnvironment/stac_dem_bc#27.



## Exploration (2026-09-02, plan mode)

### State measured

- `git tag -l` is empty; `git describe --tags --abbrev=0` exits 128 (`No names found`).
- Live collection (`GET /collections/stac-floodplains-bc`) keys: description, extent, id,
  license, links, stac_version, summaries, title, type. No `version`, no `stac_extensions`.
- Live item count via fielded `/search`: **20** (issue body says 17 — stale since #11/#36).
- Local `data/stac` is a one-group pilot build (`bulk_co_ff04`, 2 JSON docs) with
  `data/raw/PARTIAL_STAGE` = `bulk`. A full release needs `run_pipeline.sh` first.
- `$FLOODPLAINS_DATA` default (`../floodplains/data`) is present on this machine with 21 group
  directories, so the full rebuild is feasible here.
- No `.github/` — no CI. `.claude/settings.local.json` is untracked (only `.claude/visibility`
  is tracked), so its `05_stac_register.py` permission string is not a reference to move.

### Live references to `05_stac_register.py` (outside `planning/archive/`)

`README.md:64`, `CLAUDE.md:18`, `scripts/README.md:25`, `scripts/catalogue_release-check.sh:34`,
`scripts/catalogue_release.sh` ("the shape 05 emits"), `scripts/test_pipeline.R:55-56,155`,
`scripts/run_pipeline.sh:44`, `scripts/item_validate.py:44,81,152,343`, `scripts/01_stage.R:37`,
and the file's own docstring (lines 1, 24-25, 28).

### Reference implementations (all read in full)

- **stac_uav_bc** `scripts/item_create.py:114-125` — `stamp_version()` appends the Version
  Extension URL and sets `extra_fields["version"]`; `git_version()` is
  `git describe --tags --abbrev=0` with a `0.0.0` fallback on error. Stamped at build
  (`--rebuild`), which its `catalogue_release.sh:18-22` runs *inside* the release with
  `--version "$VERSION"`, so in practice uav also stamps at release time.
  `catalogue_release.sh:38-42`: verify reads `.version` from the API (`MISSING` if absent) and
  exits 1 on mismatch. Tags: `v1.0.0`, `v1.0.1`, both cut by hand on a NEWS commit **on the
  feature branch** (`9bc972e (tag: v1.0.1) Phase 2 (#18): ... NEWS for v1.0.1`), release run,
  evidence committed, then merged.
- **stac_dem_bc** `scripts/collection_patch.py:120-160` — `version_stamp()` refuses an empty
  version; docstring: *"A version here means 'the published catalogue is in this state' — the
  NEWS.md convention — not 'the scripts changed'. So it is only ever written at release time,
  by the release path, with a version passed in explicitly. Deliberately NOT derived from
  `git describe` inside this script."* `version_clear()` exists because the monthly append
  makes the previous version *false* rather than stale. Tag `v2.0.0` on `f9de569 Release
  v2.0.0 in NEWS`, cut by hand on main after the PR merged. `DESCRIPTION` there is a
  dependency manifest pinned at 0.0.0.9000 and explicitly not versioned.
- **dem NEWS.md header** (adopted here): "Versions describe the **published catalogue** … a
  tag means 'the catalogue is in this state'. Same convention as stac_uav_bc."

### `/gh-pr-merge` and a NEWS-only repo

The issue predicts that adding `NEWS.md` makes the skill auto-bump and tag on every merge.
Reading `~/.claude/commands/gh-pr-merge/SKILL.md:147-204`: the gate is
`[ ! -f DESCRIPTION ] && [ ! -f NEWS.md ]`, so `NEWS.md` alone does switch bookkeeping *on* —
but step 6 then runs `CURRENT_VERSION=$(grep '^Version:' DESCRIPTION ...)`, which errors on a
repo without `DESCRIPTION`, and step 7 edits `DESCRIPTION`. Neither uav nor dem has one, and
neither's tags came from the skill. So on this repo the skill will not cleanly auto-tag; the
tag is cut by the release flow (uav ordering). Convention owner: soul#62 ("Convention: stac
catalog repos … versioned registry"), still OPEN.

### Check harness gaps the version work must close (`catalogue_release-check.sh`)

- The curl shim has no branch for the collection URL. A `GET $API` without `-w`/`-I` falls to
  the fixture-path branch (`${url#*.amazonaws.com/}` is the whole URL) and exits 22.
- `REPO` resolves from the script's own path, so a `git describe` inside the release would read
  the real repo. Copying `scripts/` into a throwaway tagged git repo under `$WORK` runs the real
  gate with no override flag.
- `uv` is shimmed to a logger, so the stamp must not go through `uv` — `python3` + stdlib.

## Errors Encountered

| Error | Resolution |
|-------|------------|
