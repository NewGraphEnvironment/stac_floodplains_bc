# Code-check round 2 — #82 `prov_census-measure.R` + `prov_fields-check.py`

Reviewed 2026-10-15 against `branch.diff` (regenerated after round 1's four fixes), with
`scripts/01_stage.R`, `scripts/fp_provenance.R`, `scripts/item_validate.py` and
`scripts/catalogue_release.sh` read in full. Every claim below was reproduced; nothing in the
working tree was modified. Mutations ran against copies in the session scratchpad
(`scratchpad/r2a…r2f` for `prov_fields-check.py`, `scratchpad/s_t1…s_t6` for sandboxed
producer trees built by `scratchpad/mk2.sh`).

Control runs, so the measurements below are anchored:

- `uv run python <copy>/scripts/prov_fields-check.py` on an unmutated copy — **49 assertions,
  0 failed**.
- `Rscript scripts/prov_census-measure.R` on the real producer tree
  (`floodplains` at `v0.1.13-3-g760b8d9-dirty`), 2026-10-15T18:07:58Z — exit 0, 23 rostered,
  21 staged, floor 21, `link_run_uid` 18, `link_config_sha256`/`link_sha` 20, the other nine 21,
  `larl_all_ff04` + `sloc_all_ff04` skipped (no `rasters/all_ff04/`).

---

## The mechanism behind round 1's four findings

**The shared assumption: fidelity to `01_stage.R` was established by enumerating the conditions
the build applies, and then validated against the one producer tree that exists — a tree on
which each arm's distinguishing case is unreachable.** So every condition was individually
right while its *order*, its *disposition*, and its *subject* were never exercised. In
`code-check.md`'s terms this is *a fixture that cannot reach the failure mode* (the live tree is
the fixture) compounded by *a proxy is not the property* (the presence of a condition standing in
for the build's disposition on it; the presence of a string standing in for the statement being
made).

Each of the four is one distinction that collapses on today's data:

| round-1 finding | the distinction, and why today's tree cannot show it |
|---|---|
| order reversed (skip before read) | no group is simultaneously record-broken and bundle-less |
| absent `transition.tif` counted as staged | every rostered target that has a raster dir has one |
| assertion satisfied by an R comment | the pinned token happens to sit in prose as well as code |
| two targets, one scenario | no `area.yml` carries a `targets:` block at all |

**Where that mechanism still reaches in this diff** — three places, all reproduced:

1. **`prov_fields-check.py`'s `_mirror` arm, `area[["targets"]]` entry** — the comment-vs-code
   confusion that round-1 #3 fixed, one axis over, in the sibling arm added by the same commit.
   Finding 1 below; **the arm cannot fire.**
2. **`prov_fields-check.py`'s `_paste` arm** — the comment strip handles whole-line comments
   only, so a trailing `#` re-opens exactly the hole it closed. Finding 2.
3. **`prov_census-measure.R`'s group-level order** — the fix hoisted `fp_prov_read` above the
   *existence* arm and left the *readability* arm that sits immediately below it in
   `01_stage.R` and shares its disposition. Finding 3; it produces a **false refusal** whose
   message is also wrong.

---

## Findings

### 1. **[bug]** `scripts/prov_fields-check.py:371-378` — the `area[["targets"]]` mirror assertion cannot fire: both files carry the string in a comment

`_mirror` tests `e in _stage and e in _measure` over whole-file text. For
`'area[["targets"]]'` that string is present as *prose* in both files, three lines above the code
it is meant to pin:

- `scripts/01_stage.R:222` — ``# `area[["targets"]]` is NULL for that file, which is the answer the fallback below wants.`` (code at `:223`)
- `scripts/prov_census-measure.R:200` — ``# `area[["targets"]]`, never `area$targets`: the producer is mid-way through retiring target`` (code at `:203`)

Both comments exist *to explain why `$` must not be used*, so a regression to `area$targets`
would never delete them — which is exactly the state that defeats the arm.

Reproduced (copy at `scratchpad/r2a`, working tree untouched): regress only the measure script's
code line, keep its comment —

```
  targets <- area$targets
```

```
  ok    ...and mirrors the three roster expressions that decide what is counted
49 assertions, 0 failed
```

Same result regressing `01_stage.R:223` instead (`scratchpad/r2b`): **ok, 0 failed.**

The other two entries do fire, so the hole is specific to this one:

| mutation | result |
|---|---|
| measure script's pattern unanchored (`^…$` dropped) | FAIL — names `['^classified_[0-9]{4}\\.tif$']` |
| measure script's `dir.exists(src_rasters)` → `file.exists(…)` | FAIL — names `['dir.exists(src_rasters)']` |
| measure script's `area[["targets"]]` → `area$targets` | **ok** |
| `01_stage.R`'s `area[["targets"]]` → `area$targets` | **ok** |

Why it matters rather than being cosmetic: `$` partial-matches, so `area$targets` returns a
`targets_retired:` block — the measured case `01_stage.R:217-222` records, where it stages
`morr_co_ff04` + `morr_ch_ff06`. In the measure script that defect **inflates
`PROVENANCE_FLOOR` and every `PROV_CENSUS` row with retired targets nobody publishes**, and the
number is then pasted into a release gate. It is also the one of the three expressions where the
two files' walks can diverge *silently* — the other two change which items are counted in ways a
skip line or a refusal would show.

Fix: compare code only, not file text. Strip whole-line R comments from both sides before the
`in` test (the same two-line transform already written for `_paste` just below, which would work
here), or anchor the match to the assignment —
`"targets <- area[[\"targets\"]]"` — which appears in neither comment.

### 2. **[fragile]** `scripts/prov_fields-check.py:357-367` — the paste-block strip removes whole-line comments only, so a trailing `#` comment still satisfies the arm with the `cat()` deleted

`"\n".join(ln for ln in _paste.splitlines() if not ln.lstrip().startswith("#"))` is the
round-1 fix, and it is correct for the defect found then. R also permits trailing comments, and
those survive the strip.

Reproduced (`scratchpad/r2e`, `r2f`):

| mutation | result |
|---|---|
| `cat("# scripts/prov_fields-check.py — fixture populations\n")` deleted | FAIL — "paste block does not name `['prov_fields-check.py']`" |
| same deletion **plus** a trailing `# for prov_fields-check.py` on the `patterns <- vapply(…)` line | **ok, 0 failed** |

Lower severity than finding 1 because it needs someone to write that comment rather than merely
to leave an existing one in place — but it is the same guard-satisfied-by-prose shape, and the
remedy is the same one line: drop everything from the first unquoted `#` on each line, not only
lines that start with one. I confirmed the strip does **not** over-remove anything today: no
line of the paste block's code begins with `#` (every R string there opens with `"` or `'`), and
each of the three destination tokens appears in exactly one `cat()`.

### 3. **[fragile]** `scripts/prov_census-measure.R:229-248` — the build's *second* group skip is unmirrored, so an unreadable bundle plus a re-keyed record turns a build skip into a refusal, with a message that says the opposite

`01_stage.R` has **four** group/target skip arms: `:207` (no `area.yml`), `:250` (bundle
absent), **`:265` (bundle present but unreadable)**, `:380` (no raster dir). Round 1 fixed the
position of `fp_prov_read` relative to `:250`. `:265` sits immediately below `:250`, carries the
*same* disposition (`skipped <- c(skipped, wsg); next`), and sits **above** the target loop at
`:322` — so a group whose bundle cannot be opened never reaches `fp_prov_span()`.

The measure script checks existence only (a named decline, and existence is where the decline
was argued). The decline's stated justification is that every unmirrored arm "makes a real build
stage FEWER items or stop outright, so this script's count can only sit at or above what such a
build publishes, and both of those are loud"
(`prov_census-measure.R:52-64`). That reasoning covers the *count*; it does not cover the case
where the missing arm changes whether a count is produced at all.

Reproduced (`scratchpad/s_t6`): BULK with `floodplain.gpkg` replaced by 200 random bytes (exists,
unreadable — `gpkg_layer_keys()` on it raises *"Open failed."*, verified) and
`primary_scenario: xx_ff04` against a record holding only `all_*`/`co_*`:

```
NO CENSUS: 1 read(s) failed. A build of this tree stops on the first of them,
so any count printed here would describe nothing that gets published.
  - bulk_xx_ff04: provenance.json bulk_xx_ff04: the floodplain section has no 'xx_ff04' key …
EXIT=1
```

A build of that tree does **not** stop — it skips BULK at `:265` and carries on. So the script
refuses on a tree the build is happy with, and the refusal line asserts the opposite of what the
build does. The direction is the safe one for the floor (no number is pasted), which is why this
is `fragile` rather than `bug`, but both halves of the conjunction are documented live states:
the unreadable bundle is the "`$FLOODPLAINS_DATA` is stale or mid-recompute" state `:257-260`
exists for, and a target whose record does not describe it is the state `larl`/`sloc` are in
today (and `kotl` was in earlier this same session). An upstream `run_region.R` in flight — the
documented operating condition this script carries a timestamp for — is where both land at once.

Two ways out, either acceptable:
- Mirror the arm cheaply without GDAL: a group whose `*.gpkg` does not begin with
  `SQLite format 3\0` is a skip, which catches the truncated / mid-write / zero-byte cases the
  comment names (stdlib `readBin`, no `sf`).
- Or keep the decline and make the refusal honest: say "a build of this tree stops *or skips the
  group*", and note in `:52-56` that the unmirrored readability arm can convert a build skip into
  a refusal here.

### 4. **[fragile]** two line citations in `prov_census-measure.R` comments are wrong

The brief asks for each one; I checked all 23. Twenty-one are right (`01_stage.R` 135-160,
138-143, 148-151, 166-177, 217-222, 233, 250-256, 251, 380, 396, 402, 410, 422, 443, 670;
`fp_provenance.R` 147-166; `fp_provenance-check.R` 24-30; and
`catalogue_release-check.sh`'s anchored `^PROVENANCE_FLOOR=` grep at `:579`, verified). Two are
not:

- **`:252`** — "The same two assertions `01_stage.R:338-356` makes where the roster is read".
  The two assertions are at **`:328-331`** (`!is.list(tgt)`) and **`:342-353`** (the
  `species`/`scenario` loop). `338-356` is the comment block plus the second assertion; it
  **excludes the first**, which is the one whose ordering is load-bearing (`01_stage.R:324-327`
  says so explicitly: it must run before the two extractions, which the measure script's
  `:255-266` does). Round 1's first finding stayed invisible behind exactly this kind of
  mis-cited ordering justification. Should read `01_stage.R:328-353`.
- **`:310`** — "`fp_prov_rasters_current()` filters to `file.exists()` (fp_provenance.R:588)".
  The filter is **`:589`**; `:588` is the closing brace of the preceding `stop()` block.

### 5. **[fragile]** `scripts/README.md` — "Three rostered targets are in exactly that state today", undated and already two

The README's new section states the quantity with no date, unlike the `CLAUDE.md` and `NEWS.md`
copies beside it, which carry 2026-10-15 and explain that the denominator moves per build.
Measured through the script on the real tree at 2026-10-15T18:07:58Z — the same day — it is
**two** (`larl_all_ff04`, `sloc_all_ff04`); `kotl` now stages, and `mcgr`/`pine` now carry
records, so the census is 21 staged / floor 21 / `link_run_uid` 18 / `link_config_sha256` 20 /
`link_sha` 20 / nine at 21, not the 20-staged shape the same-day notes record. The notes'
own framing makes their numbers self-dating; the README sentence does not, and "today" in a
tracked file is permanent. Dropping the count ("rostered targets are in that state today —
`prov_census-measure.R` names them") removes the quantifier that has to be maintained.

---

## The fixes themselves — verified, in the states they were written for

### Round-1 fix 1: the hoisted `fp_prov_read`

`prov_census-measure.R:229-248` now matches `01_stage.R`'s order (`fp_prov_read` at `:233`,
bundle existence at `:250-256`). Walked the full matrix in sandboxed one-group producer trees:

| record | bundles | measure script | `01_stage.R` | agree |
|---|---|---|---|---|
| present | present | census, exit 0 (`s_ctrl`) | stages | yes |
| **raises** (truncated JSON) | **absent** | **failure**, no census, exit 1 (`s_t1`) | raises at `:233` → stops | yes |
| absent (NULL) | absent | skip → "nothing staged" refusal, exit 1 (`s_t2`) | NULL, then skip at `:251` | yes |
| present | absent | skip (verified inside `s_t5`-shaped runs) | skip at `:251` | yes |
| raises | present | failure, no census | raises at `:233` | yes |
| absent | present | census; item counted in the floor's denominator, carrying none | stages, `traced` empty | yes |

Also confirmed the *target*-level readers were correctly left **below** the bundle arm: a
readable record that does not describe a target (`fp_prov_sections` refusal) only raises inside
the target loop in both files, so a group with missing bundles **and** a re-keyed record is a
skip in both — which is the right half of the pair. (The wrong half is finding 3, where the
bundle is unreadable rather than absent.)

Accounting stayed exhaustive after the move. `n_targets` is incremented once per group before
any disposition; the group failure arm adds `length(targets)`, the group skip arm adds
`length(targets)`, and each per-target arm adds 1 — asserted at `:383-388` before any number
prints. The one arm that is in neither count (`no area.yml`, `:193-198`) is reported separately
at `:407-410`. I could not construct a state that satisfies the identity while losing an item:
`targets: []` gives `length(targets) == 0` on all three arms consistently, a non-list `targets:`
scalar is length 1 and lands in the per-target failure arm, and `yaml::read_yaml()` raising on a
malformed `area.yml` or region file aborts the run non-zero before the print section — the same
disposition `01_stage.R` has (no `tryCatch` there either).

### Round-1 fix 2: the `transition.tif` arm

Placed at `:316-320`, i.e. after `fp_prov_rasters_current()` and before `fp_prov_item()` —
which is where `01_stage.R:443`'s `stop("Missing source raster: …")` sits, between `:422` and
`:670`. Correct, and the ordering is observable: with both an absent `transition.tif` and a
raster newer than the record, both files report the mtime refusal first.

Reproduced (`s_t3`): removing `transition.tif` gives
`NO CENSUS … bulk_all_ff04: Missing source raster: …/transition.tif`, exit 1.

I checked `01_stage.R:430-460` for anything else it demands of the source rasters that this
script does not, as asked. The loop at `:440-450` makes exactly two demands: `file.exists(src)`
for every member of `raster_map` (now covered — and `raster_map`'s members are precisely the
discovered `classified_%d.tif` set plus `transition.tif`, which is the vector the measure script
builds), and `file.copy()` returning TRUE, which is a write and has no analogue here. Nothing
else. The classified members exist by construction (they came from `list.files()`), so the arm's
own comment is right that `transition.tif` is the only one it can catch; including the others
costs nothing and is correct if `list.files()` ever changes.

Separately verified the comment's premise that a raster dir holding 0 or 1 `classified_*.tif`
reaches the reader rather than skipping: `fp_years_reconcile()` (`fp_provenance.R:523-527`)
stops on `length(years_disk) < 2`, and `:528-534` stops when `TRANSITION_SPAN` is not covered.
`01_stage.R` has no per-area `tryCatch`, so both are build stops, and both land in the measure
script's failure arm. The `!dir.exists()`-only skip at `:283` is therefore the right split.

### Round-1 fix 3: the comment strip

Fires on the state it was written for; see finding 2 for the axis it does not cover.

### Round-1 fix 4: the duplicate-id refusal

`:394-401` fires in exactly the state it describes and I could not make it false-fire.

Reproduced (`s_t4`): two targets of one group, `{all, all_ff04}` + `{co, all_ff04}` (the real
shape, since `item_id` carries no species) —

```
NO CENSUS: 2 staged target(s) but 1 distinct item id(s) — repeated: bulk_all_ff04.
Two targets of one group declare the same scenario, so the census counts an item twice.
EXIT=1
```

False-fire analysis of the second clause, `length(absences) != length(staged)`:

- `absences[[id]] <- PROV_FIELDS[!carried]` with every field carried assigns `character(0)`,
  which `[[<-` **stores** rather than deleting (only `NULL` deletes). Confirmed empirically —
  the control run counts `1 item(s) with all 12: bulk_all_ff04` and passes the identity.
- `[[<-` with a character index matches exactly, so no partial-match collision.
- ids are `paste0(wsg, "_", scenario)` with both parts validated non-empty, and `wsgs` is
  de-duplicated by `union()` after `tolower()`, so two groups cannot produce one id.
- `fp_prov_item()` always returns a length-12 list, so `carried` cannot be zero-length.

And it does **not** fire in the benign neighbour: two targets with different scenarios, one with
no raster dir (`s_t5`) → 2 rostered, 1 staged, 1 skipped by name, census printed, exit 0.

### The two new `prov_fields-check.py` literal arms

Both correct and both fire. `_uneven` is driven off `PROV_SOFTWARE`, whose single-field entries
(`flooded`, `drift`) can never make `len({…}) > 1`, so only the `link` pair is asserted — which
is the only two-field entry and the only pair `item_create.py` can refuse half-present. The
floor arm's `max(PROV_CENSUS.values()) <= floor` is safe against an empty dict because
`item_validate.py:555` already asserts `PROV_CENSUS` covers `PROV_FIELDS`, and it reads the floor
with the same anchored pattern `catalogue_release-check.sh:579` uses.

Worth recording: on the current tree the script prints `link_version` 21 against `link_sha` 20,
so **the pairing arm would refuse this build's own census if it were pasted** — which is the
designed outcome (`item_create.py` raises on that tree), and is the arm doing its job rather than
a defect.

### Checked and clean

- No writes, no network, no database, no `sf`/GDAL/`drift`: the script only `parse()`s
  `01_stage.R` (never sources it), `source()`s `fp_provenance.R`, reads YAML/JSON, stats files,
  and shells out to `git`. `fp_provenance.R` defines no `PROV_FIELDS` of its own, so the
  `source()` at `:103` cannot shadow the parsed literal — it only *consumes* it, and
  `fp_provenance.R:136-137` asserts `FP_PROV_MAP` against it at source time, which is a second
  join in the right direction.
- `stage_literal()` is the `fp_provenance-check.R:24-30` construction exactly, with
  `sum(hit) != 1L` refusing both zero and two assignments. `eval()` of an assignment expression
  returns the value, so `PROV_FIELDS`/`TRANSITION_SPAN` are the parsed ones.
- `system2(stdout = TRUE)` is handled per the house rule: `suppressWarnings`, and the status
  read off `attr(out, "status")` rather than from a `tryCatch` that would never fire.
- The timestamp is `format(Sys.time(), "…Z", tz = "UTC")` — the `Z` is honest.
- `counts` stays **integer** end to end (`setNames(integer(…))` + `as.integer(carried)`), so the
  `sprintf("%d", …)` calls at `:411` and `:441` cannot hit `invalid format`.
- The `census:` line is byte-identical to `item_validate.py:2121`
  (`"census: " + ", ".join(f"{f} {census[f]}" …)`), and both files' `PROV_FIELDS` are in the
  same order (compared literal to literal), so the claimed `diff` really is one.
- The "carrying" predicate (`length(v) == 1L && is.na(v)`) is the same one `01_stage.R:712` uses
  for `has_prov`, so the floor's definition matches the build's.
- `WSG_ONLY` refusal, the `no region:` recording, and the zero-staged refusal all behave as
  documented (`s_t2` and the sandboxes above).
- `scripts/README.md` and the `CLAUDE.md`/`NEWS.md` additions carry no private host, tunnel or
  private-repo references.

### Not re-flagged (accepted tradeoffs in the brief)

The mirror-rather-than-share deferral (#90), the two named declines (GeoPackage layer keys,
`drift_version` against installed `drift`), the deliberately stale `PROV_CENSUS` /
`PROVENANCE_FLOOR` / fixture counts, exit 0 with a skip banner, and comment density. Finding 3
is reported because the brief asks for places the two walks *actually disagree*, and that
conjunction is one — it is about the unmirrored arm's effect on whether a census is produced,
not about the decline itself.
