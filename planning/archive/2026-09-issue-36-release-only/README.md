# catalogue_release.sh --only <item_id> (#36)

## Outcome

A single live item can now be republished with one command — its assets, its JSON, its pgstac
row — and `collection.json` is unreachable by construction: the asset sync's source root is the
item directory, the JSON goes as one explicit `aws s3 cp`, and `collection_register.sh` is never
invoked. The two guards that protect the collection (`PARTIAL_STAGE`, the live-vs-build
comparison) are skipped out loud rather than silently. Piloted on BULK against production the same
session: two runs, the first of which published everything and then reported INCOMPLETE on a
verdict that was wrong, not on a publish that was.

The test came first and it is a harness, not a fixture: `catalogue_release-check.sh` runs the
**real** release script against `aws`/`ssh`/`uv`/`curl` shims and reads their argv. Its shape was
set by a pre-baseline plan review that found the obvious assertion — grep the log for
`collection.json` — could never fire, because the sweeping JSON sync's argv does not contain the
file's name. The assertions pin the *shape* that reaches it (a root-source sync, an
`--include *.json` sweep, `load collections`), and the positive control is a full release found by
the same greps. Restoring the sweep under `--only` turns three assertions red.

Three review rounds each moved the step-5 read-back one notch: from "endpoint 200" (true before
the release too), to the probe asset's checksum (a byte-stable upstream gpkg, so a COG-only
republish — the pilot case — would pass a stale row), to every checksum (blind to labels,
provenance and the loss/gain numbers, which change no byte), to the whole document. pgstac was
measured to return the document verbatim before that last step was taken.

## Measurement

- Live collection is **20** items; the issue, README and CLAUDE.md say 17.
- BULK rebuild on this branch: 48 s. Pilot run 1 (full publish, 8 uploads, wrong verdict): ~1 min.
  Run 2 (idempotent, 1 upload, RELEASE COMPLETE): 30 s.
- **pgstac stores explicit null item properties; the API omits them.** On the row, all 11 `nge:`
  keys present with `jsonb_typeof` null; from the API, absent. Every non-null value and every
  asset field round-trips byte-for-byte. This was the untested premise of #17's null-publishing
  design; the read-back now treats build-null / live-absent as equal, and an API consumer cannot
  see a published null at all.
- Live BULK after the pilot, read from S3/API: assets equal the build (7/7 checksums),
  `classification:classes` present, `cog_validate` True, RAT 9 rows / 81 rows, `NGE_PROVENANCE_NULL`
  the only provenance tag (as designed), `net_ha` −738.2. It is the one item of 20 carrying #26,
  #33 and #34/#35; the other 19 are the old vintage until a full release.
- Wrong turns kept: a defect-restore that silently did nothing (Python quoting) and printed ALL
  PASS on the good code; a case-6 fixture that staled the wrong asset because `sed` had no `g` —
  and then turned out to be exactly the right fixture once the compare widened.

## Evidence

`pilot_bulk-*.log` in this directory; `review-round*.md` and `review-36.md` for the four reviews;
`findings.md` for the measurements.

Closed by: PR (opened from branch `36-catalogue-release-sh-only-item-id-suppor`)
