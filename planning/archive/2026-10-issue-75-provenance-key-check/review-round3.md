# Code-check round 3 (enumeration) — branch `75-provenance-key-check-verify-each-item-fi`

Reviewed 2026-10-14 against the `origin/main` merge-base (three-dot, 15 files). This is the
**enumeration round** the stopping rule requires, not another sweep: round 2 found a defect inside
round 1's fix, so a quiet round no longer ends the loop.

**Mechanism being enumerated against** (round 2's wording): *a fact about data living outside this
repo, copied in as a statement, with nothing that re-derives it and a quiet failure direction.*
Remedies: **derived** (read from the source of truth), **gated** (an ordered skip/refusal when the
pin no longer describes the file), **compared** (a floor or a relation instead of a value), **none**.

All measurement was read-only. Nothing in the repo working tree was modified (`git status` clean
before and after every command). Probes are in
`/private/tmp/claude-501/.../scratchpad/probe_enum1.py`, `probe_enum2.py`, `roster.json`.

## How the set was built (mechanically, not from memory)

1. `git diff -U0 <merge-base>...HEAD` per changed script file, every `+` line emitted with its
   current line number (459 added lines) → `scratchpad/added.txt`.
2. Non-comment added lines filtered for any quoted string or digit → the code-literal candidates.
3. Added lines in `CLAUDE.md`, `NEWS.md`, `scripts/README.md` filtered for numerals, dates,
   digests, versions and area/scenario/species tokens → the prose-claim candidates.
4. The four literals the brief names, read in full although outside the diff:
   `PROV_CENSUS` + `EXPECTED_DEPRECATED` + `ALLOWED_YEAR_SETS` (`item_validate.py`),
   `DEPRECATED_ITEMS` (`item_create.py`), `PROVENANCE_FLOOR` (`catalogue_release.sh`).
5. Every claim re-derived from the producer tree with stdlib Python over
   `../floodplains/data/*/provenance.json` and `../floodplains/config/`, independently of this
   repo's reader; the live-catalogue claim read from the public bucket.

## Ground truth measured for this round (2026-10-14)

| measurement | value |
|---|---|
| `../floodplains/data` area dirs / carrying a non-empty record | 26 / **22**; the four without are exactly `lit`, `logs`, `mcgr`, `pine` |
| rostered groups (`config/regions/*.yml`) / declared targets | 23 / **23** — **no** `area.yml` declares `targets:` |
| rostered targets whose scenario is missing from a non-empty `floodplain`/`landcover` section | **0** |
| `rasters/<scenario>/` set vs `landcover` keys, per record | **equal in all 22**, 0 violations; `floodplain` keys a superset in all 22 |
| `floodplain`+`landcover` sections restating their own key | **104 / 104** |
| areas carrying `all_ff0*` keys | exactly `bulk`, `dunc`, `kisp`, `morr` |
| `morr` section counts | floodplain **9**, landcover **3**, network **3** (`all2`, `ch3`, `co3`) |
| per-field census over the 23 targets | `link_run_uid` **17**, `link_config_sha256` **20**, `link_sha` **20**, other nine **21**; traced **21** of 23 |
| year sets over the 23 targets | (2017,2020,2023) ×**19**, annual 2017–2023 ×**4** (`kotl`, `necr`, `lnth`, `bulk`) |
| `neexdzii` landcover stamp / fold / `item_hash` | `2026-10-13T23:24:26Z` / `sha256:170a9ef4…` (re-derived in stdlib Python) / `sha256:c653b16d…` — all three match the pins |
| `bulk` `floodplain` `flooded` versions | `all_*` 0.7.0, `co_*` 0.5.0 |
| `Rscript scripts/fp_provenance-check.R` on the final branch state | **87 assertions, 0 failed, 0 skipped**, exit 0 |
| live catalogue (bucket, GetObject) | `morr_co_ff04` 200, `morr_ch_ff06` 200, `bulk_co_ff04` 200, `kisp_ch_ff04` 200, `morr_all_ff04` **403 (absent)** |
| `mcgr` / `pine` `primary_scenario` | `ch_ff04` / `bt_ff04`; both carry `rasters/<scen>/`, neither carries a record |

## Enumeration — every statement about data outside this repo, in the files this branch touches

**Set size: 49 members.** Verdict column: D derived · G gated · C compared · **N none**.

### `scripts/fp_provenance.R`

| # | file:line | fact stated | source of truth | remedy | quiet? |
|---|---|---|---|---|---|
| 1 | :32 `FP_PROV_SCHEMA_VERSION <- 2L` | upstream's record schema is v2 | the record's `schema_version` | **G** — refuses, naming both versions | no |
| 2 | :63-77 `FP_PROV_MAP` | 12 key paths inside the producer's record | the record | **G** — `fp_prov_leaf` stops on an absent key under a present section | no |
| 3 | :200-201 | "morr's file holds nine floodplain sections and three landcover ones" | the record | N (comment) | no — measured TRUE (9/3) |
| 4 | :202-205 | "upstream retired its `targets:` block under floodplains#125 … the plural case is currently unoccupied" | `config/*/area.yml` | N (comment) | no — TRUE, 0 of 23 declare `targets:` |
| 5 | :211-213 | "`all2` is order 2 … a group carrying both `co3` and `all2`" | the record + `area.yml` `min_order` | N (comment) | no — TRUE (`bulk`, `morr`) |
| 6 | :272-281 | **the safety premise**: "over all 22 areas carrying a record: `rasters/<scenario>/` EQUALS the landcover keys, floodplain keys a superset" — the justification for the new stop | the producer tree | **N** — a copied measurement | **no** — if it fails, the new stop fires loudly; the code names the line to revisit |
| 7 | :290-297 | "measured on all 104 sections on disk, zero exceptions" (declined cross-check) | the record | N (comment) | no — TRUE 104/104 |
| 8 | :302-306 | the target declares a usable scenario | the caller | **D** | no |
| 9 | :317-323 | the section is an object keyed by scenario id | the record | **D** | no |
| 10 | :324-331 | **the item finds its key** (the change) | the item's own `scenario` vs the keys present | **D** | no — 0 misses over all 23 |
| 11 | :342-347 | no duplicate scenario key | the keys present | **D** | no |
| 12 | :355-360 | the scenario key's value is not null | the keys present | **D** | no |

### `scripts/01_stage.R`

| # | file:line | fact stated | source of truth | remedy | quiet? |
|---|---|---|---|---|---|
| 13 | :37 `TRANSITION_SPAN <- c(2017L, 2023L)` | repo-owned contract, not an upstream fact | — | N by design (the anchor) | no |
| 14 | :205 `targets <- area$targets` (pre-existing, unchanged) | the roster's target block | `area.yml` | **N** — `$` partial-matches | **yes** — see finding 2 |
| 15 | :218-219 `tgt$scenario` / `tgt$species` | the target's species + scenario | `area.yml` | **G** — the `[[` guard at :227-237 refuses anything `[[` cannot find, so `$`'s partial match cannot reach `item_id` | no |
| 16 | :224 | "the four that carry no provenance.json at all (measured 2026-10-14: lit, logs, mcgr, pine)" | the producer tree | N (comment) | no — TRUE, exactly those four |
| 17 | :227-237 | the roster assertion | the roster entry, `tgt_i` as pointer | **D** (round-1 fix) | no |

### `scripts/fp_provenance-check.R`

| # | file:line | fact stated | source of truth | remedy | quiet? |
|---|---|---|---|---|---|
| 18 | :92 `YEARS <- c(2017L, 2020L, 2023L)` | synthetic fixture span | self-contained | n/a | no |
| 19 | :174-179 | `all_*` / `wct_*` sibling keys exist as a shape | synthetic fixture (and `wct_ff04` exists nowhere on disk — admitted on principle) | n/a | no |
| 20 | :186 | "the shape `bulk`, `kisp`, `morr` and `dunc` carry on disk as of 2026-10-14" | the producer tree | N (comment) | no — TRUE, exactly those four |
| 21 | :187-204 | the whole-network fixture (`all2`, `inputs$species: all`) | synthetic | n/a | no |
| 22 | :236-245 | the duplicate-key raw-JSON fixture (`9.9.9` / `0.5.0`) | synthetic | n/a | no |
| 23 | :431 `real_item(species="co", scenario="co_ff04")` + :449 `real("bulk")` | bulk still carries a `co_ff04` pair — a section floodplains#125/#131 retires | the producer tree | **N** | **no** — round 2's `real_arms` turns the refusal into one named failed assertion; documented at :434-441 |
| 24 | :436 **"the 15 arms below"** | a count of this file's own real-file arms | this file | **N** | no — **WRONG: 9** (see finding 1) |
| 25 | :459-461 `compareVersion(flooded_version, "0.5.0") >= 0` | `flooded` is at or above the #26 fix | the record | **C** (round-2 fix) | no — bulk `co_ff04` is 0.5.0 |
| 26 | :466 `all(c(2017L, 2023L) %in% …$years)` | the transition window the repo publishes | `TRANSITION_SPAN` (repo-owned), copied | N | no — but if bulk's landcover section ever became *empty*, `fp_prov_span` returns `NULL` and this arm fails under a span message while #27 four lines below passes; pre-existing line, state not currently reachable |
| 27 | :470-476 `lc_present` | whether bulk's landcover step has run | the raw JSON | **D** | no |
| 28 | :497 `PIN_STAMP <- "2026-10-13T23:24:26Z"` | the build the fold pin was taken from | the record's `run$datetime_utc` | **G** — skips out loud | no — matches today |
| 29 | :504 `sha256:170a9ef4…` | the fold of neexdzii's three digests | the record | **G** under #28 | no — re-derived independently, matches |
| 30 | :513 `sha256:c653b16d…` | neexdzii's recorded `item_hash` | the record | **G** under #28 (round-2 fix moved it inside) | no — matches |

### `scripts/stage_years-check.R`

| # | file:line | fact stated | source of truth | remedy | quiet? |
|---|---|---|---|---|---|
| 31 | :62 `AREA` default `"ufra"` | a fixture area exists upstream | the producer tree | **G** — the four skips below | no |
| 32 | :68-78 `is.null(AREA_REGION)` folded into the "no upstream tree" skip | the area is rostered | `config/regions/*.yml` | **N** | **yes** — wrong cause reported; **finding 3** |
| 33 | :79-85 | the area declares no `targets:` | `area.yml` | **G** — skips out loud | no |
| 34 | :80 `AREA_CFG$targets` | the target block | `area.yml` | **N** — `$` partial-matches | **yes** — finding 2 |
| 35 | :86-89 `SCEN <- AREA_CFG$primary_scenario`, `ITEM` | the item id under test | `area.yml` | **D** | no |
| 36 | :105-111 | the area carries a record | the file | **G** — skips out loud (round-2 fix) | no |
| 37 | :113-121 | the record has a landcover section for `SCEN` | the record | **G** — skips out loud | no |
| 38 | :122 `sort(as.integer(unlist(REC_LC[["inputs"]][["years"]])))` | the recorded span | the record | **N** — blind `unlist`, the trap `fp_prov_span`'s own comment names ("a JSON null … would fold to a shorter span that looks entirely valid") | no — a short span moves DROP/PLANT/FAKE and the arms fail on their own messages; `01_stage.R` stops independently |
| 39 | :123 `stopifnot(length(REC_YEARS) >= 3L)` | every record names ≥ 3 years | the record | **N** — and it aborts rather than skipping, unlike the four sibling states | marginal — message is accurate; unreachable today (19 three-year + 4 annual) |
| 40 | :126-133 `DROP_YEAR` / `PLANT_YEAR` / `FAKE_YEAR` / `MUT_YEARS` | the mutations | the record | **D** — verified on both populations: 3-year → drop 2020, annual → drop 2018, never a `TRANSITION_SPAN` end | no |
| 41 | :216-217 `PIN_STAMP` / `PIN_TOOLCHAIN` | the build and machine the `meta.json` digest was taken on | the record / `sf_extSoftVersion()` | **G** | no |
| 42 | :238-242 `!identical(AREA, "ufra")` | the digest pin is `ufra_ch_ff04`'s | `AREA` | **D/G** — ordered *before* the stamp gate, so it cannot blame upstream | no |
| 43 | :237 `[["landcover"]][["run"]]…` | the stamp path | the record | **D** (`[[`, round-1 fix) | no |

### `scripts/test_pipeline.R`

| # | file:line | fact stated | source of truth | remedy | quiet? |
|---|---|---|---|---|---|
| 44 | :456-461 `want` / `setequal` | a group stages exactly its declared targets | `area.yml` | **D** — *removes* a stale literal | no |
| 45 | :457-459 `area_cfg$targets`, `area_cfg$primary_scenario`, `t$scenario` | the roster | `area.yml` | **N** — `$` partial-matches | **yes** — finding 2 |
| 46 | :10, :70, :343-345 | "`WSG=bulk` … 7-year span"; "`--expect` … the number of targets the group's area.yml declares"; "a whole-network group ships the retired species layers beside its own" | the producer tree | N (comments) | no — bulk is 7-year; bulk's `floodplain.gpkg` does carry `co_*` layers |

### `scripts/readme_functions.R` / `scripts/item_create.py`

| # | file:line | fact stated | source of truth | remedy | quiet? |
|---|---|---|---|---|---|
| 47 | `readme_functions.R:21-26` `SPECIES` + "the species slot takes two to four letters", "`all` is the reserved token … order ≥ 2 … `blue_line_key`", "`wct` has no published item yet" | upstream's validator + region configs | **N** for the labels, but it is a **lookup, not a guard**: `[` + `dplyr::coalesce(..., species)` at :168 and :573, so a miss renders the raw code | no — `wct` exists nowhere on disk, every region declares `network: whole` |
| 48 | `item_create.py:4-5` "`morr_co_ff04` + `morr_ch_ff06` — both still live, though a rebuild now stages `morr_all_ff04` alone" | the live catalogue | **N** (docstring) | no — **now VERIFIED**: both objects 200 in the bucket, `morr_all_ff04` 403 (round 2 could not reach the API and left this "CONSISTENT, NOT VERIFIED") |

### Prose counts introduced or edited in `CLAUDE.md` / `NEWS.md` / `scripts/README.md`

| # | where | claim | verdict |
|---|---|---|---|
| 49a | `CLAUDE.md:92` | "MORR carries two LIVE … but stages one … live orphans until #76" | **TRUE** — verified from the bucket |
| 49b | `CLAUDE.md:99` | "two to four lowercase letters (its own validator is `^[a-z]{2,4}$`)" | TRUE (round 2, `floodplains/.../01_network_extract.R:56`) |
| 49c | `CLAUDE.md:100-102` | "`all` is the reserved token for the whole network at order ≥ 2 with no access filter, attributed by `blue_line_key`" | TRUE — every `config/regions/*.yml` declares `network: whole` |
| 49d | `CLAUDE.md:105-106` | "the roster is upstream: `config/regions/*.yml` … `config/<wsg>/area.yml` names its targets" | TRUE |
| 49e | `CLAUDE.md:194` | "the literal reads `link_run_uid` 18 and the other eleven 21" | TRUE of `PROV_CENSUS` |
| 49f | `CLAUDE.md:195-200` | "measured 2026-10-14 … over all 23 rostered targets, the census is 17 / 20 / 20, the other nine 21, with `PROVENANCE_FLOOR` 21 still exact. The whole delta is DUNC" | **TRUE** — re-measured independently through `FP_PROV_MAP`'s paths: 17/20/20, nine 21s, 21 traced of 23 |
| 49g | `NEWS.md` | "`all_ff02`/`all_ff04`/`all_ff06` exist on disk now in `bulk`, `kisp`, `morr` and `dunc`" | TRUE — exactly those four |
| 49h | `NEWS.md` | "87 assertions, 0 skipped" | **TRUE on the final branch state** — re-ran: 87 / 0 failed / 0 skipped, exit 0 |
| 49i | `NEWS.md` | "measured on all 104 sections on disk" | TRUE — 104 / 104 |
| 49j | `NEWS.md` | "`PROV_CENSUS` reads 18 / 21 / 21 where the current roster measures 17 / 20 / 20 … DUNC … null `link_log` … refused one step earlier by `item_create.py`" | TRUE |
| 49k | `NEWS.md` | "the `neexdzii` fold pin … was **dead** … and is re-taken, re-derived independently" | TRUE — stamp and both digests match; pin is live |
| 49l | `scripts/README.md:198` | "`WSG=bulk` … whole-network group: species `all`, 7-year span" | TRUE |
| 49m | `scripts/README.md:374-385` | "measured 2026-10-14, the whole script halted on the real `bulk` file" | TRUE (round 2 reproduced against the merge-base) |
| 49n | `scripts/README.md:~376` | "**The section headed "the item's own scenario key (#75)"** … Its two must-fail arms re-key a section" | **MISPLACED** — those two arms are at `:149-155`, ~20 lines *above* that section's header at `:172`; the script's own comment correctly says "the two must-fail arms **above**" |
| 49o | `scripts/README.md:422` | the `AREA=<wsg>` row | accurate, but silent on the two forward-only skips (no record; not rostered) |

### The four named literals, outside the diff

| # | where | literal | remedy | verdict |
|---|---|---|---|---|
| L1 | `item_validate.py:540-552` `PROV_CENSUS` | 18 / 21 / 21 + nine 21 | **N** by design (an exact literal a human sets) | **stale by 1/1/1** against the measured roster. Accepted in round 1 and now documented in both `CLAUDE.md` and `NEWS.md`. Fails toward a **refusal**, and DUNC is independently refused one step earlier at `item_create.py`, so nothing can publish on a wrong count |
| L2 | `catalogue_release.sh:60` `PROVENANCE_FLOOR=21` | 21 | **N** by design, exact both directions | **still exact** (21 traced of 23). Its comment at :57-59 still says "any full rebuild from today's producer tree carries `bulk_co_ff04`" — now false (a rebuild carries `bulk_all_ff04`); no behaviour, file not touched by this branch |
| L3 | `item_create.py:91` / `item_validate.py:258` `{"mcgr_ch_ff04","pine_bt_ff04"}` | 2 item ids | **N** by design, biconditional both directions | **still correct**: `mcgr` `primary_scenario` is `ch_ff04`, `pine` `bt_ff04`, both carry rasters, neither carries a record (so both must be marked). Scheduled to break when FRASER/PEACE re-run them whole — `network: whole` is already declared in both region files — and it breaks as a **refusal**, with no quiet direction |
| L4 | `item_validate.py:1006-1009` `ALLOWED_YEAR_SETS` | two tuples | **N** by design, checked in both directions | **no literal moves**: both tuples occupied over the 23 targets (19 three-year, 4 annual), and the new `all_*` items land inside them (`bulk` annual; `kisp`/`morr`/`dunc` three-year) |

## Verdict

**49 members.** Four sit above their source of truth with **no remedy and a quiet failure
direction**, and they are three distinct defects (#14/#34/#45 are one mechanism in three places):

- **#24** — a count in a comment that is simply wrong on arrival (9 arms, stated as 15). Finding 1.
- **#14 / #34 / #45** — `$` reads of the producer's `area.yml`, in a branch whose own new comment
  bans exactly that access form. Finding 2.
- **#32** — the `AREA` override's fourth forward-only state reports the wrong cause. Finding 3.

Everything else is **derived** (12 members), **gated** (10), **compared** (1), or a comment/prose
claim with no behaviour that I **re-measured TRUE** this round (23 members, table above). The two
remaining "none with a loud direction" members are the accepted ones: the `co_ff04` pinning of the
real-file arms (#23, round 2's finding, remedied to one named failed assertion) and the stale
`PROV_CENSUS` (L1, round 1's finding, remedied by documenting it).

The core change itself — `fp_prov_sections()`'s item-finds-its-key — has **no literal to go stale**
and passes the entire real roster (23 targets, 0 misses), and its safety premise (#6) re-measures
TRUE with 0 violations over all 22 records.

## Findings

- **[fragile]** `scripts/fp_provenance-check.R:436` — the comment that justifies keeping
  `real_arms()` says the pre-#75 halt meant "the 15 arms below never ran". **It is 9.** Counted
  mechanically on both the merge-base and HEAD: `grep -cE 'expect_(true|equal|stop)\('` from
  `b <- real("bulk")` to EOF gives **9** on each (4 bulk + 5 neexdzii), plus 2 `skip()` calls = 11
  at most. `NEWS.md` makes the same claim correctly without a number. A copied count that is wrong
  on arrival is the enumerated mechanism in its purest form, and this one is load-bearing as
  rhetoric: it is the argument a future reader uses to decide whether `real_arms` earns its place.

- **[fragile]** `scripts/stage_years-check.R:80`, `scripts/test_pipeline.R:457-459` (and
  `scripts/01_stage.R:205`, pre-existing) — three **new** `$` reads of the producer's `area.yml`
  landed in this branch, 12 lines below its own new comment declaring the opposite rule:
  *"`[[` throughout, never `$`: `$` partial-matches on a list … That is the access form
  fp_provenance.R bans by name, and a fixture builder reading the producer's file is not exempt
  from it."* Round 1 reported this mechanism, and the branch fixed its two instances in
  `stage_years-check.R` "together so a later reader does not find one half converted" — while
  adding `AREA_CFG$targets` in the same file and three more in `test_pipeline.R`.

  Measured on this R:

  ```
  x <- list(targets_retired = list(list(scenario = "co_ff04")), primary_scenario = "all_ff04")
  x$targets          #> list of 1   (partial match on targets_retired)
  x[["targets"]]     #> NULL
  yaml::yaml.load("targets_retired:\n  - scenario: co_ff04\n")$targets  #> non-NULL
  ```

  The quiet direction is specific and plausible, because the producer is *in the middle of*
  retiring target blocks (`config/morr/area.yml` says so in prose today): an upstream
  `targets_retired:` / `targets_old:` key with no live `targets:` is matched by `$targets` in
  **both** `01_stage.R:205` and `test_pipeline.R:457`. The two then agree, the build stages the
  retired items, and the smoke test's new `setequal()` confirms them — a publish of retired
  `co_*`/`ch_*` items with every gate green. `stage_years-check.R:80` fails toward "skip every
  case", which the summary line at least says out loud. No such key exists in any `area.yml`
  today, so this is latent, not live; `[[` on all four is a one-character change each.

- **[fragile]** `scripts/stage_years-check.R:74-78` — the `AREA` override made a fourth
  forward-only state reachable, and it reports a cause that is false. `is.null(AREA_REGION)` (the
  area is not in any region roster) shares its skip with `!dir.exists(src_area)`, so:

  ```
  $ AREA=neexdzii Rscript scripts/stage_years-check.R
    skip  every case (no upstream tree at ../floodplains/data)
  $ AREA=lit Rscript scripts/stage_years-check.R
    skip  every case (no upstream tree at ../floodplains/data)
  ```

  For `neexdzii` the tree, `data/neexdzii/`, `config/neexdzii/area.yml` **and** a full
  `provenance.json` all exist — it is deliberately not rostered (`config/regions/skeena.yml`:
  *"NEEXDZII (subset of BULK) intentionally excluded"*). And `neexdzii` is the most likely
  `AREA=` value anyone tries after `ufra` and `bulk`: it is this repo's named coho parity fixture
  and the only area the fold pin is taken from. This is the same wrong-cause shape as round 2's
  `AREA=mcgr` crash and as the two message fixes this branch already made (`:117` "would name the
  wrong cause", `:238` "whose message would otherwise blame upstream"); splitting the
  `is.null(AREA_REGION)` arm into its own skip ("`<area>` is not in any region roster") closes it.

### Noted, not findings

- `scripts/README.md:~376` attributes the two re-key must-fail arms to the `#75` section; they sit
  ~20 lines above its header (`:149-155` vs `:172`), and the script's own comment says "above".
  A wrong pointer in prose, same class as round 1's two, no behaviour.
- `scripts/stage_years-check.R:122` reaches the producer's `years` array through a blind
  `unlist()` — the trap `fp_prov_span()`'s own comment names by name. Not a live defect: a dropped
  null year moves the derived mutations and the arms fail on their own messages, and `01_stage.R`
  stops independently in `fp_prov_span()`.
- `scripts/stage_years-check.R:123` aborts via `stopifnot` where its four siblings skip out loud;
  the message is accurate and the state is unreachable today (19 three-year + 4 annual records).
- `scripts/catalogue_release.sh:57-59` (untouched by this branch) still says a full rebuild
  "carries `bulk_co_ff04`"; a rebuild now carries `bulk_all_ff04`.
