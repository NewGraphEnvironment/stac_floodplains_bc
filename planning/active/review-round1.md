# Review round 1 — #82 branch (`82-produce-the-provenance-floor-and-census`)

Reviewed: `scripts/prov_census-measure.R` (new), `scripts/prov_fields-check.py` (5 new arms),
prose in `CLAUDE.md` / `NEWS.md` / `scripts/README.md`, against `scripts/01_stage.R`,
`scripts/fp_provenance.R`, `scripts/item_validate.py`, `scripts/catalogue_release.sh` and the
org code-check conventions.

Everything claimed was checked by running it. `Rscript scripts/prov_census-measure.R` on the
real tree reproduces the numbers in `CLAUDE.md`/`NEWS.md` exactly (23 rostered / 20 staged /
floor 20, `link_run_uid` 18, `link_config_sha256` + `link_sha` 19, the other nine 20), and
`uv run python scripts/prov_fields-check.py` is 49/0. The five new python arms were
mutation-tested in a copied tree (`scratchpad/mut`, never the repo); four of five fire, the
fifth does not — finding 3.

## Findings

- **[bug]** `scripts/prov_census-measure.R:216-242` — **the reader-call order does not mirror
  `01_stage.R`, and the comment asserts the opposite of the build.** The script puts the
  missing-bundle skip (`:220-228`) *above* `fp_prov_read()` (`:235`). `01_stage.R` does the
  reverse: `wsg_prov <- fp_prov_read(src_wsg)` is line **233**, the `missing_gpkg` skip is line
  **251**. So the comment at `:218-219` — *"Absent, the build skips the whole group before it
  reads any provenance"* — is false, and it is the one ordering claim this script's design rests
  on.

  Consequence, and it is the fail-toward-pass direction the script's own `dir.exists` comment
  (`:271-276`) argues against: a group with **no bundles and a broken record** is a recorded
  *skip* here (census printed, exit 0) and a **hard stop** in the build, because `fp_prov_read()`
  raises before the skip is reached and `01_stage.R` has no per-area `tryCatch`. Every
  `fp_prov_read()` raise is reachable that way — unreadable JSON, a `schema_version` past the
  pin, an unrecognised top-level key, a record declaring another area.

  Measured, in a sandbox of symlinks to the real producer tree with `data/kisp/` reduced to a
  single `provenance.json` carrying `schema_version: 99` and no bundles:

  ```
  WARNING: 4 rostered group(s)/target(s) would not stage:
    KISP  no floodplain.gpkg / floodplain_landcover.gpkg at .../kisp — kisp_all_ff04
  items on the roster: 23   staged: 19   carrying any provenance: 19   <- PROVENANCE_FLOOR
  PROVENANCE_FLOOR=19      # exit 0, pasteable
  ```

  while `fp_prov_read()` on that same directory is:

  ```
  Error : provenance.json at .../kisp/provenance.json declares schema_version 99 but this
  reader implements 2. Update scripts/fp_provenance.R rather than publishing nulls.
  ```

  i.e. a confident paste-ready floor for a tree that stages **nothing**.

  Fix is a move, not a rewrite: hoist the `wsg_prov <- tryCatch(fp_prov_read(...))` block above
  the `missing_gpkg` arm so a failed read is recorded as a *failure* (→ NO CENSUS, exit 1) even
  on a bundle-less group, exactly as the build stops. `fp_prov_read()` returns `NULL` for an
  absent/zero-byte file, so moving it costs nothing on the normal forward-only path.

  Same correction is needed in the three prose copies, all of which state the stronger claim:
  `CLAUDE.md` (*"It mirrors the build's selection **in the build's order**"*), `NEWS.md`
  (*"it mirrors the build's selection in the build's order"*), `scripts/README.md`
  (*"it mirrors the build's **selection in the build's order**, which is load-bearing"*). The
  claim is true of the no-rasters / `fp_prov_*` ordering it then explains, and false of this
  pair — a reader checking it against `01_stage.R` lands on the gpkg block first.

- **[bug]** `scripts/prov_census-measure.R:300-303` — **a target missing `transition.tif` is
  counted as staged, and the build stops on it.** The raster skip is directory-only by design
  (right, per `:271-276`), and the classified years are discovered and reconciled. Nothing checks
  that `transition.tif` exists. `fp_prov_rasters_current()` cannot: `fp_provenance.R:588` is
  `paths <- raster_paths[file.exists(raster_paths)]`, so an absent transition is filtered out of
  the mtime check rather than reported. `01_stage.R:443` then stops the whole build with
  `Missing source raster: <...>/rasters/<scen>/transition.tif`.

  Measured, same sandbox with `kisp/rasters/all_ff04/` holding the three `classified_*.tif` and
  no `transition.tif`:

  ```
  items on the roster: 23   staged: 20   carrying any provenance: 20   <- PROVENANCE_FLOOR
  PROVENANCE_FLOOR=20
  #   18 item(s) with all 12: ..., kisp_all_ff04     # exit 0
  ```

  `kisp_all_ff04` is counted, and no build of that tree reaches `item_create.py`. This is the
  same class as finding 1 and is cheaper to close: the script already builds the full path vector
  at `:301-302`, so one `file.exists()` over it, inside the existing `tryCatch`, turns it into a
  named failure. (It is *not* covered by the accepted "does not open the GeoPackages" decline —
  no `sf`/GDAL is involved, and the README's *"its count can only sit at or above what such a
  build publishes … both of those are loud"* reads as covering it, which it does not: the build
  stopping is loud, but this script's exit 0 is what the operator pastes from.)

- **[fragile]** `scripts/prov_fields-check.py:344-350` — **the "prints … in one block" arm is
  satisfied by a prose comment, so the destination it exists to pin can be deleted and the arm
  stays green.** `_paste` is the raw source text after the `--- paste these` marker, and the test
  is substring presence. `prov_census-measure.R:416` contains the words `prov_fields-check.py`
  inside an explanatory comment that sits *after* that marker, so the third destination is
  already satisfied independently of anything being printed.

  Mutation-tested in the copied tree. Deleting the actual line
  `cat("# scripts/prov_fields-check.py — fixture populations\n")` outright
  (`grep -c 'cat("# scripts/prov_fields-check'` → 0):

  ```
  ok    ...and prints the floor, the census and this file's populations in one block
  ```

  The control fires correctly — deleting the `PROVENANCE_FLOOR=` and
  `# scripts/catalogue_release.sh` `cat()`s gives
  `FAIL … paste block does not name ['PROVENANCE_FLOOR']`. So two of the three destinations are
  pinned and the third is not, which is exactly the one whose absence `#75`'s stale-literal story
  is about. The arm's own comment claims the narrower property it does not have: *"Searched inside
  the paste block only, so a mention in the header does not satisfy it"* — it excludes the header
  and includes comments in the block.

  Fix: search the `cat(` lines rather than the text, e.g. strip `^\s*#` lines out of `_paste`
  before the `in` test, or require the literal `cat("# scripts/prov_fields-check.py` /
  `cat("# scripts/item_validate.py` / `cat("PROVENANCE_FLOOR=` strings.

  The other four new arms do fire, verified by mutation:
  - `link_sha` 21→19 in `PROV_CENSUS` → `FAIL fields sharing one processing:software entry…`
  - `landcover_key` 21→22 → `FAIL PROVENANCE_FLOOR bounds every per-field census count … peaks at 22`
  - `PROVENANCE_FLOOR=21` indented in `catalogue_release.sh` → `FAIL … has no bare PROVENANCE_FLOOR=<n> line`
  - adding `PROV_FIELDS <- c("a")` to the measure script → `FAIL … no 'PROV_FIELDS <- c(' of its own`
  - removing `dir.exists(src_rasters)` from either file, and unanchoring `01_stage.R`'s
    `^classified_[0-9]{4}\\.tif$` → `FAIL … no longer share [...]`
  - measure script absent → all three arms FAIL with their own messages

- **[fragile]** `scripts/prov_census-measure.R:313-317` — two targets of one group declaring the
  **same** `scenario` give one `item_id`, and the two sides of the output then disagree:
  `staged` and `counts` are incremented twice while `absences[[item_id]]` is overwritten, so
  `n_any` (the floor) counts the item once and `PROV_CENSUS` counts it twice. The accounting
  identity at `:366` still passes, because it is over `n_targets` and not over
  `length(absences)`. Low likelihood (needs a duplicated `scenario:` inside one `area.yml`) and
  the new `PROVENANCE_FLOOR bounds every per-field census count` arm would refuse the paste, so
  it is not silent end-to-end — but the refusal would name the wrong cause. `length(absences) ==
  length(staged)` beside the existing identity would close it.

## Checked and clean

- `stage_literal()`: `vapply` over an `expression` works; `is.call(e) && e[[1]] == as.name("<-")
  && e[[2]] == as.name(name)` with `sum(hit) != 1L` → `stop()` covers the three failure shapes
  asked about — moved into a block (0 hits), duplicated (2 hits), and written `=` (0 hits, since
  `=` parses as `` `=` `` not `` `<-` ``). All three are loud and print the name and the count.
  `eval()`'s assignment side effect is harmless (the return value is used).
- `carried` / `counts`: `fp_prov_item()` returns `setNames(..., PROV_FIELDS)`, exactly
  `length(PROV_FIELDS)` elements, each a scalar or `NA` — `fp_prov_leaf()` returns `NA` or
  `cur[[1]]` and rejects lists, so no element can be `NULL` and the `length(v) == 1L && is.na(v)`
  predicate cannot mis-read a zero-length value as carried. The predicate is byte-identical to
  `01_stage.R:712`'s `has_prov`, so `n_any` and the build's `traced` count the same thing.
  `counts + as.integer(carried)` is positional *and* order-identical, and keeps `counts`' names.
- Accounting identity `:366`: exhaustive over every `next`. The missing-`area.yml` branch is
  excluded from all three terms (reported via `no_roster`), `missing_gpkg` and the `fp_prov_read`
  failure each add `length(targets)`, and the three target-level branches add 1. `targets: []`
  and a mapping-shaped `targets:` both stay consistent, and match `01_stage.R`'s disposition.
- Refusal paths: no path prints a pasteable number and exits non-zero; no path prints a census
  and exits 0 other than the deliberate skip banner (and findings 1 and 2). `no_region` is folded
  into `failures` before the gate. The header block is metadata only.
- `absences` / `patterns`: `absences[[id]] <- character(0)` assigns rather than deletes (only
  `NULL` deletes); `vapply` preserves names, so `names(patterns)[patterns == p]` is correct;
  `gsub(..., fixed = TRUE)` on `+` is right; `counts[[f]]` can never miss, since `counts` is
  `setNames(integer(n), PROV_FIELDS)`.
- `system2()`: the convention's trap is handled — `suppressWarnings`, status read off
  `attr(out, "status")`, `!length(out)` for a command that produced nothing, and both
  "not present" / "not a git tree" are stated outcomes. A git-less or space-containing producer
  path degrades to `"not a git tree"` rather than a wrong stamp.
- `[[` vs `$`: `rc[["region"]]`, `rc[["watershed_groups"]]`, `area[["targets"]]`,
  `tgt[["species"]]`, `tgt[["scenario"]]` all use `[[`, matching `01_stage.R`'s two measured
  partial-match hazards. `wsgs` as `union(...)` is the same set *and the same order* as
  `names(wsg_region)`.
- `years`: anchored at both ends in both files, so the `.aux.xml` sidecars cannot double-count;
  `sort(as.integer(...))` is a numeric sort, so no `LC_COLLATE` exposure; a 0- or 1-year
  directory reaches `fp_years_reconcile()` and is refused, as documented.
- The build's call order *within* a target is mirrored exactly: `fp_prov_span` (:396) →
  `list.files` (:402) → `fp_years_reconcile` (:410) → `fp_prov_rasters_current` (:422) →
  `fp_prov_item` (:670). `invisible(FALSE)`/`invisible(TRUE)` assigns fine through `checked`.
- `WSG_ONLY` refusal fires before anything else and prints no numbers.
- No writes, no network, no database, no `sf`/GDAL/`drift`. `digest` is reached (via the
  `landcover_key` fold) and `jsonlite`/`yaml` are loaded; all three are already build deps.
- The measured numbers in `CLAUDE.md` and `NEWS.md` are reproducible from the script today, and
  the DUNC mechanism they describe is correct: `item_create.py:516-520` does raise on a
  half-present `processing:software` entry, and the script's own output shows `dunc_all_ff04`
  missing `link_run_uid + link_config_sha256 + link_sha` while `link_version` is present.
- `census:` line format matches `item_validate.py:2121` byte for byte, so the claimed `diff` works.
- `_release` (`:272`) is defined before `_floor_m` (`:308`) reads it; the raw-string R pattern
  `r"^classified_[0-9]{4}\\.tif$"` is the correct two-backslash literal and matches both R files;
  `re.M` with `^…$` matches `catalogue_release.sh:61` at column 0, which is the same shape
  `catalogue_release-check.sh:579` greps (and that file separately asserts the literal is unique,
  so `re.search` taking the first match is covered).

## Line-reference nits (not reported as findings)

`prov_census-measure.R` cites `01_stage.R:375` twice for the no-rasters skip; the skip is at
`:380` (`:375` is `own_lc <- gpkg_own_layers(...)`). Every other cited line or range resolves
(`:135-160`, `:217-222`, `:250`, `:338-356`, `:396`, `:402`, `:410`, `:422`, `:670`) — except
`:250`, which resolves to the right statement while the sentence around it is wrong (finding 1).
