# Review round 1 — the #59 release-note entry and regenerated landing page

Reviewer: code-check subagent, 2026-09-05. Staged diff: `NEWS.md`, `README.md`,
`index.html`, `data/readme_items.rds`.

Every claim below was measured against the live API
(`https://images.a11s.one/collections/stac-floodplains-bc`), the bucket
(`aws s3api list-objects-v2` on `stac-floodplains-bc`), the pre-publish pins in
`planning/active/baseline_live.json` / `baseline_full.json` /
`baseline_rds_20260904.json`, the producer's `../floodplains/data/*/provenance.json`,
the repo's own scripts, and `git`. Four findings; two of them are factual errors in
the published record.

---

## Findings

### 1. **[bug]** `NEWS.md:47-48` — the #36 pilot did **not** happen "between v1.0.0 and v1.1.0", and this contradicts `NEWS.md:254` in the same file

> `--only` never publishes `collection.json`, so it cannot stamp a version — the same
> path `bulk_co_ff04` took as the #36 pilot **between v1.0.0 and v1.1.0**.

Measured:

- Every #36 commit — `10be896` (21:17:55) through `5c94847` "Archive planning files
  for #36" (21:44:07), all 2026-09-01 PDT — is an **ancestor of tag `v1.0.0`**
  (`git log v1.0.0 | grep '#36'` lists all six).
- `NEWS.md:252-256`, the v1.0.0 entry, says the opposite of this diff:
  *"First versioned release of the catalogue — **20 items** … every one rebuilt …
  and republished together. `bulk_co_ff04` **had been** republished alone as the
  `--only` pilot (#36, 2026-09-02); for the other 19 this release is the first
  publication…"*  So v1.0.0 re-synced bulk with the other 19, i.e. the pilot was
  folded into **v1.0.0**, not v1.1.0.
- The v1.1.0 section (`NEWS.md:148-248`) never mentions the pilot.
- `planning/archive/2026-09-issue-36-release-only/progress.md` records the pilot run
  as *"RELEASE COMPLETE in 30 s, collection unchanged at 20"* — 20 items is the
  v1.0.0-era collection; v1.1.0 has 23.

Two things are wrong, and the second is the one that costs the reader:

1. The window is wrong (before v1.0.0, not between the two tags).
2. **At pilot time the collection carried no version at all** — v1.0.0 is "the first
   state the live catalogue can name". So the precedent being invoked here (an item
   published ahead of a *stamped* collection version, and later folded in) did not
   exist in that form. This entry's situation is the first time it has happened.

The sentence is load-bearing: it is the reassurance offered for shipping four items
ahead of the served version. A reader who follows the pointer lands on v1.0.0's own
entry and finds it saying something else.

Note for the author: the same wrong claim is in `planning/active/findings.md`
("folded into v1.1.0's notes") and `planning/active/task_plan.md:18`. Three
statements, one ancestor — they corroborate nothing. `NEWS.md:254` is the artifact
and it disagrees with all three.

Suggested correction: the pilot ran **before v1.0.0**, when the collection was
unversioned, and was folded into v1.0.0's full republish; this is the first time an
item has been published ahead of a *stamped* version.

---

### 2. **[bug]** `NEWS.md:33-38` — "Nothing else about them changed" is false: `floodplain_landcover.gpkg` moved on all four and is never mentioned in the entry

> Each item goes from **10 assets to 14** — `classified_2018`, `_2019`, `_2021` and
> `_2022` are new. **Nothing else about them changed**, and that is measured rather
> than assumed: … the `floodplain`, `transition_vector` and three `style_*` assets
> are unchanged on both checksum and size.

The enumerated evidence is exactly right — I re-verified all of it (see the clean
list below). What it does **not** cover is `floodplain_landcover.gpkg`, which is the
largest asset in the bundle and which changed on every one of the four.

Measured, `baseline_live.json` (pre-publish) vs the live API:

| item | `floodplain_landcover.gpkg` before | after | delta |
|---|---:|---:|---:|
| `bulk_co_ff04` | 41,672,704 | 52,961,280 | +10.8 MB (+27%) |
| `necr_ch_ff04` | 30,801,920 | 49,565,696 | +17.9 MB (+61%) |
| `lnth_ch_ff04` | 11,362,304 | 23,314,432 | +11.4 MB (+105%) |
| `kotl_bt_ff04` | 21,311,488 | 42,549,248 | +20.3 MB (+100%) |

`file:checksum` moved on all four.

And unlike the COGs, this is **not** a metadata stamp — the content genuinely
changed. `sf::st_layers()` on the rebuilt local copy still on disk
(`data/stac/kotl_bt_ff04/floodplain_landcover.gpkg`):

```
classified_bt_ff04_2017 / _2018 / _2019 / _2020 / _2021 / _2022 / _2023   (7 layers)
transition_bt_ff04_2017_2023                                              4929 features
layer_styles                                                              8 rows
```

Seven dissolved classified-year layers where a published copy has three. So a
consumer holding `floodplain_landcover.gpkg` for one of the four is missing four
vector layers and roughly half the file, and this release note tells them nothing.

Why it slips through: of the ten pre-existing assets, five are named as unchanged
(correctly), three classified COGs are implied by "goes from 10 assets to 14", and
`transition_2017_2023` gets its own bullet explaining why its bytes moved while its
pixels did not. `floodplain_landcover.gpkg` is the only asset that both moved and is
never named — and it is the one whose movement is real rather than incidental.

This is the same shape as the v1.1.0 finding the entry itself cites: a sentence that
sends a consumer to the wrong signal. Here it sends them to no signal at all.

---

### 3. **[fragile]** `NEWS.md:50` — "the item's own `nge:produced_datetime` is the honest per-item answer" fails on 2 of 23 items and answers a different question than the one asked

> Until then a consumer reading `1.1.0` off the API is holding a version string that
> predates four items' current contents; the item's own `nge:produced_datetime` is
> the honest per-item answer.

Two gaps, both measured:

- **It is absent on two items.** `mcgr_ch_ff04` and `pine_bt_ff04` serve no
  `nge:produced_datetime` at all on the live API (published null, omitted on output —
  the behaviour `CLAUDE.md` documents). A consumer following this advice on either of
  the two `deprecated: true` items gets nothing back. The entry names those two items
  three paragraphs later, so the exception is in scope.
- **It is a proxy for the property.** `scripts/fp_provenance.R:40-43` says what it
  is: *"`produced_datetime` is the LANDCOVER step's run timestamp"*. It is upstream's
  produce time, not this repo's publish time, and it does not move when this repo
  republishes an item that upstream did not re-run — which is precisely what the #36
  pilot did and what v1.1.0's RAT/COG re-encode did to items with unchanged geometry.
  So it separates *"upstream re-ran"* from *"upstream did not"*, which happens to
  coincide with *"my copy is stale"* for these four and does not in general.

Correct for the four items in front of it; over-stated as the general per-item answer
to a versioning question. Narrowing it ("for these four, `produced_datetime` moved to
2026-09-05 and is the per-item marker") would be exact.

---

### 4. **[fragile]** `NEWS.md:66-68` — the mechanism credited for `transition_vector.gpkg`'s stability does not cover the last write to that file

> **`transition_vector.gpkg` is byte-identical**, and it carries no provenance tags
> and is written with `OGR_CURRENT_DATE` pinned, so byte equality there *is* content
> equality of the transition layer.

The **result is verified** — byte-identical checksum and size on all four (see clean
list). Two problems with the reasoning a future reader will lean on:

- "byte equality *is* content equality" is trivially true of any file; it needs no
  support. The two clauses offered ("no provenance tags", "`OGR_CURRENT_DATE`
  pinned") support the *converse* — that a content change could not have hidden
  behind a nuisance byte change. Harmless, but the sentence reads as though the
  inference depends on them.
- More materially, **`OGR_CURRENT_DATE` is not the whole mechanism.** `01_stage.R`
  writes the file under that pin (`scripts/fp_gpkg.R:37`), but `04_gpkg_style.py`
  then modifies it, writing `layer_styles` through `sqlite3` — the local copy carries
  8 style rows. `CLAUDE.md` states this explicitly: *"a `sqlite3` write never passes
  through GDAL, so `OGR_CURRENT_DATE` does not reach it"*, which is why
  `style_determinism-check.py` exists as a separate churn guard alongside
  `gpkg_determinism-check.R`. Crediting the byte-stability of the *published* file to
  the OGR pin alone names a mechanism that does not govern its final write.

Not a wrong number; a wrong causal account in the paragraph that exists to tell a
consumer which signal to trust.

---

## Verified clean — measured, not reasoned

Everything below was re-derived from the artifacts and matches the entry **exactly**.

**Asset and item counts** (live API, 23 items)
- Four items serve 7 `classified_<year>` assets (2017–2023 inclusive) and 14 assets
  total; the other **nineteen** serve 3 and 10. 4 + 19 = 23. ✓
- New keys are exactly `classified_2018`, `_2019`, `_2021`, `_2022` on each of the
  four; nothing removed. ✓

**"Exactly four properties move"** — diffing `baseline_live.json` against live, the
moved `nge:` keys on each of the four are exactly
`landcover_key`, `landcover_item_hash`, `drift_version`, `produced_datetime`. ✓
`nge:drift_version` is `0.13.0` on all four; installed `drift` is 0.13.0 and exports
`dft_rast_break_class()`. ✓

**"The other nineteen items did not move at all"** — all 19 identical in asset key
set, every `file:checksum`, every `file:size` and every `nge:` property. 0 of 19
moved. ✓

**Unchanged assets on the four** — `floodplain`, `transition_vector`,
`style_classified`, `style_floodplain`, `style_transition`, on both checksum and
size, for all four. ✓ (`transition_vector.gpkg` byte-identical: the load-bearing
claim in finding 4 — the result holds.)

**Modelled figures** — `floodplain_ff02/04/06_km2`, `gross_loss_ha`,
`gross_gain_ha`, `net_ha`, `flood_factor`, `scenario`, `region`, `species`: identical
across **all 23** items vs `baseline_rds_20260904.json`. ✓ Temporal window still
`2017-01-01` → `2023-12-31` on all four. ✓

**Bucket** — 270 objects total; **210 outside the four**, ETag-for-ETag identical to
`baseline_full.json`, none added, none removed. ✓ `collection.json` last modified
2026-09-03, ETag unchanged — never written. ✓ The four carry 15 objects each
(14 assets + item JSON). ✓

**Collection version** — API serves `version: 1.1.0`, `license: CC-BY-4.0`. ✓
`catalogue_release.sh:325-331` reads the live version and skips the stamp under
`--only`; `:400-401` skips `--expect-provenance`. ✓ `PROVENANCE_FLOOR=21` at
`catalogue_release.sh:60`, and 21 of 23 items serve non-null `nge:` values. ✓

**`nge:landcover_key` — the load-bearing check, reproduced independently.** I
reimplemented the fold in Python (`sha256:` + sha256 of `\n`-joined `<year>=<digest>`,
years ascending) per `fp_provenance.R:94-129`, against today's
`../floodplains/data/<wsg>/provenance.json`:

| item | fold(7 years) vs live | fold(2017,2020,2023) vs pre-publish baseline |
|---|---|---|
| `bulk_co_ff04` | MATCH | MATCH (`sha256:66104a0f…`) |
| `necr_ch_ff04` | MATCH | MATCH (`sha256:23678392…`) |
| `lnth_ch_ff04` | MATCH | MATCH (`sha256:a737bbdc…`) |
| `kotl_bt_ff04` | MATCH | MATCH (`sha256:a6f3a5f6…`) |

Both arms exact on all four. This is **not** circular: the reference is the
pre-re-run published value pinned before anything was written, and the recomputation
came from an independent implementation over the producer's file. The claim is sound
and the entry is right to call it the load-bearing one. `CLAUDE.md`'s description of
`nge:landcover_key` is consistent with it and needs no change.

**`02_raster_tag.py` stamps every COG** — the loop at `02_raster_tag.py:267-277`
walks `(RAW_DIR/wsg).glob("*.tif")` and applies `shared_tags + provenance_tags` to
every raster before the per-asset `YEAR` / `YEAR_FROM`/`YEAR_TO` branch, so the
transition raster carries the provenance block too. All four moved properties are in
`PROV_FIELDS`. ✓ Confirmed on the wire: published transition COGs carry 25 tags
including `NGE_*`.

**The 30 stray tags** — read over `/vsicurl/` from the published hrefs:

| item | `classified_*.tif` | `transition_2017_2023.tif` |
|---|---|---|
| `bulk_co_ff04` | 24 tags, 0 stray | 25 tags, 0 stray |
| `lnth_ch_ff04` | 24 tags, 0 stray | 25 tags, 0 stray |
| `necr_ch_ff04` | 54 tags, **30 stray** | 25 tags, 0 stray |
| `kotl_bt_ff04` | 54 tags, **30 stray** | 25 tags, 0 stray |

Exactly 30, exactly on `necr` and `kotl`, exactly on the classified rasters and not
the transition raster — and `data#type = 'float64'` / `data#_FillValue = 'nan'` on
rasters whose header reads `uint8` / nodata `255.0`. Every clause of that bullet is
exact. ✓

**Upstream references** — `floodplains#79` CLOSED 2026-09-05, titled *"…rerun step 3
with every year"*; `floodplains#76` OPEN; `floodplains#83` OPEN, titled *"classified_*.tif
carry 30 stray gdalcubes/NetCDF tags on 2 of 4 #79 areas, two of them wrong"*;
`drift#62` OPEN. `pine_bt_ff04` and `mcgr_ch_ff04` serve `deprecated: true`. ✓

**Repo boundary** — the entry explicitly declines to restate drift's measurement
("The measurement that motivated it belongs to `drift` and is not restated here").
No upstream number is restated. The BULK ~20% figure that appears in
`planning/active/task_plan.md` correctly did **not** make it into `NEWS.md`. ✓

**Generated files** — `README.md` changes only its generation date (2026-09-04 →
2026-09-05), and its coverage table is still correct because every modelled figure is
unchanged. `README.md:44` already states the two-population rule, so it does not
contradict the new entry. `index.html` is 2 lines changed and does carry the new
links (`bulk_co_ff04/classified_2018.tif` … `_2022.tif` present in the staged copy,
absent at HEAD) — the widget-id / seed pinning from #53 is holding. `data/readme_items.rds`
is the tracked render cache and belongs in this commit. Both are appropriate here. ✓

---

## One process note (not a finding)

The commit does the work of `task_plan.md` Phase 6 (the NEWS entry, the regenerated
`README.md` and `index.html`) but stages neither the Phase 6 checkbox flips nor a
`progress.md` entry. `planning/active/` is tracked, so the repo's atomic-commit rule
("each commit bundles code change + checkbox flip") applies; as staged,
`task_plan.md` records the NEWS entry as not yet written.

Also worth a glance while editing: `CLAUDE.md`'s collection-model section still says
`floodplains#79` *"is re-running areas onto an annual span"* in the present tense.
It closed 2026-09-05. Outside this diff, so not a finding.
