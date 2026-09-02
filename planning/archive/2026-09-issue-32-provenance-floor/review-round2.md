# Review round 2 — #32 provenance floor (exact floor + `--only` preflight)

Diff: `main..HEAD` plus the uncommitted working-tree hunks over `scripts/`, `CLAUDE.md`,
`NEWS.md`. Probes ran against scratch copies of `scripts/` under the session scratchpad; nothing
in the working tree or `data/` was touched. Both hermetic checks run clean from the repo root:
`catalogue_release-check.sh` ALL PASS, `fp_provenance-check.R` 49/0/0.

## Findings

- **[fragile]** `scripts/catalogue_release.sh:191-206` — the `--only` preflight's predicate is
  `live > 0 && built == 0`, so it refuses only a **total** loss. A per-section loss — the exact
  "network found, landcover lost" case the new `PROV_SECTIONS` comment in `item_validate.py`
  names — passes it: live item carries 12 values, the build's copy carries 4 (network) and 8
  nulls, `n_built = 4`, no refusal. Step 5 then compares build-null against served-absent as
  "the same document" (by design, #36), so the release completes with every guard green having
  replaced eight live provenance values with nulls, on a bucket with no rollback. The harness
  cannot see this: the fixture has one `nge:` key (`nge:probe`), so partial loss is not
  representable, and case 15 proves only the all-or-nothing arm. The fix costs nothing and is
  strictly stronger with the same inputs already in hand — count keys that are present (hence
  non-null) on the live item and null on the build, and refuse if any:
  ```python
  lost = sorted(k for k, v in live.get('properties', {}).items()
                if k.startswith('nge:') and v is not None and built['properties'].get(k) is None)
  ```
  and print the list, so the refusal names the section that went missing. Same class as
  *"a guard that encodes the cause you measured is a proxy for the property you want"*: the
  property is "no live value becomes a null", the encoded cause is "the reader found nothing at
  all". (The full-release exact floor has the same item-level blindness, but the diff states
  that deliberately and mitigates it with the per-section print; under `--only` there is no
  floor at all, so the preflight is the only opinion.)

## Probed and clean

- **Restore-the-bug, harness** (scratch copies, four mutations, each fired on exactly the
  assertion written for it): preflight refusal disabled (`-eq 0` → `-eq 99`) → case 15 fails
  twice, and confirms the context's claim — with the guard off the release syncs (`aws calls=2`)
  and only step 5 catches it. `PROVENANCE_FLOOR="${PROVENANCE_FLOOR:-0}"` → case 2's sed premise
  fails. Flag dropped from the full-release `uv` line → `n_floor_flag` 0 and `floor_passed` empty
  fail. `--expect-provenance ""` leaked into the `--only` branch → case 1's "flag absent, not
  merely empty" fails (`n_floor_flag` 1) — round 1's fragility is closed, not just noted.
- **Exact floor** (`check_provenance` imported from the script, 3-item scratch fixture with 2
  traced): `None` → no problem; 0 and 1 → "reader found nothing" arm; 2 → clean; 3 → "floor is
  behind the build" arm. `PROV_SECTIONS` partitions `REQUIRED_NGE_PROPERTIES` exactly: 4 + 1 + 7
  = 12, union equal, disjoint. `run_pipeline.sh` passes no flag → `None` → no check, as stated.
- **`--only` preflight shell shapes.** `curl -sf` failing (a 404 or a timeout) under
  `pipefail` inside `$( )` makes the substitution non-zero whether or not python also dies on
  the empty body → the `||` refusal fires (measured). The 404 is in practice unreachable: the
  "is not live" refusal precedes it, and `fetch_live_ids` searches with `limit: 1000` (20 live
  items), so a live id is in the list. The python is exposed to exactly two `$`-expansions,
  `$STAC_DIR` and `$ONLY`; `$ONLY` is anchored to `[A-Za-z0-9_-]` at line 94-95, so the
  single-quoted path cannot break. No backticks or backslashes in the body. `read -r` from the
  unquoted heredoc parses "N M" cleanly. Python either prints two ints or exits non-zero, so the
  one-value shape — which would make `[ "" -eq 0 ]` error to false inside the `if` and fall
  through — is unreachable from this code. `n_floor_flag`'s `END { print n+0 }` prints 0 when no
  `uv` line exists (measured through mutation A3).
- **`test_pipeline.R` per-target compare.** The three paths match `FP_PROV_MAP` byte for byte
  (`inputs$link$version`, `inputs$flooded$version`, `run$datetime_utc`), and the network
  selector is the same `Filter(identical(as.character(inputs$species), species))` the reader uses
  at `fp_provenance.R:224`. `fp_prov_leaf` returns `cur[[1]]` verbatim, `write_json(auto_unbox,
  na="null", null="null")` and `read_json(simplifyVector=FALSE)` round-trip a string, an integer
  and a JSON null to `identical()` TRUE (measured). The one type that does not round-trip is a
  JSON `1.0` (numeric → written `1` → read integer), which none of the three fields can be —
  versions and datetimes are strings. `NULL[[...]][[...]]` chains and `list()[["x"]]` both give
  NULL; `Filter` over a `[]` network gives `list()`; `list(a = if (FALSE) 1)` keeps the NULL
  member, so `want` always has three names. `%||%` is defined locally (and in base R 4.5).
- **`fp_provenance-check.R` bulk case.** `%||%` comes from the `source()`d `fp_provenance.R`
  (and base R ≥ 4.4). `(raw[["landcover"]] %||% list())[["co_ff04"]]` is NULL for a missing
  section or an empty array. The expectation is now derived from the producer's raw bytes rather
  than asserted, in whichever state the file is — the reader agrees today (49/0).
- **Docs.** `CLAUDE.md`, `NEWS.md`, `scripts/README.md` describe the exact semantics and the
  `--only` stand-in as implemented; the `PROVENANCE_FLOOR` comment's "next full release sets 1"
  matches the memory note that BULK now carries values.
