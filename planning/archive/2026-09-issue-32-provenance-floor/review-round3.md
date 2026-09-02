# Review round 3 — #32 provenance floor (per-key `--only` preflight)

Diff: `main..HEAD` over `scripts/`, `CLAUDE.md`, `NEWS.md`, all committed. Probes ran against a
scratch copy of `scripts/` under the session scratchpad; the working tree and `data/` were not
touched. Both hermetic checks run clean from the repo root: `catalogue_release-check.sh` ALL PASS,
`fp_provenance-check.R` 49/0/0.

## Findings

- **[fragile]** `CLAUDE.md:66-67`, `scripts/README.md:139` — both describe the `--only` preflight
  as refusing "if the live item carries `nge:` values and the build's copy carries **none**". That
  is round 2's total-loss predicate, which this round replaced: `catalogue_release.sh:200` refuses
  per key (any live value that the build publishes as null), and harness case 15 pins the partial
  shape. The docs now state a weaker guard than the one shipped, so a reader of the repo section —
  which is the spec the next person works from — would believe a network-kept/landcover-lost item
  goes through under `--only`. `NEWS.md` ("refuses to replace a live item's provenance with nulls")
  and the in-script comment are correct. One clause in each file.

- **[fragile]** `scripts/catalogue_release.sh:200` — `bp.get(k) is None` is true for a key that is
  **absent** from the build as well as for a null, so a contract rename (the thing #40 just did)
  makes the next `--only` refuse with a diagnosis of "a reader that found nothing, or only some
  sections" — the wrong cause. Measured with the script's own predicate: live `{a:x, old:y}` vs
  build `{a:x, new:z}` prints `2 2 nge:old`, so the counts line says "carries 2 … carries 2" and
  the next line says a value would be published as null. The refusal itself is the right
  direction — pgstac's upsert replaces the whole document, so republishing one item under a renamed
  key would leave the other 19 live items on the old key, and a contract change is a full-release
  event — only the message misattributes it. Low weight; `k not in bp` is separable from
  `bp[k] is None` in the same comprehension if the message is worth fixing.

## Mechanism, and whether the change has converged

The defect class across the three rounds is one thing: **a guard written at a coarser granularity
than the property it stands for.** The property is per key — "no live `nge:` value becomes a null" —
and each draft encoded an aggregate of it that happened to agree on the fixture in hand:

| round | granularity of the guard | what it could not see |
|---|---|---|
| 1 | file: `provenance.json` exists ⇒ some value non-null | the reader's contract is per section; a MORR file with only the coho sections is a legitimate all-null `ch_ff06` — a false refusal |
| 2 | item: `n_built == 0` | a partial loss (network kept, landcover lost) — a false pass, on a bucket with no rollback |
| 3 | key: `{k : live[k] non-null ∧ build[k] null}` | — |

This terminates by enumeration rather than by another round: the property is a set difference over
keys, and the current predicate computes that set exactly. There is no level below key. The
harness now reaches the distinction (the fixture gained `nge:kept`, so a partial loss is
representable), and restoring round 2's predicate in the scratch copy turns case 15 red on both
assertions with `aws calls=2` — the guard off, the release syncs before step 5 catches it, which is
what the preflight exists to prevent. **On the `--only` path the change has converged.**

**Residual, stated by the diff and worth naming precisely.** The full-release floor is item-level
by construction (`traced` counts items with *any* non-null field, the same predicate as `has_prov`
and `_no_prov`), with per-section counts printed but not gated. So round 2's shape exists on the
other path: a reader that keeps the network section and loses landcover on every item passes
`--expect-provenance 1` today, and nothing in the full-release path compares against live per key —
the step-5 read-back runs under `--only` only, and `run_pipeline.sh` does not run
`test_pipeline.R`, so the new per-target compare guards a manual smoke, not a release. This is
definitional (a floor is a count of items) and the docstring accepts it deliberately, so it is not
instance four; it is the residual. If it is ever to be closed, the full-path equivalent is the same
per-key compare over every id in `live_ids`, which preflight already holds.

## Probed and clean

- **Restore-the-bug** (scratch harness, mutation = round 2's `n_live > 0 and n_built == 0`):
  case 15 fails "refused before any write" (`rc=1, aws calls=2`) and "names the lost key"; every
  other case passes, so the two new assertions are the ones that discriminate.
- **Preflight predicate shapes** (script's own three lines): null-on-build `(2, 1, 'nge:b')` →
  refused; build-has-more `(1, 2, '')` and value-changed `(1, 1, '')` → pass, correctly — a
  re-model that changes or adds a value is not a loss. `read -r a b c` on `"1 1 "`, `"2 1 nge:probe"`
  and `"2 0 nge:a,nge:b"` parses to the three fields with `c=''` for the empty case; key names carry
  no whitespace, and the unquoted heredoc expands `$only_prov` once without re-parsing, so the
  live document's key names cannot reach the shell.
- **`$API`** is defined at line 39 before the preflight uses it (line 193); the fetch shape matches
  step 5's, and `curl -sf` failure under `pipefail` inside `$( )` still reaches the
  `|| { … refusing to publish blind }` arm (round 2 measured).
- **Floor value 0.** `--expect-provenance 0` is `not None`, so it is a real check (a `truthy` test
  would have silently disabled the floor at exactly the value it ships with); the print says
  `floor 0`, not `none`. Case 2's sed premise still reads the literal.
- **Harness fixture carries values with floor 0** (`nge:kept` on both items, `PROVENANCE_FLOOR=0`)
  — inert today because `uv` is shimmed, as the header states; it would surface only if the
  validator were ever run for real inside the harness, and would surface loud.
- **The operator's two "number to set" strings** exist as documented: `01_stage.R:416`
  `"N of M staged item(s) carry run provenance"` and `item_create.py:409`
  `"provenance block: N/M"`, on the same any-non-null predicate as `traced`.
- **`fp_provenance-check.R`**: `lc` is defined at line 115 before the bulk block; `%||%` comes
  from the `source()`d `fp_provenance.R:32`; the expectation is derived from the producer's bytes
  in whichever state the file is, and the reader agrees (49/0).
- **`test_pipeline.R`**: the three paths match `FP_PROV_MAP` and the network selector matches the
  reader's (round 2); `[[` throughout; `want` keeps its three names when a value is NULL.
