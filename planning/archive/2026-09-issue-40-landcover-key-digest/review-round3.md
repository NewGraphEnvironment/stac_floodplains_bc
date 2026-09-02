# Review round 3 — #40 (branch 40-nge-landcover-key-publishes-item-hash-th)

Scope: committed diff `main..HEAD` over `scripts/`, `CLAUDE.md`, `NEWS.md`, `README.md` (617
lines), every changed file read in full. Probes ran in a scratch copy of `scripts/` under the
scratchpad (`r3/probe_mtime.R`); the working tree was not touched, no stage or
`test_pipeline.R` run, `data/` untouched, producer files read read-only. Brief: mechanism over
instances, and a convergence verdict.

## Findings

- **[bug]** `scripts/fp_provenance.R:333-335` (`fp_prov_rasters_current`, called from
  `scripts/01_stage.R:217`) — the guard's reference is `file.mtime(provenance.json)`, and that
  file is **rewritten wholesale by all three upstream steps** (`floodplains/scripts/floodplain_lcc/fp_provenance.R`:
  `fp_prov_read` → modify one section → `fp_prov_write` renames a fresh file over the target).
  So the file's mtime is the time of the *last writer*, not of the landcover section that
  describes the rasters. The state the guard is documented to catch — step 3 wrote rasters
  and crashed before recording — is masked the moment step 1 or 2 re-runs for that area, which
  `run_area.R <area> 1|2` makes routine. Probed in the scratch copy against both controls:

  | state | rasters | file mtime | landcover `run.datetime_utc` | guard |
  |---|---|---|---|---|
  | consistent (control) | T0−15 s | T0 | T0 | pass |
  | step 3 crashed after writing rasters, nothing rewrote the file (control) | T0+10 min | T0 | T0 | STOP |
  | same crash, then step 1/2 re-ran and rewrote the file | T0+10 min | **T0+20 min** | T0 | **pass** |

  In the third row the item publishes `nge:landcover_key` as a fingerprint of bytes it does
  not ship, and is counted as traced — the exact outcome the guard exists to refuse, in the
  silent direction. Reachability is narrow (crash, then a *different* step re-run before step 3
  is retried) but the cost is a confidently wrong published value.

  The discriminating reference is already in hand: the section's own `run$datetime_utc` is
  stamped at record time (`03_lulc_classify.R:410-443` calls `fp_prov_run()` → `fp_provenance.R:714`
  `format(Sys.time(), ..., tz = "UTC")`, after the raster writes at :123/:138), it survives
  rewrites by other steps, and it is what this repo already publishes as `produced_datetime`.
  On the real neexdzii file it equals the file mtime to the second (12:48:49 -0700 both;
  rasters 12:48:34–38). Compare raster mtimes to
  `as.POSIXct(sec$landcover$run$datetime_utc, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")` instead of
  the file. Two details for that fix: the stamp is floored to the second while `file.mtime`
  carries fractions, so floor the raster side too (or test `mtime >= stamp + 1`) or a raster
  written in the record's own second false-fires; and the check script's mtime fixture
  (`fp_provenance-check.R:157-167`) sets raster times relative to the *file's* mtime, so it
  would need to set them relative to the synthetic document's `datetime_utc`
  (`2026-09-02T19:48:49Z`) — as written it could not reach this row.

  This is the mechanism behind round 2's finding as well (a copied tree resets mtimes): both
  are the guard reading a property of the *file object* — its copy, its last writer — where the
  invariant is a property of the *record's content*. The S4 follow-up (recompute the digest on
  the staged copies) retires the whole class; until it lands, the section stamp is the correct
  reference for the cheap half.

## Verified clean (mechanism-level, this round)

- **Fold reproducibility is not circular.** Round 1's "stated rule, recomputed here" assertion
  uses the same `digest::digest` as the fold, which proves the join rule but not the hash. Recomputed
  the neexdzii pin from the producer's file with Python `hashlib.sha256` over
  `"\n".join(f"{y}={m[y]}")`, years sorted: `sha256:27a0c5b6…fb89b04`, identical to the pinned
  value. So "a consumer holding the producer's file can recompute the published value" holds
  with a standard tool, and `serialize = FALSE` hashes the bare bytes with no trailing newline.
- **Fold input shapes.** `{}` and `[]` both read back as an unnamed `list()` → refused by the
  names guard; duplicate year keys survive `read_json` as duplicate names → `sort(names(x))`
  ≠ `years` → refused; `x[[y]]` is exact-match. No route publishes a single year's digest.
- **`fp_prov_item(…, years)` callers:** exactly two (`01_stage.R:357`, check script :87), both
  pass the span; no other script sources `fp_provenance.R`.
- **`digest` is a new R dependency on this branch** (absent from `main`'s `scripts/`). The repo
  declares no R packages anywhere (no DESCRIPTION/renv; README lists none), so it is no less
  declared than `sf`/`yaml`/`drift`. It fails loud, and only once a landcover section is reached
  (the fold is the sole caller), so a machine without it stops mid-stage rather than publishing
  a wrong value. Installed here. Not a finding.
- `run_pipeline.sh` is `set -euo pipefail` and runs `Rscript scripts/01_stage.R` bare, so the
  new stop route aborts the chain like every existing one; no partial `data/raw` reaches 02/03.
- The four Python/R field-list copies and the two-sided `test_pipeline.R` check were re-read;
  round 1's analysis stands, nothing moved.

## Convergence

**The reader and the fold have converged.** Three rounds, every guard restored-and-fired in
round 1, the hash reproduced independently this round, and no finding in any round has touched
`fp_fold_year_digests`, `fp_prov_leaf`, `fp_prov_sections`, `fp_prov_read` or the field-list
plumbing. I would not expect a fourth round to find anything there.

**`fp_prov_rasters_current` has not.** Round 2 and round 3 each found one defect in it, and
they share a mechanism — mtime is a fact about the file object, the invariant is a fact about
the record — which is the signal that the guard's *reference* is wrong rather than that two
instances need patching. Switching to the section stamp closes the reachable failure I can
name; S4 closes the class. Ship with the one-line reference change, or ship as-is with the
guard's comment narrowed to what it actually detects ("rasters newer than the *last write* to
provenance.json") so the next reader does not credit it with the crash case.
