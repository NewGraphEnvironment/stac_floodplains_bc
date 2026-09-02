# Review round 1 — `catalogue_release.sh --only <item_id>` (#36)

Reviewed the staged diff of `scripts/catalogue_release.sh` against the Shell Scripts checklist in
CLAUDE.md, with `catalogue_release-check.sh`, `item_register.sh`, `item_unregister.sh`,
`item_validate.py`, `01_stage.R`, `05_stac_register.py`, `test_pipeline.R` and `scripts/README.md`
read for context.

## Verdict: Clean

No real issue found. Every claim below was measured, not reasoned.

## What was run

| probe | result |
|---|---|
| `bash scripts/catalogue_release-check.sh` (bash 5.3.9) | ALL PASS, 33/33, rc=0 |
| same, with `bash` resolved to `/bin/bash` 3.2.57 | ALL PASS, rc=0 |
| `bash -n` on the staged script | syntax ok |
| `--only --skip-sync` | rc=1 `suspicious item id: --skip-sync` (the `-*` arm), before any I/O |
| `--only -x` | rc=1, same arm |
| `--only bulk_co_ff04 --only ../x` | rc=1, last value wins and is refused by the class |
| `--only X --skip-sync` and `--skip-sync --only X` | both parse; stop at preflight (empty STAC_DIR) — order-independent |
| `--only X --allow-retract` | rc=1, the explicit combination refusal |
| `--allow-retract --only` (bare, last arg) | rc=1 via `usage`, not an unbound-variable crash — `[ $# -ge 2 ] &&` short-circuits before `$2` is touched under `set -u` |
| `--only collection` | rc=1 at the `-d "$STAC_DIR/collection"` check (see note 3) |

## Checklist items, each checked against the diff

- **Guard failing toward skip** — the must-be-live check is `if ! printf ... | grep -qxF -- "$ONLY"`;
  a grep that cannot run (or an empty `live_ids`) refuses. The step-5 membership compare is a plain
  `!=` on two strings, not `comm ... || true`, so a failed `comm` cannot read as "no difference". Both
  fail toward abort. The combination refusal and the shape check run before `cd`, before any I/O.
- **Empty result set** — an empty `live_ids` cannot pass the live check, so `after_ids != live_ids`
  in step 5 is comparing against a provably non-empty baseline; an API hiccup returning `[]` after
  registration fails the release rather than passing it.
- **`set -e` / pipefail** — `after_ids=$(fetch_live_ids)` (pre-existing) aborts on failure via the
  assignment status. `grep -qxF` early exit cannot SIGPIPE `printf` at these sizes (≤ ~14 KB for the
  1000-item page limit, one write into an empty pipe). Every new mutating call (`aws s3 sync`,
  `aws s3 cp`, `item_register.sh`) is a bare statement under `set -e`, unsilenced, not chained with `;`.
- **bash 3.2** — no arrays, no 4.x-only expansions; the check passes with `/bin/bash`.
- **Quoting** — `$ONLY` is constrained to `[A-Za-z0-9_-]` with no leading `-` before it reaches an S3
  key, a curl URL, a Python string literal (step 5), or `item_register.sh`. Every expansion is quoted.
- **`if/elif/else` placement** — steps 2+3: `if SKIP_SYNC / elif ONLY / else / fi` (183–233); step 4
  `if/else/fi` (238–248); step 5 `if/else/fi` (259–282) with `probe_item` set on both arms. Case 2 of
  the check (full release: two root syncs, one `*.json` sweep, one `load collections`) proves the full
  path is unchanged; the only edits to it are `fail=0` hoisted above the branch and `probe_item` moved
  inside the `else`, both inert.
- **Can any `--only` route reach collection.json?** On S3: step 2's source root is `$STAC_DIR/$ONLY`
  (cannot see the tree root) and step 3 is a single explicit `cp` of `$ONLY.json`. In pgstac: step 4
  calls only `item_register.sh`. The check pins all three (no root sync, no `*.json` sweep, no aws call
  naming `collection.json`, exactly two aws calls, zero `load collections`), and its positive control
  finds those same calls in a full release.
- **`--skip-sync` + `--only`** — steps 2+3 skipped, step 4 registers only `$ONLY`, step 5 probes
  `$ONLY` (size and checksum against S3), so a locally-changed asset that was never uploaded still
  fails the release for the sampled asset, same as the full path.
- **`--expect $n_local` under a one-group tree** — `item_validate.py` has no fixed floor; `--expect` is
  an exact count and refuses only `< 1`. `01_stage.R` wipes `data/stac` on every run including
  `WSG_ONLY`, so the tree is exactly the group's items plus `collection.json` and `n_local` is right.
  The smoke test already runs the validator over this shape.
- **Docs** — `scripts/README.md` (§ Pilot) and `test_pipeline.R`'s header and closing message already
  describe `--only`; nothing stale.

## Considered and not flagged

1. **Step 5 under `--only` does not prove the pgstac row changed.** Its assertions are: item endpoint
   200 (true before the release too — the same "meaningless 200" the asset-probe comment warns about),
   membership unchanged, and S3 bytes match the local build. Nothing reads the live item back. This is
   the same shape as the full path (`missing`/`extra` compare ids only) and the register's own exit
   status is robust (`set -eu` remotely, line-count guard, pypgstac status through ssh), so it is not
   introduced here and not a false-pass route on its own. Worth knowing when reading a green pilot:
   "the row was upserted" rests on `item_register.sh` exiting 0, not on step 5.
2. **`--only` bypasses PARTIAL_STAGE for the silently-skipped-target case too.** Harmless: the operator
   names the item, and a skipped target has no `<id>.json` (tree wiped per stage), so it is refused at
   preflight. A group's *other* target being skipped does not make the named one incomplete.
3. **`--only collection`** is the one id for which `$STAC_DIR/$ONLY.json` *is* the protected document.
   It is refused twice — no `data/stac/collection/` directory ever exists (05 keys asset dirs by
   item id) and `collection` is never in the live item ids — but both are incidental facts rather than
   an explicit rule, and the check script does not exercise it. Two independent structural guards is
   enough; noting it only so the next person does not weaken both at once.
4. **`aws s3 sync` under `--only` has no `--delete`**, so a renamed asset leaves its old object under
   `s3://bucket/<id>/`. Identical to the full path and deliberate there (versioning Suspended).

