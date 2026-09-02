# Task: Versioned catalogue releases: STAC Version Extension stamp + NEWS.md + git tags (#14 item 3) (#19)

#14 delivered the converged catalog system but deliberately deferred item 3 of its own
proposal: versioned releases (STAC Version Extension stamp on the collection + `NEWS.md` + git
tags). The orchestration half shipped (`scripts/catalogue_release.sh`); the versioning half did
not. Today you cannot ask the live catalog *which release it is* — nothing ties the live state
to a commit, and the release verify can only compare id sets because there is no version to
compare. State at planning (2026-09-02): `git tag -l` empty, no `NEWS.md`, live collection
carries no `version` and no `stac_extensions`; live count is **20** items (the issue says 17).

## Two decisions the exploration changed

**1. Stamp at release time, not build time.** The issue proposes stamping in the build script
from `git describe` (uav's shape). `stac_dem_bc` moved away from that deliberately: a version
means *"the published catalogue is in this state"*, so it is written only by the release path.
The rebuild precedes the tag in every real flow, so a build-time stamp is the previous tag by
construction; and `git describe` fails on a tagless clone, where uav's `0.0.0` fallback publishes
a silently wrong stamp. So `catalogue_release.sh` stamps `data/stac/collection.json` in
preflight, only on a full release, from the tag HEAD sits on exactly. The build never carries a
version.

**2. Release ordering follows uav:** tag the NEWS commit on the feature branch, release from it,
commit the evidence, then merge. `/gh-pr-merge`'s bookkeeping reads `Version:` from
`DESCRIPTION`, which this repo (like uav and dem) does not have — recorded in findings, surfaced
at merge, owned by soul#62.

**Assumption:** first versioned release is **v1.0.0**.

```
full release:  NEWS top == tag on HEAD (exact)  ->  stamp collection.json  ->  validate (gate)
               -> sync -> register -> verify: live.version == stamped, else RELEASE INCOMPLETE
--only:        no stamp, no NEWS/tag gate (said out loud); verify: live.version unchanged
```

## Phase 1: Rename `05_stac_register.py` → `item_create.py`

Mechanical, first, so every later diff already uses the new name. `git mv`, then move the
live references (archives under `planning/archive/` stay as history):

- [x] `git mv scripts/05_stac_register.py scripts/item_create.py`; drop the "misnomer" paragraph
      from its docstring and update its own usage line
- [x] `scripts/run_pipeline.sh` (step banner + command), `scripts/test_pipeline.R:55-56,155`
- [x] `scripts/item_validate.py` comments (lines 44, 81, 152, 343), `scripts/01_stage.R:37`,
      `scripts/catalogue_release.sh` ("the shape 05 emits"), `scripts/catalogue_release-check.sh:34`
- [x] `README.md` pipeline table, `scripts/README.md` rebuild table (drop "misnomer kept until…"),
      `CLAUDE.md` Layout bullet
- [x] Verify: `git grep -n 05_stac_register -- . ':(exclude)planning/archive'` is empty;
      `uv run python -m py_compile scripts/item_create.py`; `bash -n` on the two shell scripts;
      `bash scripts/catalogue_release-check.sh` still ALL PASS

## Phase 2: Version stamp + release gates

- [ ] New `scripts/collection_version.py <collection.json> <version>` — stdlib only (the release
      side uses `python3`, not `uv`, and the check harness shims `uv` away): adds
      `https://stac-extensions.github.io/version/v1.2.0/schema.json` to `stac_extensions` if
      absent and sets `version`; refuses an empty or non-`X.Y.Z` version; idempotent; prints
      what it wrote. Mirrors dem's `version_stamp`.
- [ ] `catalogue_release.sh` step 0, full release only: `VERSION` from
      `git -C "$REPO" describe --tags --exact-match HEAD` (strip `v`), refuse if HEAD is not
      tagged ("tag the NEWS commit first"); refuse if `git status --porcelain --untracked-files=no`
      is non-empty (the tag must describe the scripts that run); refuse unless the top `## v…`
      heading of `NEWS.md` equals `VERSION`; then stamp `collection.json` **before** step 1 so the
      validator gates the stamped document. Under `--only`: none of this, said out loud, and the
      live `version` is read and remembered (absent allowed)
- [ ] `catalogue_release.sh` step 5: full → read `version` from `$API`, compare to `VERSION`
      (`MISSING` when absent), `fail=1` on mismatch with both values printed; `--only` → must
      equal the preflight read (absent == absent is unchanged). The completion line names the
      version
- [ ] `item_validate.py`: one absolute consistency check on the collection — `version` present
      iff the Version Extension is declared, and if present it matches `^\d+\.\d+\.\d+$`
      (pystac's schema validation covers the declared-ext direction; this covers the other)
- [ ] Docs: `scripts/README.md` release table (step 0 gains the tag/NEWS gate + stamp, step 5 the
      version assert) and a short "Cut a release" recipe (NEWS entry → tag → rebuild →
      `catalogue_release.sh`); `README.md` Guards gains the version line; `CLAUDE.md` Catalog
      registration gains a versioning paragraph (release-time stamp, why not build-time,
      `--only` never moves the version)

## Phase 3: Prove it in `catalogue_release-check.sh`

The harness runs the real script against shims; today its curl shim has no branch for the
collection URL (it would 404 into the fixture path) and `git` would read the real repo.

- [ ] Run the release from a throwaway git repo: copy `scripts/` into `$WORK/repo`, write a
      `NEWS.md` whose top heading is `## v9.9.9`, commit, `git tag v9.9.9`. `REPO` resolves from
      the script's own location, so no override flag is needed — the gate runs for real
- [ ] curl shim: a `*/collections/$COLL` branch (exact, before the `*/items/*` one) serving the
      fixture `collection.json` as stamped, or `FAKE_LIVE_VERSION` when set (`none` → key absent)
- [ ] Cases: case 2 (positive control) also asserts the stamp landed on disk and
      "live collection version 9.9.9" was verified; **8** live version stale → RELEASE INCOMPLETE
      naming both versions; **9** live version absent → INCOMPLETE; **10** HEAD not at a tag →
      refused, no aws call; **11** NEWS top ≠ tag → refused, no aws call; **12** `--only` leaves
      `collection.json` byte-identical (no `version` key) and passes with absent == absent
- [ ] Restore-the-bug: with the step-5 compare commented out, case 8 must go red; with the
      stamp line removed, case 2 must go red. Record both in `progress.md`
- [ ] Verify: `bash scripts/catalogue_release-check.sh` → ALL PASS, exit 0

## Phase 4: NEWS.md, v1.0.0, first versioned release

- [ ] `NEWS.md`: header paragraph in dem's words (versions describe the published catalogue,
      a tag means "the catalogue is in this state", scripts are not versioned separately), then
      `## v1.0.0 (YYYY-MM-DD)` summarising what is live: 20 items across the rostered groups,
      per-item assets (4 COGs + 3 GeoPackages), class-label RAT + `classification:classes`
      (#34/#35), `file:checksum` (#22), `nge:` provenance (#17), transition vector (#23), COG
      layout (#33), `--only` pilot path (#36), and this release system
- [ ] Commit the NEWS entry, `git tag v1.0.0` on that commit, push the tag
- [ ] Full rebuild: `bash scripts/run_pipeline.sh` (needs `$FLOODPLAINS_DATA`, present on this
      machine; ~20 min of COG conversion). The local tree is a one-group pilot build today
      (`data/raw/PARTIAL_STAGE` = bulk), so this is required, and it also brings the 19 items
      published before #26/#33/#34/#35 up to date — the full release the memory notes anticipate
- [ ] `bash scripts/catalogue_release.sh` → RELEASE COMPLETE naming v1.0.0
- [ ] Acceptance: `curl -s $API | jq .version` → `"1.0.0"`; `jq .stac_extensions` lists the
      Version Extension; 20 items live; `git tag -l` and `NEWS.md` top agree. Paste the three
      reads into `progress.md`
- [ ] Note for merge: `/gh-pr-merge` bookkeeping is n/a (tag already cut on the release commit,
      no `DESCRIPTION`); open a soul issue if the skill mis-handles a NEWS-only repo, referencing
      soul#62

## Validation

- [ ] `bash scripts/catalogue_release-check.sh` ALL PASS on every commit that touches the release path
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
