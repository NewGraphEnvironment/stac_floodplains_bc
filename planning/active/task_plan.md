# Task: Publish v2.1.0 — the last box on #98

Issue #98 has one box left: **restage and republish every whole-network item.** Everything
else closed in #99 (merged `44dc70c`). The catalogue still serves the v2.0.1 figures, so
until this release runs the published `floodplain_ffNN_km2` are whole-footprint numbers
and this repo's own README refuses to render (`README_MIN_VERSION <- "2.1.0"`).

The box is open rather than done because the build on disk is **stale against the publish
code**: `data/stac` was written 2026-10-19 02:35 and `d77fd36` landed at 02:41, editing
`item_create.py`'s asset and collection description prose.

**No feature branch.** `catalogue_release.sh` refuses unless HEAD is exactly at a `vX.Y.Z`
tag with a clean tracked tree and `NEWS.md`'s top entry naming that version; both prior
tags sit on main. PWF is committed **before** the tag, and these boxes tick after the
release — `scripts/README.md`: "Between the tag and the release, touch nothing tracked".

## Phase 1: Rebuild the tree the release is cut from

- [ ] `bash scripts/run_pipeline.sh` — full rebuild, wipes `data/`. No `WSG_ONLY`,
      `ALLOW_SKIPPED` or `ALLOW_DRIFT_SKEW`.
- [ ] 23 item directories + 23 item JSONs + `collection.json`, and the run's own
      `=== VALIDATE ===` exits 0.
- [ ] Record the build's printed twelve provenance counts and its metric-scope line. These,
      not any paragraph in `NEWS.md` or `CLAUDE.md`, are what the literals are set from.

## Phase 2: Hand-run guards, and re-take the literals from this build

- [ ] `uv run python scripts/claim_drift-check.py`
- [ ] `uv run python scripts/attribution_drift-check.py`
- [ ] `Rscript scripts/prov_census-measure.R` — the pre-flight, not the authority
- [ ] Re-take `PROVENANCE_FLOOR`, `PROV_CENSUS`, `METRIC_SCOPE_CENSUS`; edit only if the
      build disagrees, and commit that edit on its own
- [ ] `item_validate.py --base data/stac --expect 23 --expect-provenance <floor>` exits 0

## Phase 3: Date, commit, tag

- [ ] Commit the PWF triple (the tag commit must leave a clean tree)
- [ ] `NEWS.md`: `## v2.1.0 (unreleased)` -> `## v2.1.0 (YYYY-MM-DD)`
- [ ] Commit `NEWS: date v2.1.0 to the day it is released`
- [ ] `git tag v2.1.0` — local only

## Phase 4: Release

- [ ] Report the gate, then on the user's go:
      `AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=10 bash scripts/catalogue_release.sh`
- [ ] Verify on the bytes a consumer downloads: fetch one published GeoPackage from the
      bucket, `ogrinfo -so` it, compare sha256 with the local build
- [ ] API and bucket `collection.json` both serve version `2.1.0`

## Phase 5: Post-release

- [ ] `git push origin v2.1.0`, push main
- [ ] Step 6 README regen — `github_document` then `html_document`, in that order
- [ ] Tick #98's last box and close it
- [ ] `/planning-archive` -> `2026-10-issue-98-release-v2.1.0`

## Validation

- [ ] Tests pass
- [ ] `/code-check` on any literal or NEWS edit this release makes
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
