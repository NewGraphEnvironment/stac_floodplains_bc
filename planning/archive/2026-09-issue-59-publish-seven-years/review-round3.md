# Code-check round 3 — #59 release record

Scope: the staged diff (`NEWS.md`, `README.md`, `planning/active/*`). `index.html`,
`data/readme_items.rds` and the round-1/2 review files read for context only.

Everything below was re-derived from the artifacts: the live API
(`https://images.a11s.one/collections/stac-floodplains-bc`), `aws s3api list-objects-v2` on
`s3://stac-floodplains-bc`, `/vsicurl/` reads of the published COGs, the producer's
`../floodplains/data/*/provenance.json`, and `planning/active/baseline_*.json`.

---

## Mechanism

**Every one of the ten prior findings, and the two below, is a sentence that quantifies or
bounds a population the writer had already measured item-by-item — composed from the mental
summary of that measurement rather than re-derived from it. The measurements themselves have
been correct in all three rounds. The defect is always one altitude up, in the quantifier.**

The two candidate shapes offered are both real, and they are the same mechanism seen from two
sides:

- **(a) the summary outran the table** — this is the mechanism applied to *this* release's own
  population (four items, fourteen assets, twenty-three items, 270 bucket objects). The
  evidence sits one line below the sentence, and the sentence was not checked against it.
  Instances: "roughly doubles"; "nothing else changed" (twice); "each rebuilt COG was
  compared"; "the catalogue offers no field that says so"; and **Finding 1 below**.
- **(b) the claim was inherited** — this is the same mechanism applied to a *neighbouring*
  population (v1.0.0, v1.1.0, floodplains#79), where the thing being summarised is another
  document's headline rather than an artifact. Instances: the wrong version-history claim that
  reached three documents from one ancestor; the wrongly-credited byte-identity mechanism; and
  **Finding 2 below**.

So neither shape is rejected; (a) and (b) are one habit with two sources of the summary. The
discriminating tell, present in all twelve, is a **universal or range word applied to a set** —
`every`, `each`, `nothing else`, `no field`, `all four`, `roughly doubles`, `between X and Y`,
`without moving it` — where the per-member evidence exists but was not walked. `code-check.md`
names both halves: *"Documents that share an ancestor corroborate nothing"* for (b), and
*"Derive every number in a release note from the artifact it describes"* / *"Write the numbers
last, against the final tree"* for (a).

Two secondary observations that the enumeration below supports:

- The mechanism **cannot be closed by another review round**, because the sentences are
  individually plausible and reading them does not disprove them. It closes by walking the
  quantifiers, which is what the table below does.
- The direction of error is not random: **eleven of twelve understate or over-tidy.** A
  summary written from memory rounds toward the clean claim ("nothing else", "a double",
  "without moving it"), never toward the messy one. That asymmetry is what makes the summary
  layer worth a mechanical pass rather than a careful read.

### Every place the mechanism reaches in this diff — enumerated, with a verdict

All 41 quantified/bounded/inherited claims in the new `NEWS.md` text and the one changed
`README.md` line. Verdicts are measurements, not readings.

| # | claim | verdict |
|---|---|---|
| 1 | four areas publish every year 2017–2023 | ✅ 7 contiguous `classified_<y>` on all four |
| 2 | the other nineteen still serve three | ✅ 19 × 3 |
| 3 | each item 10 assets → 14 | ✅ baseline 10 (incl. `bulk` in `baseline_live.json`), live 14 |
| 4 | `_2018/_2019/_2021/_2022` are new | ✅ exactly those four keys added |
| 5 | **gpkg "grows by between a quarter and a double"** | ❌ **FINDING 1** — measured +27.1 / +60.9 / +99.7 / **+105.2 %** |
| 6 | gpkg is the largest file in the bundle | ✅ 53.0 MB vs next-largest 8.6 MB |
| 7 | spread not proportional to layer count | ✅ 3→7 on all four, spread 27–105 % |
| 8 | the four table rows | ✅ 41 672 704→52 961 280; 30 801 920→49 565 696; 11 362 304→23 314 432; 21 311 488→42 549 248 |
| 9 | no modelled value changed (extents, tree-change, window, bbox, geometry) | ✅ only 4 properties differ; bbox identical |
| 10 | `floodplain`, `transition_vector`, three `style_*` unchanged on checksum **and** size | ✅ all five identical on both |
| 11 | every COG's bytes moved | ✅ all pre-existing COGs' `file:checksum` moved |
| 12 | exactly four properties move (`landcover_key`, `landcover_item_hash`, `drift_version`, `produced_datetime`) | ✅ exactly those, on `necr`/`lnth`/`kotl` (`bulk`'s pre-publish properties are not in either baseline — see note) |
| 13 | the other nineteen did not move at all | ✅ 0 property, asset-checksum or bbox differences across 19 |
| 14 | 210 bucket objects outside the four, unchanged ETags, none added, none removed | ✅ 210 = 210, 0 changed, 0 added, 0 removed |
| 15 | `collection.json` never written | ✅ ETag unchanged, `LastModified 2026-09-04T06:17Z` (the v1.1.0 sync) |
| 16 | served collection version still `1.1.0` | ✅ |
| 17 | #36 pilot folded into **v1.0.0** | ✅ v1.0.0's entry names the pilot (round-1 fix holds) |
| 18 | pilot ran before v1.0.0, no version at all then | ✅ |
| 19 | first time published items moved ahead of a *stamped* version | ✅ consistent with the tag/publish record |
| 20 | the four read `19:14Z … 19:52Z`, every other item `2026-09-03T20:16Z` or earlier | ✅ 19:14:08–19:52:01; max of the rest is `unth` 20:16:31 |
| 21 | it is the landcover step's upstream run time, not a publish time | ✅ `fp_provenance.R:67` → `landcover.<scen>.run.datetime_utc` |
| 22 | **"(the v1.1.0 re-encode moved every asset's bytes without moving it)"** | ❌ **FINDING 2** |
| 23 | the two `deprecated: true` items serve no `nge:` properties whatsoever | ✅ both serve zero `nge:` keys |
| 24 | folding only 2017/2020/2023 reproduces the pre-run key, exactly, for all four | ✅ reproduced independently for `necr`/`lnth`/`kotl`; `bulk`'s prior key rests on `findings.md`'s plan-time 4-of-4 check (not recoverable from either committed baseline) |
| 25 | seven-year fold matches what is live | ✅ reproduced for all four |
| 26 | `landcover_item_hash` moved (7 ids where there were 3) | ✅ moved |
| 27 | transition COG checksum moved on every item | ✅ |
| 28 | `02_raster_tag.py` stamps provenance into *every* COG's tags | ✅ `PROV_FIELDS` applied per raster, not per kind |
| 29 | `transition_vector.gpkg` byte-identical on all four | ✅ checksum and size both identical |
| 30 | both writers pin timestamps (`OGR_CURRENT_DATE`, `GPKG_EPOCH`) | ✅ `fp_gpkg.R:37`, `04_gpkg_style.py:89` |
| 31 | `gross_loss_ha`/`gross_gain_ha`/`net_ha` unchanged | ✅ |
| 32 | the four pre-existing COGs compared against S3's bytes **before** publishing | ✅ consistent with `progress.md` (round-2 fix holds) |
| 33 | **the four new years "each" read back Byte / nodata 255 / 9-row RAT** | ⚠️ **FINDING 3** — the property is TRUE (I read all 16: `uint8`, nodata 255, 9-row RAT) but the three documents in this commit record three different populations |
| 34 | `necr` and `kotl` ship 30 stray tags per classified COG | ✅ exactly 30 on both, on `_2017` and `_2018` |
| 35 | absent from `bulk`, `lnth`, and every transition raster | ✅ 0 on `bulk`/`lnth`; `necr`/`kotl` transitions carry none |
| 36 | `data#type = 'float64'`, `data#_FillValue = 'nan'` over `uint8`/255 | ✅ verbatim |
| 37 | `PROVENANCE_FLOOR` unchanged at 21; `--only` skips `--expect-provenance` | ✅ `catalogue_release.sh:60`, `:397–408` |
| 38 | floodplains#79 re-ran **step 3 only**; geometry and sub-basins untouched | ✅ all four: `network`/`floodplain` stamps 09-02/09-03, `landcover` alone 09-05 |
| 39 | PINE and MCGR remain `deprecated: true` | ✅ |
| 40 | the 9-row class-label RAT | ✅ `classes.json` 9 classes; RAT 9 rows on all 16 new COGs |
| 41 | README: 23 items / 22 groups / 4 regions / version 1.1.0 / 2026-09-05 | ✅ |

**38 of 41 verified, 2 false, 1 inconsistent.** That is the enumeration; the set is closed.

---

## Findings

- **[bug] NEWS.md:41 — "`floodplain_landcover.gpkg` grows by between a quarter and a double"
  is contradicted by its own table, for the third round running.**

  Measured against the live API's `file:size` and the pre-publish sizes in
  `planning/active/baseline_full.json` / `baseline_live.json`:

  | item | before | after | growth |
  |---|---:|---:|---:|
  | `bulk_co_ff04` | 41 672 704 | 52 961 280 | **+27.1 %** |
  | `necr_ch_ff04` | 30 801 920 | 49 565 696 | **+60.9 %** |
  | `kotl_bt_ff04` | 21 311 488 | 42 549 248 | **+99.7 %** |
  | `lnth_ch_ff04` | 11 362 304 | 23 314 432 | **+105.2 %** |

  A "double" is +100 %. `lnth` is +105 %, and the table three lines below the sentence *says*
  `+105%`. So the stated upper bound is beaten by the row that is already printed under it —
  the identical defect round 1 fixed ("nothing else changed"), round 2 fixed ("roughly
  doubles"), and this wording reintroduces at a 5-point margin instead of a 100-point one.

  It is not cosmetic in context: the sentence's next clause is *"so plan the download"*, which
  makes the upper bound the number a consumer sizes against.

  Fix by removing the quantifier rather than re-estimating it — `grows by 27 % to 105 %`, or
  `between a quarter and slightly over a double`. The range is already in the table; the
  summary does not need to restate it approximately.

- **[bug] NEWS.md:70–71 — "(the v1.1.0 re-encode moved every asset's bytes without moving it)"
  is false. `nge:produced_datetime` moved at v1.1.0, on every item that carries it.**

  The parenthetical is the *only* evidence offered for the sentence it sits in — that
  `produced_datetime` "would not move at all on a republish of an item upstream had not
  re-run". It cites a release in which upstream **did** re-run, so it cannot support the claim,
  and it is wrong on its own terms.

  Measured, three independent ways:

  1. **v1.1.0's own entry says so.** *"Areas cannot be scaled, so the items were rebuilt
     **upstream** on `flooded` >= 0.5.0"* (`NEWS.md:185`). v1.1.0 was an upstream rebuild, not
     only the #33/#34/#35 re-encode. Calling it "the v1.1.0 re-encode" is the inherited
     characterisation; the artifact says otherwise.
  2. **The producer's own files.** Every live `produced_datetime` outside the four forms one
     alphabetical, monotonically increasing campaign — `bowr` 2026-09-02T23:02:24Z, `fran`
     00:20:39, `kisp` 00:54:39, `larl` 01:36:18, `lchl` 01:52:54, `lsal` 02:02:17, `mork`
     03:54:43, `morr_co` 04:15:05, `morr_ch` 04:35:14, `pars` 05:45:17, `pcea` 06:25:54,
     `sloc` 06:33:36, `tabr` 06:45:26, `ufra` 07:16:49, `will` 07:39:25 — one sequential
     upstream run over **all** areas, corrected and uncorrected alike. `kisp`, `pars` and
     `morr` are three of the five items v1.1.0's own table shows as geometry-unchanged, and
     `../floodplains/data/kisp/provenance.json` shows their `network` and `floodplain` steps
     re-ran in that campaign too (kisp: network 00:20:59, ff02 00:22:35, ff04 00:23:46, ff06
     00:49:28, landcover 00:54:39).
  3. **The dates rule out the alternative.** v1.1.0 published `bowr` at 235.75 km²; the run
     that produced 235.75 is stamped 2026-09-02T22:43:01Z, so the v1.0.0 build — which
     published `bowr` at 298.16 km² — predates it. `kisp`'s landcover stamp of
     2026-09-03T00:54:39Z therefore cannot have been in the v1.0.0 build, whenever that build
     was *published*. So v1.0.0 published a different `produced_datetime` for `kisp` than
     v1.1.0 did. The same holds for `bulk`, whose floodplain steps ran 2026-09-02T19:52–20:39,
     after the v1.0.0 tag commit (2026-09-02T18:40:51Z), and whose producer stamp was recorded
     as `2026-09-02T20:46:08Z` during the #32 work.

  The consequence for a reader is the opposite of what the sentence intends. The paragraph
  tells a consumer not to lean on `produced_datetime`, then hands them a supposed instance of
  the field standing still through a full byte-level republish. There is no such instance in
  this catalogue's history: **every republish so far has also re-run upstream.** A consumer who
  takes the parenthetical at face value would conclude a v1.1.0-era stamp is stable evidence of
  unchanged upstream content, which is precisely backwards.

  Fix: delete the parenthetical. The claim it supports is a true property of the field (it
  reads `landcover.<scen>.run.datetime_utc`, per `fp_provenance.R:67`) and stands on the
  mapping alone. If a worked example is wanted, it has to be a hypothetical — say so — because
  the catalogue has never produced one.

  Note the shape, since it is the mechanism's cleanest instance: this paragraph is the
  *replacement* written in round 1 for an over-stated `produced_datetime` claim, and round 2
  edited it again. Both rounds corrected the sentence's reach and neither checked the release
  it cites. The check is one `git tag --format=%(creatordate)` plus one read of the producer's
  `provenance.json`.

- **[fragile] NEWS.md:97–100 vs planning/active/progress.md:26–28 vs
  planning/active/task_plan.md:79 — three documents in one commit record three different
  populations for the same `/vsicurl/` read-back.**

  - `NEWS.md`: "The four *new* years … were checked instead by reading them back over
    `/vsicurl/` after publish, where **each** returns `Byte` / nodata 255 with the 9-row
    class-label RAT intact" → 16 rasters.
  - `progress.md`: "drift#62's `/vsicurl/` read confirmed on **a newly published year per
    item**, RAT intact" → 4 rasters.
  - `task_plan.md` validation: "The four items' **seven COGs** readable over `/vsicurl/` from
    the published hrefs" `[x]` → 28 rasters.

  **The property is true** — I read all 16 new COGs over `/vsicurl/` and every one is `uint8`,
  nodata 255, blocks 512×512, five overview levels, 9-row RAT. So no consumer is misled about
  the data. What is unreliable is the record of what the release verified, on the one bullet
  whose whole purpose is to say how the new assets were checked — and `progress.md`, the
  narrowest of the three, is the one written closest to the work. This is the same shape round
  2 caught between the task-plan checkboxes and the progress log.

  Fix: make one of them right and the other two agree with it. If only one year per item was
  read in-session, say so in `NEWS.md` (the substance is unaffected — the four checked years
  are representative and I have now confirmed the other twelve); if all sixteen were read, fix
  `progress.md`.

### Two things worth recording that are not findings

- **`bulk_co_ff04`'s pre-publish `nge:` properties are not recoverable from anything committed.**
  `baseline_live.json` (21:24:21Z) holds its assets but was taken with 10 assets and no
  property half; `baseline_full.json` (21:33:08Z) is post-publish for `bulk`; `baseline_rds_20260904.json`
  carries only modelled properties. So claim #12 ("exactly four properties move") and claim
  #24 ("for all four") are verifiable from the committed record for three of four items, and
  for `bulk` rest on `findings.md`'s plan-time measurement. That is honest — `findings.md`
  records the 4-of-4 fold check as taken before publishing — and the note in `baseline_full.json`
  already says the recovery was partial. Recording it so the next reader does not mistake the
  baseline for a complete pin.
- **Both false claims are about a *neighbouring* artifact, not this one.** Every claim in the
  table that could be settled by reading this release's own bucket, API or producer files came
  back true (38 of 38). The two that failed are about v1.1.0 and about a range summarised from
  memory. If a single habit is worth carrying forward from three rounds, it is: **a sentence
  naming another release is a citation, and gets opened.**
