# Progress — catalogue_release.sh --only <item_id> (#36)

## Session 2026-09-01

- Plan-mode exploration — phases approved by user; Plan-agent review (12 findings) folded in pre-baseline
- Created branch `36-catalogue-release-sh-only-item-id-suppor` off main
- Scaffolded PWF baseline from issue #36 with approved phases
- User: "Go all phases to pr" — Phase 5 pilot is authorised
- Next: start Phase 1
- Phase 1: `catalogue_release-check.sh` written. On unmodified main: case 2 control green (2 root-source syncs — assets then JSON — one `--include *.json` sweep, one `load collections`), interlock control green, everything `--only` red (unknown option). 12 red assertions to turn.
- Phase 2: `--only` implemented; check 33/33 → 37/37 after adding the live-item read-back (round-1 review's unflagged note) with its negative case 6. Case 6 first went green on a broken fixture (`sed` without `g` altered the wrong asset's checksum) — the harness now prints the run tail on any FAIL.
- Phase 3: defect restored (sweeping sync under `--only`) → 3 red; reverted → all pass. First restore attempt silently did nothing (Python quoting); see findings.
- Phase 4: README Pilot section, release table, smoke-test paragraph + flag row; `test_pipeline.R` header and closing hint; CLAUDE.md Publish bullet.
- Phase 5 prep: `WSG=bulk Rscript scripts/test_pipeline.R` on this branch — 48 s, 0 errors, all outputs rewritten, `valid: 1 item(s) + 1 collection(s)`, COG layout valid, RAT embedded.
- /code-check round 1: Clean (`review-round1.md`). Round 2 on the delta pending.
- /code-check round 2: 2 findings, both real, both fixed — the live-item read-back compared only the probe asset (a byte-stable upstream gpkg), so a stale pgstac row passed on exactly the COG-only pilot case; now every asset from the same GET. Case 6 stales one non-largest asset (the no-`g` sed that was the "bug" an hour earlier is the right fixture) — red on the old compare, green on the new. README step-5 row updated. Round 3 pending.
- /code-check round 3: 1 finding, real — checksum equality is a proxy; a labels/provenance/numbers-only republish would pass a stale row. Measured first that pgstac returns the document verbatim (mixed `Z`/`+00:00` datetime strings round-trip), then switched the read-back to wholesale `assets` + `properties` equality; case 7 stales a property with no byte changed. 41/41. The build's 11 `nge:` properties are all null, so the pilot's read-back will also answer whether pgstac preserves explicit nulls (untested until now).
- Phase 5: pilot run 1 published everything and then reported INCOMPLETE on the 11 null `nge:` properties — pgstac stores nulls, the API omits them (measured on the row). Read-back now treats build-null/live-absent as equal; fixture mirrors the API. Run 2: RELEASE COMPLETE in 30 s, collection unchanged at 20. Live BULK verified from S3/API: assets equal, cog_validate True, RAT 9/81 rows, labels present.
- Commits: a46e9cb (test), 62c4f5b (impl), 9d00f86 (docs), + this one (null rule + pilot evidence). Next: /planning-archive, /gh-pr-push.
