# Code-check round 3 — `prov_census-measure.R` (NEW) + `prov_fields-check.py` (#82)

Reviewed 2026-10-15, ~18:20–18:40Z. Branch `82-produce-the-provenance-floor-and-census`
at `d0addac`. Diff regenerated after rounds 1 and 2.

**Verdict: no bugs found.** One stale undated count in a comment (fragile, below). Both
enumeration tables are below as required, built from the source rather than from the brief.

---

## Step 1 — attacking the enumeration of source-text reads

### Is the candidate set actually eight?

Enumerated mechanically over the whole file, not from the brief:

```bash
grep -n "read_text\|ast\.\|in _release\|in _measure\|in _stage\|re\.search\|re\.findall\|re\.match\|\.split(\|literal(" scripts/prov_fields-check.py
```

That returns lines 230, 284, 285, 286, 314, 323, 356, 376, 380–383, 394–395, 412, 415 —
**no ninth read**. `prov_census-measure.R` reads source text once (`parse(file.path("scripts",
"01_stage.R"))` at :94, consumed only through `stage_literal`'s AST walk at :96–97, never by
text matching), so the set is complete across both changed files.

| # | arm | reads | mechanism | immune? | mutation proven to fire |
|---|---|---|---|---|---|
| 1 | "item_create.py and item_validate.py publish the same map" | `item_create.py` `PROV_PROPERTIES`/`PROV_SOFTWARE` | `literal()` → `ast.parse` + `literal_eval` | yes — a comment is not an AST node | pre-existing (#74) |
| 2 | "02_raster_tag.py tags exactly the fields the map publishes" | `02_raster_tag.py` `PROV_FIELDS` | same AST walk | yes | pre-existing |
| 3 | 3 arms on `only_preflight` (`op.NEW`, `op.SOFTWARE`, `op.PREFIXES`) | the module | **import**, not text | yes | pre-existing |
| 4 | "the release path runs it rather than an inline program" | `catalogue_release.sh`, 400-char window after `only_prov=$(curl` | `_code_only(…, word_start=True)` | yes | **m15** ✓ — replaced the pipeline with `python3 -c "…"  # was: \| python3 scripts/only_preflight.py` (round 2's exact defeat) and the arm fired |
| 5 | "PROVENANCE_FLOOR bounds every per-field census count" | `catalogue_release.sh` **raw** text | `re.search(r"^PROVENANCE_FLOOR=([0-9]+)$", re.M)` | yes — anchored at both ends at column 0, so a comment line cannot match (a `#` would precede). Deliberately the raw text: it mirrors the consumer, `catalogue_release-check.sh:579`'s `sed -n 's/^PROVENANCE_FLOOR=\([0-9][0-9]*\)$/\1/p'`, and :588 there already asserts the literal is *one* bare integer, closing the "two matching lines, `re.search` takes the first" hole | **m9** ✓ (floor 21→20, fires: "the floor is 20 and the census peaks at 21"); **m10** ✓ (indented, fires: "no bare `PROVENANCE_FLOOR=<n>` line") |
| 6 | "parses its literals out of 01_stage.R rather than copying" | `prov_census-measure.R` | `_code_only` | yes | **m7** ✓ (replaced `stage_literal("PROV_FIELDS")` with a copy); **m16** ✓ (copy *added* while keeping the parse); **m17** ✓ (`TRANSITION_SPAN` hardcoded); **m18** ✓ (script deleted → names the absence) |
| 7 | "…prints the floor, the census and this file's populations in one block" | `prov_census-measure.R` after `--- paste these` | `_code_only` + `split` | yes | **m1/m2/m3** ✓ (each of the three `cat()` destinations deleted in turn, each named in the failure); **m13** ✓ (round 1's defect: `cat()` replaced by a *comment* naming the file); **m14** ✓ (round 2's defect: `cat("# fixture populations\n")  # was: scripts/prov_fields-check.py`) |
| 8 | "…mirrors the three roster expressions that decide what is counted" | `01_stage.R` **and** `prov_census-measure.R` | `_code_only` on both sides | yes | **m4/m5/m6** ✓ (each of the three expressions broken in the census: `area$targets`, unanchored pattern, `file.exists` for `dir.exists`); **m12** ✓ — round 2's measured defeat, rewriting the subscript in **both** files, now fires |

New non-text arm, for completeness: `_uneven` (`PROV_SOFTWARE` × `PROV_CENSUS`, in memory,
no source read) — **m8b** ✓: `"link_sha": 21` → `20` fires it with
`link publishes as ONE entry but the census says {'link_version': 21, 'link_sha': 20}`.

Control: 49 assertions, 0 failed, both in place and from a copied tree. Every mutation was
run against a copy of `scripts/` under the scratchpad; the repo tree was never touched.

### Is `_code_only()` correct? Run over all three files it is applied to

Measured three ways over `01_stage.R`, `prov_census-measure.R` (R rules) and
`catalogue_release.sh` (`word_start=True`):

| probe | 01_stage.R | prov_census-measure.R | catalogue_release.sh |
|---|---|---|---|
| lines where the cut removed text that is **not** a comment (over-strip) | 0 | 0 | 0 |
| lines where a `#` **survived** the strip (candidate under-strip) | 5 | 5 | 16 |
| of those, an actual surviving comment | **0** | **0** | **0** |
| lines left with an open quote at end (per-line desync risk) | 0 | 0 | 18 |

Every surviving `#` is correctly kept: in `01_stage.R` they are inside string literals
(`"^#[0-9A-Fa-f]{6}$"`, `floodplains#30`, `(#65)`, `floodplains#131`); in
`prov_census-measure.R` they are the five `cat("# …")` lines of the paste block — which is
exactly the text arm 7 must see, and the whole reason the cut is quote-aware rather than
at the first `#`; in `catalogue_release.sh` they are shell parameter expansions
(`$#`, `${tag#v}`, `${live_state#OK }`, `${_d#*|}` …). The docstring's "seven of those in
catalogue_release.sh, measured" checks out:
`grep -o '\${[A-Za-z_][A-Za-z0-9_]*#' scripts/catalogue_release.sh | wc -l` → **7**.

Single-quote handling, the one asymmetry in the function (`esc` is set only inside `"`):
`prov_census-measure.R:446` is the one line in either R file mixing both quote kinds
(`cat('    "', f, '": ', …)`) and it survives intact. Neither R file contains `\'`, so the
asymmetry is unreachable today.

**The one real limitation, stated rather than reported as a defect:** `_code_only` resets
quote state per line, so it cannot see a multi-line string literal. No R line in either
file leaves a quote open today (probe above), so no R desync is possible. `catalogue_release.sh`
has 18 such lines — the embedded `python3 -c` programs at :224, :274, :524, :599, :908, :960,
:985, :1014, :1122 — but all sit far from the only window a bash arm reads (lines 426–427),
the control passes and m15 fires, so the one bash arm is unaffected. If either R file ever
gains a multi-line string, a `#` inside it on a continuation line would be stripped;
the probe for that is one command and it is already written above.

**Conclusion on step 1: the enumeration holds. No ninth read, no mis-strip, no under-strip,
and all 14 mutations fire, including both defects earlier rounds measured as defeats.**

---

## Step 2 — attacking the FIRST mechanism: fidelity to `01_stage.R`

Built from `01_stage.R` itself, not from the brief. Every condition the script applies
between reading the roster and writing an item's `meta.json`, in file order, with the
census's disposition. `M` = mirrored, `D` = deliberately declined (named in the header),
`—` = cannot affect the staged set.

### Before the roster (outside #82's stated range, listed because each one stops the build)

| `01_stage.R` | condition | census |
|---|---|---|
| :16, :25–26 | `library(sf)`, `fp_gpkg.R`, `gpkg_pin_date()` | D (no sf; the census writes nothing, so the pin is irrelevant) |
| :85–87 | wipes `data/raw`, `data/stac` | — |
| :104–105 | `drift::dft_class_table("io-lulc")` | D — covered by the header's "no `drift`/`sf`/GDAL", though not enumerated there by name |
| :111–118 | four `stopifnot` arms on the class table (**stops the whole build**) | D, same clause. Direction: build stops, census over-counts → the header's closing sentence covers it ("stage FEWER items or stop outright … both of those are loud") |

### The roster

| `01_stage.R` | condition | census |
|---|---|---|
| :135–136 | `list.files(config/regions, "\\.yml$")` | **M** (:143–144), plus an extra refusal when the directory is empty (:145–149) — a *new* arm, loud, no build equivalent needed |
| :147 | `yaml::read_yaml(rf)` can raise | **M** in effect — not in a `tryCatch`, so a malformed region file aborts the census (exit 1) exactly as it aborts the build. Different message, same disposition |
| :149–151 | no `region:` → **stop** | **M** (:157–160 records it; :346–349 turns it into a failure → exit 1). The census finishes the walk first rather than stopping at the file, but the outcome (no census, exit 1) is the same |
| :152–159 | duplicate group across regions → `warning`, first region wins | **M** by `union` (:161). **Measured identical on the real tree:** both walks yield the same 23 groups in the same order (`identical(a, b)` TRUE) |
| :161 | `wsgs <- names(wsg_region)` | **M** — order preserved by `union` |
| :167–175 | `WSG_ONLY` → one group + `PARTIAL_STAGE` | **M**, as a refusal (:81–86). Stronger than the build, deliberately: a full-roster census from a one-group tree is the asymmetry being produced |

### Per group

| `01_stage.R` | condition | census |
|---|---|---|
| :207–211 | no `area.yml` → **group SKIP** | **M** (:196–201). Not counted in `n_targets` (its targets are unknowable) and reported separately at :417–420 — verified with a `NOAREA` group |
| :212 | `yaml::read_yaml(area_yml)` can raise | **M** in effect (uncaught → exit 1, as the build raises) |
| :223–227 | `area[["targets"]]`, never `$`; fallback to `{species, primary_scenario}` | **M** (:206–209). Pinned by arm 8 |
| :233 | `fp_prov_read()` — NULL is normal, a raise is not | **M** (:232–239), **above** the bundle arm, matching the build's :233-before-:251. Round 1's fix verified in place |
| :250–256 | both bundles absent → **group SKIP** | **M** (:243–251), existence only — verified with a `NOGPKG` group |
| :265–275 | a bundle that cannot be **READ** → **group SKIP** | **D** (round 2's fix). Named twice: in the header's declines and inside the refusal message at :351–357 ("stops **or skips its group**"). This is the one decline where the build's disposition is a *skip* rather than a *stop*, which is why the refusal must not claim the stronger one |
| :297–305 | a layer with no usable item key → **stop** | **D** (needs `sf`) |
| :306–314 | a layer of a foreign watershed group → **stop** | **D** (needs `sf`) |

### Per target

| `01_stage.R` | condition | census |
|---|---|---|
| :328–331 | target is not a mapping → **stop** | **M** (:258–259), and the same guard is repeated defensively inside `target_ids` (:214) so a bare-scalar `targets:` entry cannot raise `[[` there either |
| :342–353 | `species`/`scenario` not a usable scalar → **stop** | **M** (:261–268), same `is.character`/`length`/`is.na`/`nzchar` order |
| :354–356 | `item_id <- paste0(wsg, "_", scenario)` | **M** (:277) |
| :370–377 | `sp_prefix`, `ff_layers`, `needed`, `gpkg_own_layers()` (**above** the raster skip, and can raise) | **D** (needs `sf`) |
| :380–384 | `!dir.exists(src_rasters)` → **target SKIP** | **M** (:286–290). Directory-only, with the reason the one-raster case must *not* be treated as a skip written out at :280–285. Pinned by arm 8 |
| :396 | `fp_prov_span()` | **M** (:304), first reader call, same order |
| :402–404 | anchored `^classified_[0-9]{4}\.tif$` → `years` | **M** (:305–307), byte-identical expression. Pinned by arm 8 |
| :410–415 | `fp_years_reconcile()` → raise, or FALSE = "unchecked" | **M** (:308, :325, :334, :422–429), and it reports the same `N of M staged item(s) took their year set from disk` line the build prints |
| :422–426 | `fp_prov_rasters_current()` (mtime guard) | **M** (:311), same argument list |
| :429–432 | `dir.create` staging dirs | — |
| :435–443 | `if (!file.exists(src)) stop("Missing source raster")` over `classified_<y>.tif` × n + `transition.tif` | **M** (:309–323). Round 1's fix; the path set is identical to the build's `raster_map` srcs, and it is placed *between* `rasters_current` and `fp_prov_item`, which is where the build's stop sits |
| :449 | `file.copy` returning FALSE → `stopifnot` | — (no copy) |
| :475–485 | an item's own layer set empty → **stop** | **D** |
| :486–497 | own set all aspatial → **stop** | **D** |
| :500–503 | `gpkg_copy_layers()` | **D** |
| :520–527 | aspatial tables report | — (message only) |
| :540–551 | `unfamiliar` family report | — (message only) |
| :570–577 | `gpkg_extract_layer()` of `transition_<scenario>_<span>` → raises if absent | **D** |
| :598–611 | staged `floodplain.gpkg` missing a `needed` layer → **stop** | **D** |
| :612–631 | `read_area_km2`, footprint `st_read`/`st_union`/`st_transform`, GeoJSON round trip | **D** |
| :638–641 | `tree_transition_metrics()` | **D** |
| :643–661 | `meta` assembly; `region = wsg_region[[wsg]]` | — (not a provenance field) |
| :670 | `fp_prov_item(wsg_prov, species, scenario, item_id, years)` | **M** (:324), same argument list, last reader call as in the build |
| :681–695 | `drift_version` ≠ installed `drift` → **stop** unless `ALLOW_DRIFT_SKEW` | **D**, named in the header |
| :708–710 | `write_json(meta, …, na = "null", null = "null")` | — |
| :712–714 | `has_prov` = any field non-NA → `traced` | **M** (:335, :413) — `n_any` uses the identical `length(v) == 1L && is.na(v)` test |

### Environment variables that change what the build stages

Enumerated by `grep -n Sys.getenv` over `01_stage.R`, `fp_provenance.R`, `fp_gpkg.R`:
exactly four. `FLOODPLAINS_DATA` **M** (:74, same default), `WSG_ONLY` **M** (refused),
`ALLOW_DRIFT_SKEW` **D** (named), `ALLOW_SKIPPED` — reported at :136 and correctly does
**not** change the census, because in the build it only governs the `PARTIAL_STAGE` marker
(:794–805), never what stages. No fifth.

### Misses

**None.** Every build condition in the table is mirrored, or declined with the decline
named in the header, and every decline is in the conservative direction: the build either
stages fewer items than the census counts or stops outright. Both are loud, because
`PROVENANCE_FLOOR` and `PROV_CENSUS` are **exact in both directions** — `item_validate.py`
refuses a floor above *or* below the build, so there is no silent direction for a census
that is too high. And the census cannot be too *low*, because every condition it applies
that the build does not have at that point (the empty-regions refusal, the `WSG_ONLY`
refusal, the duplicate-item refusal, the `n_targets` identity) exits non-zero with no
number rather than printing a short one.

### Load-bearing behaviour verified by running it, not by reading it

- Real tree, 18:24Z: exit **1**, `NO CENSUS: 1 read(s) failed` on `larl_all_ff04`
  (landcover section holds `bt_ff04`) — which is where `01_stage.R:396` stops the build too.
- Real tree, 18:33Z (the upstream `columbia` run having landed in between): exit **0**,
  23 rostered / 22 staged / floor 22, `sloc_all_ff04` skipped for no `rasters/all_ff04/`.
  Confirmed directly upstream: `kotl` and `larl` now hold `rasters/all_ff04` *and* an
  `all_ff04` landcover key; `sloc` holds only `bt_ff04`.
- That run also exhibits the pairing the header and `_uneven` exist for, live:
  `link_sha` **21** against `link_version` **22**. Verified end to end —
  `data/dunc/provenance.json`'s `network.all2.inputs.link` is
  `{sha: null, sha_source: "unresolved_version_mismatch", version: "0.50.0"}`, and
  `item_create.py:506–520` raises `"<id>: link software entry is half-present"` on exactly
  that. So the CLAUDE.md/NEWS claim that a build of today's tree aborts is correct, and
  `_uneven` would refuse these numbers if pasted. The paste block printing them anyway is
  the documented split (header :35–37).
- One-group sandbox: census printed, paste block at column 0, `census:` line byte-identical
  in format to `item_validate.py:2121`'s `print("census: " + ", ".join(f"{f} {census[f]}" …))`.
- Two-target sandbox, same scenario twice: the duplicate arm fires
  (`NO CENSUS: 2 staged target(s) but 1 distinct item id(s) — repeated: bulk_all_ff04`),
  which is round 1's finding (d) proven to fire.
- Two-target sandbox, different scenarios, plus a provenance-less group: 3 on the roster,
  3 staged, floor 2, and the fixture populations grouped as
  `2 item(s) with all 12` / `1 item(s) with none at all`.
- `NOAREA` / `NOGPKG` / no-rasters sandbox: all three skip paths reported by name, the
  `n_targets` identity satisfied (4 = 2 staged + 2 skipped + 0 failed) with the
  no-`area.yml` group correctly in neither count.

### R semantics the script depends on, each measured rather than assumed

- `fp_prov_item()` returns `setNames(out, PROV_FIELDS)` (`fp_provenance.R:613–621`), so
  `counts + as.integer(carried)` at :336 — which is **positional**, `as.integer` having
  dropped the names — cannot mis-attribute a count. Verified that `c(p=1L,q=2L) + c(1L,0L)`
  keeps `p`/`q`.
- `absences[[id]] <- character(0)` **keeps** the element (only `NULL` deletes), so the
  `length(absences) != length(staged)` arm at :404 cannot fire falsely on an all-carried item.
- `list(1,2)[["scenario"]]` returns `NULL`, not an error, so neither `target_ids` (:214)
  nor the build's `tgt[[f]]` (:343) can raise "subscript out of bounds" on an unnamed
  `targets:` entry — both produce their named refusal instead.
- `isTRUE(invisible(TRUE))` is TRUE, so `year_checked` at :325 reads
  `fp_years_reconcile`'s invisible return correctly.
- `system2(…, stdout = TRUE)` warns rather than raises on non-zero exit; `git_stamp`
  (:117–127) reads the status off `attr(out, "status")` as the convention requires, and
  returns `"not a git tree"` for the sandboxes (observed).
- `gsub("+", " + ", p, fixed = TRUE)` at :466 — `fixed = TRUE` present, so the `+` is literal.
- Every `nzchar()` is guarded by an `is.na()` first (:215, :263), except :157, which is a
  byte-for-byte mirror of `01_stage.R:149` and therefore not a new defect.

### Citations

All 21 `file:line` citations in `prov_census-measure.R` were resolved against the files
they name — `01_stage.R` :135–160, :138–143, :148–151, :166–177, :217–222, :233, :250–256,
:251, :265–275, :328–353, :380, :396, :402, :410, :422, :443, :670; `fp_provenance.R`
:147–166, :589; `fp_provenance-check.R` :24–30. **All correct.** Round 2's two wrong
citations are fixed and no new ones were introduced. The claims that
`catalogue_release-check.sh` greps the floor with an anchored pattern (`:579`) and that
`item_validate.py` prints the census in that exact format (`:2121`) both check out.

---

## Findings

- **[fragile]** `scripts/prov_census-measure.R:167–170` — the parenthetical "Three rostered
  targets are in exactly that state (kotl/larl/sloc declare `all_ff04` while their landcover
  sections hold only `bt_ff04` …)" is an **undated count**, and it is already false.
  Measured 2026-10-15T18:33Z through this repo's own script and confirmed directly upstream:
  `kotl` and `larl` each now hold `data/<wsg>/rasters/all_ff04/` and an `all_ff04` key in
  their landcover section, and both stage; only `sloc` is still in the no-rasters state.
  This is the same class round 2 reported as finding (i) and fixed in `scripts/README.md`
  by timestamping it ("`kotl`, `larl` and `sloc` at 2026-10-15T17:37Z, two of them an hour
  later as the Columbia run landed") — the script header kept the undated form. The
  argument the comment supports is unaffected: the order deviation is still load-bearing
  because `sloc_all_ff04` is still in that state, and the 18:24Z run showed the *other*
  half of the argument live (`larl` mid-conversion raised, exactly as the build would).
  Remedy is one clause: date the count, or drop the three names and keep "rostered targets
  sit in that state whenever a group's config is converted ahead of its run", which the
  README already says. Mechanically inert — no guard reads it.

Nothing else. No bug, no security issue, no data-loss path.

---

## What would terminate the loop

Both candidate sets are now enumerated mechanically rather than recalled, and both are
closed:

1. **Source-text reads** — 8, found by grep over both changed files, not by recollection.
   Each shown immune by construction (AST, import, anchored-at-both-ends regex, or the
   quote-aware `_code_only`), and **14 mutations run, 14 fired**, including both defects
   earlier rounds measured as defeats (m12, m14/m15). `_code_only` itself measured over all
   three files it is applied to: 0 over-strips, 0 surviving comments, and the only
   structural limitation (per-line quote reset) shown unreachable in both R files by a probe.
2. **Build conditions between the roster and `meta.json`** — 38 rows, read out of
   `01_stage.R` in file order and cross-checked by `grep` for every `stop(`, `stopifnot`,
   `SKIPPED`, `warning(` and `next` in :130–721 plus every implicit raise from a called
   function, and by `grep Sys.getenv` for the four environment variables. Every row is
   mirrored, or declined with the decline named in the header, and **every decline is in
   the direction where the build stages fewer items or stops** — which an exact-in-both-
   directions literal makes loud. No miss.

The remaining duplication (the mirrored roster walk) is #90, and the three static arms over
it are proven to fire. Nothing above its source of truth; nothing found inside round 2's
fixes.
