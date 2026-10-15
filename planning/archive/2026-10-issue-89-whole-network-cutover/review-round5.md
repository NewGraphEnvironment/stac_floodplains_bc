# Code-check round 5 — verification pass on `0aa9c92` (#89)

Scope as briefed: (1) independently re-derive every number `0aa9c92` touched, stating scope and
units; (2) confirm or refute the two rewritten `test_pipeline.R` comments; (3) a final
behavioural confirmation over the branch diff, weighted to `catalogue_release.sh` step 6/7;
(4) the termination verdict.

**Measured 2026-10-15, working tree clean at `0aa9c92`.** Nothing was taken from the commit
message, from `review-round4.md`, or from any earlier round. Sizes are `os.path.getsize()` over
Python `glob` output (never `ls`, which is aliased `--color` here and injects ANSI bytes into
captured paths); layer counts are `sqlite3` over `gpkg_contents` with `ogrinfo` as an
independent cross-check; byte counts are `wc -c` and the release script's own
`awk '/^## /{n++} n==1'` slice; raster counts are `rasterio` under `uv run`.

**The roster was derived independently of the build**, not from `data/stac/*`: the four
`floodplains/config/regions/*.yml` files name COLUMBIA 4 + FRASER 13 + PEACE 3 + SKEENA 3 = **23**
groups, and `skeena.yml` carries `# NEEXDZII (subset of BULK) intentionally excluded` in the
`watershed_groups:` line itself. `$FLOODPLAINS_DATA` holds 25 group directories plus `logs/`;
the two off-roster ones are `lit` and `neexdzii`. So the scope word in the prose is checkable
from upstream config, not only from what happened to stage.

---

## Verification table

| # | claim, as it now stands in the tree | site | measured | scope / units measured at | verdict |
|---|---|---|---|---|---|
| 1 | upstream two bundles 1680.4 MB | CLAUDE.md:153, scripts/README.md:66 | 1,680,412,672 B = 1680.4 MB | `../floodplains/data/<wsg>/{floodplain_landcover,floodplain}.gpkg`, 23 rostered, /1e6 | agree |
| 2 | staged two bundles 1085.6 MB | same | 1,085,607,936 B = 1085.6 MB | `data/stac/<wsg>_all_ff04/` same two files, same 23, /1e6 | agree |
| 3 | saving 594.8 MB | same | 594,804,736 B = 594.8 MB | row 1 − row 2 | agree |
| 4 | `transition_vector.gpkg` a further 93.6 MB | CLAUDE.md:154, README.md:67 | 93,618,176 B = 93.6 MB | staged, 23 items, /1e6 | agree |
| 5 | MORR 116.3 -> 35.6 MB, −69% | CLAUDE.md:154 | 116,326,400 -> 35,622,912 B = 116.3 -> 35.6 MB, **−69.4%** | MORR two bundles both sides, /1e6 | agree |
| 6 | #80's historical pair is **decimal MB**, 826.9 -> 642.9 | CLAUDE.md:157, README.md:69 | archive `progress.md:109` reads `826.9 -> 642.9 MB … MORR -70% (116.3 -> 35.4)`; `:144` reads `two bundles on disk 642.9 MB`; `:252` reads `23 staged … 23/23 at 642.9 MB` | the archive, plus MORR's still-unrewritten upstream bundles at 116,326,400 B = 116.3 **MB** decimal (110.9 MiB), which is the number #80 wrote | agree — MB is right, MiB was the error |
| 7 | re-read cost 1338.3 MB | README.md:61 | 1,338,267,559 B over 246 asset files = 1338.3 MB | every `assets[*].href` of all 23 items resolved to its staged file, /1e6 | agree |
| 8 | …= three bundles 1179.2 + COGs 154.6 + QML 4.5 | README.md:63 | 1,179,226,112 (69 .gpkg) + 154,566,567 (108 .tif) + 4,474,880 (69 .qml) = 1179.2 + 154.6 + 4.5 = **1338.3** | same 246 files, partitioned by extension | agree, and the three parts sum to the total |
| 9 | `attributes` layers: 66 in the landcover bundle | CLAUDE.md:175, 01_stage.R:530 | **66** | `gpkg_contents.data_type='attributes'`, upstream `floodplain_landcover.gpkg`, 23 rostered | agree |
| 10 | …0 in `floodplain.gpkg` | same | **0** | same scope | agree |
| 11 | …23 in `aquatic_network.gpkg` | same | **23** (1 per group) | same scope | agree |
| 12 | an all-directories glob gives 68 | 01_stage.R:531 | **68** over the 24 directories carrying the bundle; the extra 2 are `neexdzii`'s `composition_co_ff04_2017_2023` + `patch_watercourse_co_ff04_2017_2023`; `lit` carries no bundle | every dir in `$FLOODPLAINS_DATA` less `logs/` | agree, and the +2 is located |
| 13 | item JSON 5.6–18.2 MB each | catalogue_release.sh:525, item_create.py:726, item_register.sh:37 | min `sloc_all_ff04.json` 5,619,746 B = 5.62 MB; max `fran_all_ff04.json` 18,245,948 B = **18.25 MB** | `data/stac/*.json` less `collection.json`, /1e6 | agree (18.2 is the correct one-decimal truncation; 18.3 was the slip) |
| 14 | 252.6 MB total | item_register.sh:37 | 252,620,392 B = 252.6 MB | same 23 files | agree |
| 15 | NEWS.md 47,156 B | catalogue_release.sh:687, :728, catalogue_release-check.sh:1064 | **47,156 B** by `wc -c` and by `git show HEAD:NEWS.md` | whole file | agree, all **three** copies now carry it |
| 16 | top section 36,129 B | catalogue_release.sh:729 | **36,129 B** by the script's own `news=$(…); printf '%s\n' "$news" \| awk '/^## /{n++} n==1' \| wc -c` | top `## ` section only | agree |
| 17 | margin 1.8x against 64 KiB | catalogue_release.sh:729 | 65536/36129 = **1.814** | 64 KiB = 65,536 B | agree |
| 18 | whole-file margin 1.39x | catalogue_release.sh:688 | 65536/47156 = **1.390** | — | agree |
| 19 | **"it was 2.2x before this release's own entry"** | catalogue_release.sh:730 | main's top section is **32,989 B → 1.987x**; 2.2x was the state at 29,165 B, two steps back | same awk slice, run against `git show main:NEWS.md` | **disagree — Finding 1** |
| 20 | 4 COGs on 19 items, 8 on 4 | item_validate.py:1327 | `{4: 19, 8: 4}` | `.tif` assets per item JSON | agree |
| 21 | 10 assets on 19, 14 on 4 | test_pipeline.R:327-328 | `{10: 19, 14: 4}`; the four 14s are bulk, kotl, lnth, necr | `len(assets)` per item JSON | agree |
| 22 | "all 23 items" reported unmarked-and-not-rebuilt | item_validate.py:2072 | 23 items built, `deprecated` absent on **all 23**, `flooded` = `0.7.0` on all 23 | item properties | agree |

### Also re-derived (same candidate set, not in the briefed list; all agree)

| claim | site | measured |
|---|---|---|
| 22 of 23 groups carry a layer naming no target; only DUNC clean | CLAUDE.md:145-147 | 22 dirty, **dunc** the single clean group |
| all 23 items carry both a `patch_watercourse` and a `composition` | CLAUDE.md:159-161 | exactly (1, 1) on all 23 staged landcover bundles |
| four layers per published `floodplain.gpkg`, all 23 carry `_by_blue_line_key` | style_qml-write.py:21-22, 01_stage.R:558 | `{4: 23}`, and exactly one `_by_blue_line_key` in each |
| MORR's upstream `floodplain.gpkg` has 13 layers | style_qml-write.py:23 | **13** |
| `kisp .../all_ff04/classified_2020.tif` holds 58,540 zeros among 3,555,686 valid | 01_stage.R:104-106, item_validate.py:997 | **58,540 / 3,555,686**, nodata 255 |
| …and the species raster for the same group and year holds none | 01_stage.R:106 | `kisp/rasters/ch_ff04/classified_2020.tif`: 2,061,340 valid, **0** zeros |
| "the 81, of which KISP reaches 45" | 01_stage.R:117 | 45 distinct transition codes present in `kisp_all_ff04/transition_2017_2023.tif` |
| `EXPECTED_STYLE_CATEGORIES` {10, 91} | item_validate.py:1021 | committed QML: classified **10**, transition **91** |
| "for `transition` 81 of 90 ship off" | item_validate.py:1758 | 91 categories, 82 `render="false"`, of which 1 is the `value="NULL"` catch-all → **81 of 90** |
| `classification:classes` 10 per classified asset, 100 on the transition | derived from `EXPECTED_RAT_ROWS` | 10 and 100 on every asset of `bulk_all_ff04` |
| all 23 rostered groups carry a `provenance.json` with an `all_ff04` landcover section | 01_stage.R:423-425, stage_years-check.R:122 | 0 missing, 0 without the section |
| `sloc_all_ff04` is a real staged item (the moved default) | gpkg_determinism-check.R:32, style_determinism-check.py:60 | present, and the smallest item JSON |

### Re-validation run in this round

| command | result |
|---|---|
| `uv run python scripts/style_drift-check.py` | exit 0 — 3 styles byte-identical, 10 classes |
| `uv run python scripts/attribution_drift-check.py` | exit 0 — citation 770 chars, id and licence agree |
| `uv run python scripts/prov_fields-check.py` | exit 0 — **49 assertions, 0 failed** |
| `bash -n` on `catalogue_release.sh`, `catalogue_release-check.sh`, `item_register.sh`, `item_unregister.sh` | clean |

---

## Part 2 — the two rewritten `test_pipeline.R` comments

**Both are now TRUE.** Confirmed by reading the code, not by reasoning from the comment.

The count guard at `scripts/test_pipeline.R:305-308`:

```r
n_expected <- 7L + length(unlist(meta$years))
if (length(item_assets) != n_expected) { stop(...) }
```

`item_assets <- jsonlite::read_json(item_json)$assets` is the JSON object's key set. The
published keys are, measured on `bulk_all_ff04` (a 7-year item, 14 assets):

```
classified_2017 … classified_2023, transition_2017_2023,
floodplain_landcover, floodplain, transition_vector,
style_floodplain -> floodplain.qml, style_classified -> classified.qml, style_transition -> transition.qml
```

* **Style comment (lines 311-315).** `floodplain.qml`'s stem is `floodplain`, which is already
  the gpkg's asset key. Keying the style by its stem writes into an existing dict key, so the
  object holds one fewer member — 13 where `n_expected` is 14, 9 where it is 10 — and the
  count check **does** fire. The comment now says exactly that, and that what it cannot say is
  *which* key went. True. (`classified.qml` and `transition.qml` collide with nothing, since the
  data keys are `classified_<year>` and `transition_<y1>_<y2>`; the comment names only
  `floodplain` and `transition_vector`, which is correct.)
* **transition_vector comment (lines 325-330).** Same mechanism: the gpkg's old proposed
  filename stem is `transition_2017_2023`, already the COG key, so a stem key overwrites the
  raster and the item holds 9 or 13 against the 10 or 14 of a three-year or annual-span item.
  Measured distribution is exactly `{10: 19, 14: 4}`, so both pairs the comment quotes are
  right. True.

Round 4's refutation of the previous wording is confirmed, and the replacement wording is
confirmed independently.

---

## Part 3 — behavioural confirmation

No behavioural defect found. Detail on the parts that perform the irreversible delete:

**Step 6, the unregister call (`catalogue_release.sh:1198-1234`).**

* `to_delete=$(comm -12 <(printf '%s\n' "$retired_ids") <(printf '%s\n' "$live_ids") || true)` —
  both sides are sorted compatibly. `retired_ids` is `LC_ALL=C sort -u` (line 107); `live_ids`
  comes from `fetch_live_ids`, which sorts in Python (codepoint). Verified empirically over the
  real 46-id union (23 retired + 23 built): `LC_ALL=C sort`, `LC_ALL=en_US.UTF-8 sort` and
  Python `sorted()` produce **byte-identical** output, so the missing `LC_ALL=C` on `comm`
  cannot reorder this set. (`comm` here is GNU coreutils 9.11 from Homebrew.) The ids are
  structurally aligned — every wsg code is 4 chars and no code is a prefix of another — which is
  why underscore-ignoring collation cannot reach them.
* `… bash scripts/item_unregister.sh $to_delete || { … exit 1; }` — the `||` binds to the simple
  command including its `VAR=val` prefixes, which is what is wanted. Under `set -euo pipefail`
  this is the correct shape: a bare call would have let `set -e` kill the script before step 7,
  which is the only evidence the delete happened. The handler's `if post_ids=$(fetch_live_ids);`
  is safe as an `if` condition (a failing pipeline selects the `else`), both `comm`s inside it
  carry `|| true`, `$to_delete` is in scope (shell variables are global, and the whole block is
  gated on `n_retired > 0`), and the fall-back branch prints the full list. The handler ends in
  `exit 1`, so no path falls through to step 7 after a failed delete.
* The one cosmetic edge: with `$gone` empty, `echo "already unregistered:$(printf ' %s' $gone)"`
  prints a trailing space rather than nothing. Harmless and not reported as a finding.

**Step 7 (`:1238-1292`).**

* `final_ids=$(fetch_live_ids) || { … exit 1; }` — a failed read-back fails the release rather
  than reporting success.
* The equality arm `[ "$final_ids" != "$local_ids" ]` is unconditional. I checked `git show
  main:` — it was already unconditional before this branch, and the comment explaining why is
  pre-existing (`741f067`, #76). Not a branch change.
* `echo "retired $(printf '%s\n' "$to_delete" | grep -c . || true) item(s) this run"` — correct
  against the `grep -c` trap: `|| true` sits inside the substitution and after a command that
  already printed `0`, so an empty `$to_delete` yields the single line `0`, not `0\n0`. Verified
  against the convention's stated failure (`|| echo 0`), which this does not use.
* Ordering is right: `[ "$fail" -eq 0 ] || { echo "RELEASE INCOMPLETE"; exit 1; }` at `:1179`
  sits **above** the retire block, so every step-5 probe runs before anything is deleted.

**Rest of the branch diff.** The behavioural changes are: `classes` keeping code 0 (with the
`setequal` floor widened to the 10 codes, so a short table still aborts); `DEPRECATED_ITEMS` /
`EXPECTED_DEPRECATED` emptied, with both consuming arms being set differences and therefore
vacuous, plus a new `elif EXPECTED_DEPRECATED:` / `else:` that prints a true statement in both
states; `PROVENANCE_FLOOR` 21 → 23 and `PROV_CENSUS` → 18/23×11; `EXPECTED_RAT_ROWS` {10, 100}
and `EXPECTED_STYLE_CATEGORIES` {10, 91}; the `prov_fields-check.py` fixture widened to 18 + 5 + 2
= 25 items / 23 traced, which is arithmetically consistent with the census literal it asserts
(`link_run_uid` 18 = the full population; the other eleven 23 = full + partial); and the two
determinism-check defaults moved to `sloc_all_ff04`, which exists. `RETIRED_ITEMS` is the only
other substantive change and is settled ground.

---

## Findings

### 1. [fragile] `scripts/catalogue_release.sh:730` — "it was 2.2x before this release's own entry" is 2.0x

```
      # buffer — measured at 64 KiB on this machine. NEWS.md is 47,156 B on the v2.0.0
      # commit and its top section 36,129 B, so this is not reachable yet; it is 1.8x of
      # margin on a file that only grows — it was 2.2x before this release's own entry — and
```

Measured with the script's own slice:

```
main (the state immediately before this release's entry):  32,989 B  ->  65536/32989 = 1.987x
HEAD (v2.0.0):                                             36,129 B  ->  65536/36129 = 1.814x
```

So this release's entry took the margin from **2.0x to 1.8x**, not from 2.2x. 2.2x was true of
the state the *previous* version of this comment recorded — `NEWS.md is 39,573 B today and its
top section 29,165 B` (65536/29165 = 2.247) — which was itself already partway into this
release's `## Unreleased` section, so it matches no reading of "before this release's own
entry". The comparator was carried forward while the two figures beside it on the same line
were re-measured; `0aa9c92` edited `36,128 -> 36,129` one line above and left it.

Same mechanism as rounds 2–4: a measured quantity in prose re-anchored to a different state
than the one its sentence names. No behavioural effect — the conclusion (the here-string is
nowhere near the 64 KiB pipe buffer) is unaffected and is independently true at 1.814x.

Fix: `it was 2.0x before this release's own entry`.

---

## Termination verdict

**Not strictly met, by one number — and nothing behavioural remains.**

* **Every number `0aa9c92` touched is correct** when derived independently, by a different
  expression than the one that produced it and at a scope stated in words: all 22 briefed
  claims verify, and the three parts of the re-read (1179.2 + 154.6 + 4.5) sum exactly to the
  stated 1338.3 MB, which is a self-check the earlier wrong-scope versions could not have
  passed. The scope word itself is now checkable from `floodplains/config/regions/*.yml`
  rather than from the build, which is what closes the 68-vs-66 class.
* **Both rewritten `test_pipeline.R` comments are true**, confirmed from the code and from the
  real asset key sets, not from the commit message.
* **No behavioural defect**, including in the step 6/7 delete path, whose sort compatibility I
  confirmed empirically over the actual 46-id union rather than by argument.
* **One number in the wider candidate set is still wrong** (Finding 1): a 2.2x comparator that
  is 2.0x. It is the fourth instance of the same mechanism, but it is a *carried-forward*
  comparator rather than a freshly committed wrong measurement, it is the only one left after a
  sweep of every margin, byte count, MB figure, layer count and item count in the changed files,
  and it cannot affect the release.

Round 6 is not warranted as a re-read: fix Finding 1 in place and the candidate set is clean.
The standing remedy is the mechanical quantities check filed as #93 — four rounds have now each
found exactly one prose quantity that no code can contradict.
