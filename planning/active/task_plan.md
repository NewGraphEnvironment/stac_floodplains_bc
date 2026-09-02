# Task: catalogue_release.sh --only <item_id>: supported single-group republish that never touches collection.json (#36)

A single group can be rebuilt and pushed with one command, so a change can be piloted on
BULK and inspected live before it is cut across all items. Today every pilot is a
hand-assembled sequence of `aws s3 sync` flags whose subtleties are load-bearing and easy to
get wrong in the direction that damages the live catalog. The mechanics are already fine
(`item_register.sh` upserts; the asset sync has no `--delete`); what must never happen is
publishing `collection.json` from a partial build, and the existing step-3 JSON sync sweeps it
in. `--only` replaces that with an explicit single-object copy — and that property gets a
test, not just care.

## Phase 1: Test first — the shim harness and the collection.json invariant
- [ ] Write `scripts/catalogue_release-check.sh`: fixture builder, `aws`/`ssh`/`uv`/`curl` shims (tab-separated `%s` logging), PASS/FAIL runner
- [ ] Case 2 (positive control: root-source `--include *.json` sync + `load collections`) and case 3's interlock control pass against **current** `main`
- [ ] Case 1 and the `--only` refusals in case 3 written; red on current `main` (unknown option) confirmed

## Phase 2: `--only` in `catalogue_release.sh`
- [ ] Arg parsing: `--only <id>`, empty value refused, id shape check, `--allow-retract` combination refused, usage
- [ ] Step 0: item file + dir exist, must be live (`grep -qxF --`), interlock + orphan comparison skipped out loud
- [ ] Steps 2+3 as `skip` / `only` / `full`: per-item asset sync; explicit `aws s3 cp` of the one item JSON
- [ ] Step 4: `item_register.sh` only
- [ ] Step 5: item endpoint 200, membership unchanged by string compare, probes on `$ID`
- [ ] Cases 1–3 green

## Phase 3: Prove the guard can see the defect
- [ ] Restore the bug: make the `--only` step-3 branch run the sweeping sync; case 1 goes red; revert
- [ ] Case 4 (membership change → `RELEASE INCOMPLETE`) and case 5 (checksum mismatch under `--only`) written and green
- [ ] `bash -n` both scripts; `shellcheck` if installed (not on this machine today — not a gate)

## Phase 4: Docs
- [ ] `catalogue_release.sh` header, `scripts/README.md` release table + Pilot section + smoke-test paragraph, `CLAUDE.md` Publish bullet
- [ ] `findings.md`: live count is 20, not the 17 the prose says; review-36.md folded

## Phase 5: Pilot on BULK (publishes to production — user gave the go-ahead: "Go all phases to pr")
- [ ] Rebuild BULK on this branch: `WSG=bulk Rscript scripts/test_pipeline.R`
- [ ] `bash scripts/catalogue_release.sh --only bulk_co_ff04`; capture the log, including the `valid: 1 item(s) + 1 collection(s)` line, into `findings.md`
- [ ] Confirm live: `cog_validate` on a published BULK COG via `/vsicurl/`, RAT present, membership still 20

## Validation

- [ ] Tests pass
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
