# Review round 2 — #61, the validator side

Scope as assigned: `scripts/item_validate.py`, `scripts/year_sets-check.py`,
`scripts/test_pipeline.R`, `scripts/item_create.py`, `scripts/run_pipeline.sh`, `NEWS.md`,
`README.Rmd`.

**The tree moved under this review, again.** At my first `git status` the assigned files were
staged; by the time I finished they were committed (`9901cc2`, `b9f6830`) and the index held a
different set (`CLAUDE.md`, `NEWS.md`, `scripts/README.md`, `scripts/fp_provenance-check.R`,
`scripts/stage_years-check.R`, `planning/active/review-round1.md`). Everything below was read
from the **working tree**, which is HEAD for the code files, and re-confirmed against the
current `NEWS.md` — so the three NEWS findings are against the text that stands right now, not
against the version I was handed.

## What I verified by running, not by reading

- `uv run python scripts/year_sets-check.py` → **10 assertions, 0 failed**.
- **Mutation-tested the proof suite** against a copy of `item_validate.py` in a scratch dir.
  Neutering arm (d) (`if on_disk != keys:` → `if False:`) turns exactly one assertion red
  (`a COG on disk that no asset describes is refused`). Neutering arm (b)
  (`if not partial:` → `if False:`) turns exactly one red. Neutering arm (a)
  (`if match is None:` → `if False:`) crashes on `used[None]`, which is a mutation artefact,
  not a defect. **Every case reaches the arm it names**, and the `expect_problem` needle
  discipline is doing real work — no case passes by firing a neighbour.
- The two regexes in the file are **correct** — `r"^classified_(\d{4})$"` and
  `r"^classified_(\d{4})\.tif$"`, single backslash, confirmed with `cat -A`. Not the doubled
  form that would have matched nothing and failed toward pass.
- `used` and `allowed` are both keyed `tuple(sorted(y))` from the same literal, so
  `used[match]` cannot `KeyError` even if someone writes an unsorted tuple into
  `ALLOWED_YEAR_SETS`.
- `max(fixed_keys.values(), key=len)` cannot see an empty sequence: it sits inside
  `if asset_keys:`, and the all-empty case is caught by `if not expected_fixed`. An item with
  **zero** classified assets is not silently exempt either — `year_keys[i]` is the empty set,
  matches no sanctioned set, and arm (a) fires with `classified asset keys none`.
- An empty tree cannot reach `check_checksums` at all: `main()` refuses at
  `expected < 1` (`item_validate.py:1548`).
- The set comprehension `{m.group(0)[: -len(".tif")] …}` yields `classified_2017`-shaped
  **keys**, directly comparable to published asset keys — proved by the arm-(d) case, whose
  needle is the literal `present-but-unpublished ['classified_2019']`.
- `03_cog.py` writes to `STAC_DIR / src.relative_to(RAW_DIR)`, i.e. `data/stac/<item_id>/`, so
  arm (d)'s `base / item_id` is the right directory.
- The year-set `print()` runs **after** the `if bad: return 1`, so it can never print a count
  over a tree that failed arm (a) — the misleading line is unreachable.
- `--partial` partition audited arm by arm. Fixed-key cross-item compare: names keys the
  subset *contains* → stays on (and is a self-comparison on a one-item tree, as it was before
  #61). Arm (a): per item → stays on. Arm (d): per item, per directory → stays on. Arm (b):
  asks about sets the subset may legitimately not hold → dropped. **The partition is right.**
- `jsonlite::read_json` parses whole JSON numbers as **integer**, so `test_pipeline.R`'s
  `sprintf("classified_%d.tif", unlist(meta$years))` and the `transition_%d_%d` form do not
  hit `sprintf`'s "invalid format '%d'" on doubles. Measured.
- `n_expected` is reassigned at `test_pipeline.R:239` inside the per-item loop, but the
  pre-loop value is consumed at line 95, before the loop. No live bug.
- `check_checksums` has no callers outside `item_validate.py` and `year_sets-check.py`, so the
  signature change to a 2-tuple breaks nothing.
- `04_gpkg_style.py` really does map by prefix (`layer.startswith("classified")`,
  `04_gpkg_style.py:60`), so the NEWS claim that it needed no change is **correct**.
- `LNTH` is in `fraser.yml`'s `watershed_groups` and its upstream rasters are
  `classified_2017 … classified_2023` — genuinely annual. So a full build today does use both
  sanctioned sets and arm (b) will not spuriously refuse the next full release.

## Findings

- **[bug] `NEWS.md:59-62` and `scripts/test_pipeline.R:73-77` — the claim about which groups
  the smoke test could validate on `main` is false, and it understates the breakage.**
  Both say the smoke test "has been unable to validate **any** watershed group except the two
  named in `EXPECTED_DEPRECATED`" / "could only ever run for those two groups". It could run
  for **none of them**. `check_deprecated`'s whole-catalogue arm is
  `for i in sorted(EXPECTED_DEPRECATED - seen)`, and a one-group tree is missing *the other*
  member of the pair whichever of the two you pick. Measured, driving the current
  `check_deprecated` over synthetic one-item trees:

  | tree | `partial=False` | `partial=True` |
  |---|---|---|
  | `mcgr_ch_ff04` | `pine_bt_ff04: named in EXPECTED_DEPRECATED but absent from the build` | CLEAN |
  | `pine_bt_ff04` | `mcgr_ch_ff04: named in EXPECTED_DEPRECATED but absent from the build` | CLEAN |
  | `ufra_ch_ff04` | both of the above | CLEAN |

  Why it matters: this is a release note stating the blast radius of a regression #26
  introduced, and a reader deciding whether to backport or how far the damage ran will take
  the carve-out at face value. The accurate sentence is "since #26 landed, `test_pipeline.R`
  has been unable to validate **any** watershed group at all — the last arm asks about ids
  absent from a one-group tree, and a one-group tree is always missing at least one of the
  two." This is the `code-check.md` "Documents that share an ancestor corroborate nothing"
  case in its release-note form: derive the claim from the artifact, not from the shape of the
  literal. Round 1 did not cover this one.

- **[fragile] `NEWS.md:50-52` and `scripts/item_validate.py:1491-1495` — arm (d)'s scope is
  claimed as "a stray COG", and it only covers `classified_<yyyy>.tif`.**
  Both say a stray COG reaching the public bucket "was caught by no guard in this repo" /
  "is caught by nothing else", with no qualifier. The arm's `on_disk` set is filtered through
  `CLASSIFIED_FILE_RE`, so a stray `transition_2017_2025.tif`, any other-named `.tif`, and any
  stray `.gpkg` or `.qml` in `data/stac/<item_id>/` still sync to the public bucket described
  by nothing. I grepped for any other guard that enumerates the item directory
  (`iterdir`, `glob("*")`) — there is none, so nothing else closes the remainder either.
  This is "A guard's scope is usually a coincidence, and it will not announce itself": the
  next person reads this comment as *the directory is now guarded* and stops looking. Name the
  boundary — "a stray **classified** COG" — or widen the arm to compare the whole directory
  against the whole published asset set, which is the check the comment's own reasoning
  (`aws s3 sync` uploads the directory) actually argues for.

- **[fragile] `scripts/item_validate.py:1509-1516` — arm (b)'s remedy is written for only one
  of the two directions the arm fires in.**
  The message ends "Delete it once the rollout that made it obsolete is finished". That is the
  right instruction for a set that has *become* unused. It is the wrong instruction for a set
  added *ahead of* its data, which is the live state of this rollout: `ALLOWED_YEAR_SETS`
  gained the annual tuple in this change, and `floodplains#79` is still converting. Today the
  arm is satisfied (LNTH stages annual, measured above), but any full build where LNTH is
  SKIPPED — no rasters for its scenario, the ordinary partial-stage state this repo already
  guards with `PARTIAL_STAGE` — refuses the release with a message telling the operator to
  delete the annual tuple. Doing that then makes arm (a) refuse the first annual item, i.e.
  the remedy walks the operator back through the guard. `code-check.md`, "A guard that fires
  correctly and then points at the wrong fix" — ask what someone would *do* on reading it.
  One clause fixes it: "…or, if the rollout that will use it has not reached this build yet,
  check the groups you expected to supply it actually staged."

- **[fragile] `scripts/item_create.py:8` — the module docstring still declares the removed
  constant.** `- assets = classified_2017/2020/2023 + transition_2017_2023 COGs`. This is the
  exact three-year constant #61 removed, sitting at the top of the script that *builds* the
  assets; the same commit corrected the collection `description` 559 lines below it
  (`item_create.py:568`) and every other public surface (`README.Rmd`, `README.md`,
  `index.html`). Should read `classified_<yyyy>` per the item's own year set. Same class as
  round 1's `CLAUDE.md:83` finding, in a file round 1 did not list.

## Not findings, recorded so a round 3 does not re-derive them

- The `continue` after arm (a) does suppress arm (d) for that item. That is safe: both arms
  are refusals, `bad` is non-empty either way, and once the span is sanctioned arm (d) runs on
  the next pass. Nothing is permanently hidden.
- Arm (d)'s `published-but-absent` half is effectively unreachable — an asset key whose file is
  missing is already caught by the per-asset loop's `asset not on disk at …`. Dead but
  harmless.
- Arm (d) compares *stems on disk* to *published keys*, not the key→file mapping, so an asset
  keyed `classified_2017` whose href pointed at `classified_2020.tif` would pass. `item_create.py`
  derives the key from the stem, so the state is not constructible today.
- The fixed-key cross-item compare degenerates to a self-comparison on a one-item tree, so
  under `--only` nothing absolute covers the four fixed *data* assets (transition + three
  GeoPackages); `EXPECTED_STYLE_ASSETS` is absolute only for the three styles. The comment at
  `item_validate.py:1462-1464` slightly over-claims by pairing them. Pre-existing behaviour,
  unchanged by #61, and `test_pipeline.R`'s per-item count covers it in the smoke test.
- `README.Rmd`'s "Seven assets each, plus one per classified year" reconciles: 1 transition +
  3 GeoPackages + 3 styles = 7. `lnth_ch_ff04`'s "14 assets" in NEWS = 7 + 7. Both correct.
- Round 1's finding that neither new check script is reachable has been addressed —
  `scripts/README.md:209-223` now documents both. (Note for whoever greps to confirm: plain
  BSD `grep 'a\|b'` treats `\|` literally and reports a false absence, per
  `code-check-shell.md`. Use `grep -E`.)
