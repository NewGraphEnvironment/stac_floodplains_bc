# Progress — catalogue_release.sh --only <item_id> (#36)

## Session 2026-09-01

- Plan-mode exploration — phases approved by user; Plan-agent review (12 findings) folded in pre-baseline
- Created branch `36-catalogue-release-sh-only-item-id-suppor` off main
- Scaffolded PWF baseline from issue #36 with approved phases
- User: "Go all phases to pr" — Phase 5 pilot is authorised
- Next: start Phase 1
- Phase 1: `catalogue_release-check.sh` written. On unmodified main: case 2 control green (2 root-source syncs — assets then JSON — one `--include *.json` sweep, one `load collections`), interlock control green, everything `--only` red (unknown option). 12 red assertions to turn.
