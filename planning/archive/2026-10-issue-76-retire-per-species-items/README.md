# Retire the per-species floodplain items as each group's whole-network item publishes (#76)

**Outcome:** the publish layer gained a retirement mechanism it did not have. `--allow-retract`
*permitted* publishing past a live item absent from the build and never removed one, so
`RELEASE COMPLETE` printed with the retired items still live — under floodplains#125 that is a
group served two floodplains on different networks and, after floodplains#117, different DEM
grids, with nothing in either item saying which is current. `RETIRED_ITEMS` now names the ids a
release removes, arms in step 0 check the literal against the catalogue and the release notes,
step 6 unregisters them after every probe has passed, and step 7 requires the served set to equal
the build. `scripts/item_retract_s3.sh` is the irreversible half, kept out of the release so the
pgstac delete stays reversible from the bucket copy until it runs.

**Nothing published changed.** No `*_all_ff04` item is live and no release can be cut: 13 of the
23 rostered groups have no whole-network rasters on disk (measured 2026-10-14), DUNC is blocked by
floodplains#133, and MCGR's `area.yml` names a scenario it cannot build. This is the mechanism the
cutover needs, proved against the synthetic harness.

Closed #79 by construction. Filed #86 (a public repo naming a private sibling, pre-existing) and
#87 (mechanism E's two pre-existing members).

**Closing commits:** `178ef1d` (baseline) … `/gh-pr-push` PR on branch
`76-retire-the-per-species-floodplain-items`.

## Measurement

**The migration is one release, not one per group** — the issue asked for per-group retirement and
it is not achievable: `--only` cannot publish a never-live item, and `fp_readme_check_complete()`
refuses any API/bucket item-count mismatch. The first full release after floodplains#125 retires
all 17 per-species items and adds 17 whole-network ones. Corrected in #76's body and on
floodplains#125.

Upstream state, 2026-10-14: 17 of 23 `area.yml` name `all_ff04`, but only `bulk`, `dunc`, `kisp`
and `morr` hold `rasters/all_ff04/`. A full rebuild stages 10 of 23 and writes `PARTIAL_STAGE`.

`ALLOWED_YEAR_SETS` needs no change — measured, not assumed: both sanctioned sets keep users
(`kotl_bt_ff04` stays `bt_ff04` and is annual, `bulk_all_ff04` is annual).

**Two guards of this repo's own had silently stopped proving anything**, both defaulting to a group
that can no longer stage. `stage_years-check.R` printed `0 assertions, 0 failed, 1 skipped — the
call site was NOT proven` on its documented invocation; it is 13 assertions on `bulk`.
`test_pipeline.R` stopped at `no items staged for UFRA`.

### What review cost and what it bought

Five `/code-check` rounds, 25 reviewer findings, 7 more from walking the classes, 1 disproved.
**Two could have damaged a bucket with versioning Suspended:**

- `item_retract_s3.sh --yes collection` **deleted the published `collection.json`**. All three
  guards missed it; the only one that caught it did so by accident and is skipped when `data/stac`
  is absent — a release-only machine, which is what that script is for.
- `--skip-sync` on a release that **adds** items published a `collection.json` linking objects
  never uploaded. A reload-from-S3 deletes the collection's rows, then 404s and aborts.

And two instruments could not fail: case 21a's positive control (the stage knob fed it the
post-delete set, so it never exercised the arm it existed to prove) and case 20c (its phrase was
printed by the arm it was *not* testing).

Five mechanisms were named; four are closed here, and E's two pre-existing members are #87.
The convention's rule held exactly: **every round found a defect inside the previous round's fix**,
so a quiet round was never the evidence — the enumerations were, and three of them are now static
cases that go red when a member is reintroduced.

One instrument gave up a claim it could not keep, which is also a measurement:
`case 20-assertions` reads source templates while the suite asserts on rendered output, so it is an
instance of the mechanism it was built to close. A variable-aware matcher was built and rejected —
at LCS thresholds 8 to 20 it reports 29 to 61 of 73 patterns ambiguous, nearly all falsely, and
still leaves 6 to 13 blind. Scoped to verbatim duplicates (4 found, all real) with
`BLIND_FLOOR = 42` recording the gap. **Class D's terminator is the mutation table.**

Final: **222 assertions, 41 harness cases, 42 guards mutated** — all red but two recorded as
implied or correctly-green, and two classes closed statically where no fixture can reach them.

## Evidence

`planning/archive/2026-10-issue-76-retire-per-species-items/findings.md` — the measurements, the
seven mutation tables, and the five rounds' findings with what each one disproved.
`review-round1.md` … `review-round5.md` — the reviewers' own reports, as delivered.

Mutation tables are reproducible: disable the named arm in `scripts/catalogue_release.sh` or
`scripts/item_retract_s3.sh` and run `bash scripts/catalogue_release-check.sh` (synthetic, ~35 s,
no network, no credentials).

## Errors worth keeping

- I committed during round 4's review, so it briefly read a file mid-edit. It snapshotted and said
  so. Editing files a long review is reading is what the convention forbids, and I had held to it
  until then.
- I ran `test_pipeline.R` in the background while `stage_years-check.R` was running. Both own
  `data/`, so the second reported `1 failed` — on the assertion that exists to notice exactly
  that. Serially, 0 failed.
- Two of the first mutation round's "STILL GREEN" rows were the mutation patching inside a branch
  the case never enters. The probe was broken before the world was, and a mutation table is itself
  a probe.
