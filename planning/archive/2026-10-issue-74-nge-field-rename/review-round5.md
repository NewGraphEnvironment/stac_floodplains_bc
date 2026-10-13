# Review round 5 (#74) — `scripts/only_preflight.py`, its call site, the join, the branch

Base `844ba81`, HEAD `08d2a82`. Both safe suites re-run on this tree, under `/bin/bash`
3.2.57 (the only `bash` on PATH here):

- `bash scripts/catalogue_release-check.sh` → **ALL PASS** (includes cases 15/16/17 and
  case 1's `--only` controls)
- `uv run python scripts/prov_fields-check.py` → **44 assertions, 0 failed**

## Findings

- **[fragile]** `scripts/only_preflight.py:117` (`live = json.load(sys.stdin)` →
  `canon(live.get("properties", {}))`) — the live side of the VALUES arm fails toward
  pass, while the built side fails loudly. `built["properties"]` raises `KeyError`
  (measured: rc 1, so the shell refuses); `live.get("properties", {})` returns `{}` for a
  readable JSON document that is not an item, so `live_values` is empty, `lost` is empty,
  and the preflight prints a clean line. Measured:

  ```
  echo '{}' | python3 scripts/only_preflight.py built.json bucket.json
  0|2|||          rc=0        -> no refusal, release proceeds
  ```

  The second arm of the same shape: `canon()` skips `processing:software` entirely unless
  `isinstance(value, dict)`, so a live item serving that property as a string or a list
  silently drops up to four fields from `live_values` (measured: `2|2|||` where the
  software fields were present on the live side and absent from the comparison).

  Reachability is narrow — `curl -sf` refuses ≥400, and a truncated body exits 18, both of
  which the `||` branch catches (verified: python non-zero, curl non-zero, missing argv,
  missing path, empty stdin, `"properties": null`, a top-level list and a bare string all
  exit non-zero and refuse). But the direction matters more than the odds here: this guard
  exists to refuse *before* the sync and the upsert, its message says so ("Refusing before
  anything is written"), and the only backstop for a lost provenance value is step 5's
  read-back, which runs **after** both irreversible writes on a bucket with versioning
  Suspended. The repo already treats the equivalent premise as load-bearing elsewhere —
  `check_provenance` and `check_cog_tags` both append a problem when they compared nothing.

  One line closes it, and it is strictly stronger (a STAC Feature always carries
  `properties`, and the harness's own read-back asserts "3 properties"):

  ```python
  live = json.load(sys.stdin)
  if live.get("type") != "Feature" or not isinstance(live.get("properties"), dict):
      print(f"{argv[0]}: stdin is not a STAC Feature with properties", file=sys.stderr)
      return 2
  ```

  Same reasoning argues for making a non-dict `processing:software` a refusal rather than a
  skip on both sides, or at minimum reporting it in `lost`.

- **[fragile]** Four pointers say the comparison lives in `catalogue_release.sh`; round 4
  moved it to `scripts/only_preflight.py`, and one of them claims a guard that no longer
  exists.

  - `scripts/README.md:249` — "It also parses `item_create.py`, `02_raster_tag.py` and **the
    inline program inside `catalogue_release.sh`'s `--only` preflight**" — `prov_fields-check.py`
    imports the module (line 184) and parses only the two Python files; nothing slices the
    shell script.
  - `scripts/README.md:252` — "**The same slice enumerates every character bash expands
    inside that preflight's double-quoted argument, because a comment there is program
    input.**" — that enumeration was deleted with the construct. `grep -n
    'slice\|hazard\|expand\|backtick\|release_preflight' scripts/prov_fields-check.py`
    returns only prose. A reader is told a guard is in place that is not, three paragraphs
    below the correct description of the file in the same README section.
  - `scripts/prov_fields-check.py:239-242` — a duplicated, superseded comment paragraph
    ("The fifth copy: catalogue_release.sh's --only preflight, which canonicalises…") sits
    directly above its replacement at 243-247. Delete 239-242.
  - `scripts/item_create.py:176` and `CLAUDE.md:121` — "`canon()` in `catalogue_release.sh`
    is the one other reader that still knows the retired prefix". `CLAUDE.md:29` names
    `scripts/only_preflight.py` correctly, so `CLAUDE.md` contradicts itself.

  No runtime consequence; it is the "one fact stated in N places, one copy updated" shape,
  and `CLAUDE.md` is instructions a future session acts on.

## Verified, no finding

**1. `only_preflight.py` as a program.** Every failure mode drives the refusal path or is
benign, measured rather than read:

| input | result |
|---|---|
| no argv / one argv | usage on stderr, rc 2 → refusal |
| nonexistent path (either arg) | `FileNotFoundError`, rc 1 → refusal |
| empty stdin | `JSONDecodeError`, rc 1 → refusal |
| `{"properties": null}` | `AttributeError`, rc 1 → refusal |
| stdin a list / a bare string | `AttributeError`, rc 1 → refusal |
| built JSON with no `properties` | `KeyError`, rc 1 → refusal |
| bucket JSON with no `properties` | every built key reads as *gained* → reported, not refused (correct: `keys()` of `{}` is empty) |
| valid JSON, not an item | **see finding 1** |

`|` or a newline inside a key name cannot flip a refusal into a pass: I drove the real
`IFS='|' read` + heredoc construct with each shape. A `|` in a *dropped* key splits the
field but leaves `only_dropped_prov` non-empty (`REFUSE dropped` still fires); a newline
truncates at the heredoc's first line but the surviving prefix is still non-empty; a
newline in `gained` only shortens an informational echo. Large items are irrelevant —
command substitution, not a fixed buffer.

**2. The call site.** Correct in every mode I could drive. `set -euo pipefail` + `pipefail`
inside `$( )` makes a failing `curl` or a failing/absent `python3` a non-zero substitution,
so the `||` refusal fires; the one shape that would pass silently (exit 0 with no output)
is unreachable, because `main()` returns 0 only after `print`. The heredoc body is at
column 0 with `EOF` at column 0 (`cat -A`-checked), unquoted so `$only_prov` interpolates —
and a value's own `$(…)`/backticks are **not** re-scanned, so the construct carries none of
the hazard the inline program did. `IFS='|' read` keeps the trailing empty field in
position (drove all five shapes). `python3` rather than `uv run` is right and matches the
pre-existing `python3 scripts/collection_version.py` call; the relative `scripts/…` path
matches the script's existing cwd assumption (`STAC_DIR=data/stac`). `mktemp -t
only_bucket.XXXXXX` has its six X's and is guarded; there is exactly **one** `trap … EXIT`
in the file (`grep -c 'trap '` = 1), armed on the statement after the `mktemp`, and the temp
file is now read as `argv[2]` rather than through the pipe, which is what the extraction
needed. bash 3.2's "armed EXIT trap turns an expansion error into exit 0" does not reach
this path — no `${VAR:?}` anywhere in the script, and cases 15/16 assert `rc != 0` *after*
the trap is armed and pass under 3.2.57.

**3. The join in `prov_fields-check.py`.**

*Can the "the release path runs it" assertion be satisfied by a release that does not run
it?* I could not make it pass. Mutating a copy of the script three ways — revert to an
inline `python3 -c '…'` (single-quoted, which the `'python3 -c "'` substring misses),
revert to `python3 /dev/stdin`, and delete the call while keeping the comment — all three
are **caught**, because `"python3 scripts/only_preflight.py"` occurs exactly once in
`catalogue_release.sh` and it is the call itself (the comment block says "an inline `python3
-c`", not the path). The residual weakness is that the three conditions are not anchored to
each other, so the day someone writes the path into a comment in that file the first
condition stops discriminating. One cheap tightening, if round 5's fixes touch this anyway:
require the call in the segment the second condition already locates —
`"| python3 scripts/only_preflight.py" in _release.split("only_prov=$(curl", 1)[1][:400]`.
Not reported as a finding: it does not pass today against any revert I could build.

*Does importing the module reintroduce x == x?* No, and the comment's argument holds.
`only_preflight.NEW/SOFTWARE/PREFIXES` are module-level literals **independently declared**
in that file; `only_preflight` imports nothing from `item_validate` or `item_create` (only
`json` and `sys`), so `op.NEW == {v: k for k, v in PROV_PROPERTIES.items()}` compares two
copies of one fact and is a join in exactly the sense `literal()`'s static parse is. The
x == x hazard would need the preflight to import the map it is checked against. Import vs.
parse costs only the module's side effects at import time, and there are none (argv handling
is behind `__main__`); `sys.path.insert` of `scripts/` collides with no stdlib name. An
inverted-dict collapse would be caught rather than hidden (unequal lengths fail the compare).

**4. Cases 15/16/17 and `test_pipeline.R`.** No findings.

- The shims reach the right arms: case 15 drives the VALUES arm through the API read
  (`provenance` stale mode) at counts 2 vs 1, which a total-loss check would pass; case 16
  drives the SHAPE arm through the bucket read only, which is the one the API cannot answer;
  case 17 pins the asymmetry, and asserts the absence of the refusal message rather than just
  exit 0. Case 1's `n_floor_flag`/`n_partial_flag`/`n_uv` premises are read from the argv log,
  not from the script text.
- Worth stating out loud rather than fixing: because every live item's **bucket** copy is
  pre-#74, the SHAPE arm will refuse `--only` for *every* item until the first full release
  after this branch. That is the designed behaviour and the message says so ("a FULL-release
  change"), but NEWS.md's #74 entry does not mention it, and `--only` is the path an operator
  reaches for by default.
- `test_pipeline.R`: the two-sided staged↔published join is sound. I verified the premise it
  rests on — `jsonlite::read_json()` keeps a JSON null as a NULL element whose **name**
  survives, so `setdiff(names(meta), meta_core)` still sees all twelve fields when values are
  absent, and `staged_present` filters on `!is.null`. The degenerate shapes behave:
  `prov_map[character(0)]` → `character(0)`, `c(character(0), NULL)` → `character(0)`, and
  `setequal(character(0), NULL)` → TRUE, so an all-absent item compares empty-to-empty on
  both the key and the entry arms rather than erroring. `want$link` is reassembled from the
  producer's two leaves (`inputs$link$version`, `link_log$link_sha` — the same leaves
  `fp_provenance.R` maps, confirmed) rather than split out of the published string, and a
  half-present pair fails here as well as in `item_create.py`. `ls` as a local name shadows
  `base::ls` but is only ever read as a value.
