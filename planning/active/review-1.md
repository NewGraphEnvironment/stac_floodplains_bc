# Plan review 1 — #80 (Plan agent, 2026-10-14)

Spawned at the plan gate, delivered ~12 min later, after Phase 1 had started. The agent
re-derived the plan's measurements independently across all rostered groups first and they
held. Findings below with this session's verdict on each; verified claims are marked with how
they were checked.

## Adopted

| # | Finding | Verdict |
|---|---|---|
| **B1** | One disposition given to two upstream states. A foreign *species/scenario* is known (3 groups, floodplains#131) and a message is right. A foreign **`wsg`** has never been seen and would mean the producer merged two groups into one area dir — and `test_pipeline.R:373-380`'s `wsg != meta$wsg` stop is the repo's only guard in that direction. Filtering removes such a layer *before* that assertion can see it, so the stop is traded for a census line. | **CONFIRMED, adopted.** `wsg` mismatch stops; species/scenario mismatch is the census. |
| **G2** | The per-file asymmetry has a case it gets wrong. `<sp>_ff0N_by_blue_line_key` / `_by_gnis_name` are derived from ONE scenario and record it. Species-only is safe today only because every retirement so far also changed the species; a headline moving `ch_ff04` -> `ch_ff06` would republish the retired scenario's attributed layer. | **CONFIRMED, adopted.** Keep where `scenario ∈ {<sp>_ff02, <sp>_ff04, <sp>_ff06} ∪ {item scenario}` — the vector `01_stage.R` already builds as `needed`. Re-measured here: **identical keep sets in all 24 areas**, so it is a strictly stronger rule at zero behavioural cost. |
| **G3** | The zero-layer guard must count **feature** layers too. `04_gpkg_style.py:153-156` raises on a file with no feature layers, so a landcover retaining only aspatial tables passes an R layer-count guard and dies three steps later under a message about styling. | Adopted. Both arms in `01_stage.R`, where the cause is known. |
| **G4** | A zero-row or NULL-key layer is undecidable, and report-and-drop is the direction that ships. | Adopted — `gpkg_layer_keys()` statuses `nokey` / `multi` **stop**. |
| **G5** | What catches a layer matching the key but named in no known family: landcover `features` **caught** (`04_gpkg_style.py:132-138`); landcover `attributes` **nothing** — and `composition_*` is already exactly this case in 5 of 23 groups; `floodplain.gpkg` **nothing**, because `:57` is a catch-all. The consequence moves from "inherited from upstream" to "selected by us". | Adopted as a census line over **kept** layer names, which is the name-vs-key cross-check in the opposite direction from O7. |
| **G6** | After this change **no** published asset is a verbatim upstream copy, and both GeoPackage checksums become a function of the R-side GDAL (3.8.5 here, not the 3.12+ uv GDAL writing the COGs). A rebuild on a differently-linked machine churns 2 assets × 23 items. | Adopted as documentation. `catalogue_release.sh:597-598` reasons *from* the old fact and is now false. |
| **O7** | Item (5) is load-bearing for a guard, not only for metric honesty: pointed at the staged copy, `01_stage.R:388-392` becomes a **name-vs-key cross-check** — a layer named `ch_ff02` whose `species` column says `co` is dropped by the filter and then stops the stage by name. | **Adopted, and it is the stronger reason.** The error must also name the staged path and separate "absent upstream" from "dropped by the filter". |
| **O8** | The census must be computed **once per group**, outside the target loop: "matches no item of the group" needs the group's whole target set, and computed inside, a 2-target group double-counts and can call a layer foreign that a sibling target owns. Dormant while every `area.yml` is `targets:`-free — the same shape #75 spent four rounds on. | Adopted. `gpkg_layer_keys()` is read **once per group** and the own sets are computed from that one table per target. |
| **O9** | Stop before you report, or a group with no landcover prints ~20 foreign-layer lines and then stops anyway. | Adopted. |
| **O11** | `01_stage.R:340-342`'s `file.copy()`-returns-FALSE reasoning must not be deleted wholesale — the raster copy at `:334` still depends on it. | Adopted. |
| **O12** | `gpkg_copy_layers()` unlinks `dst`, and `stage_years-check.R:170-173` hands the stage **symlinks to the producer's real `.gpkg` files**. A caller that swapped the arguments would delete upstream data. | Adopted — stated in the helper's doc. |
| **A13** | `-f GPKG` explicitly, switches before layer names: GDAL 3.9+ parses with argparse, where trailing positionals are safest last. | Adopted. |
| **AC19** | `test_pipeline.R`'s `feature_layers()` filter (`:358-361`) excludes exactly the aspatial tables the filter now **selects**, so a tightened assertion would leave them unchecked. The right discriminator is `gpkg_contents.data_type IN ('features','attributes')`, which also excludes `layer_styles` without naming it — `04_gpkg_style.py:21-26` records (measured) that it gets no `gpkg_contents` row. | **CONFIRMED, adopted.** Verified here that `st_read(query = "SELECT table_name, data_type FROM gpkg_contents")` works. |
| **AC20** | `gpkg_determinism-check.R` reads `data/stac/<item>/floodplain_landcover.gpkg` (`:28`), which after this change is *itself* a vectortranslate output — so extending it there proves "re-translating our own output is stable", not "translating the producer's file is stable", and the second is the property whose failure churns 46 published checksums. | **Adopted — the best finding in the review.** Adds an upstream-source arm that skips out loud when `$FLOODPLAINS_DATA` is absent, keeping the staged arm so the check still runs without the source tree. |

## Noted, not adopted as code

- **A14 FID preservation** — verified rather than assumed: UFRA's transition layer is
  `fid` 1..6929, 6929 rows, identical either side of the copy.
- **A15** — `st_read(query=)` is N dataset opens (22 for morr's 88 MB landcover). Measured
  trivial; a `UNION ALL` would be one open and is not worth the SQL.
- **S16 / S17** — the live orphans are the last whole-group GeoPackages in the catalogue
  after this lands, so #76 finishes what #80 starts; one NEWS line ties them. These two files
  are 813 MB across the 24 upstream dirs, and only the three affected groups shrink.
- **S18** — confirmed unaffected by reading: `catalogue_release-check.sh` (fully synthetic,
  never calls `01_stage.R`), `year_sets-check.py`, `only_preflight.py`, `PROVENANCE_FLOOR` /
  `PROV_CENSUS` (property counts, not layer counts), the sync (no `--size-only`, no
  `--delete`), and `item_validate.py`'s asset-key / style / checksum checks, which all derive
  their layer lists from the file.

## Where the review was right and this session was wrong

The review states `sf::gdal_utils()` "**does** `stop()` on failure — `if (ret) stop(...)`,
note the inverted return convention". This session initially recorded that as compatible with
its own measurement ("returns zero and only warns"). **It was not compatible, and the review
was right.** Re-measured with a `withCallingHandlers` warning handler alongside a `tryCatch`
error handler: a missing layer both warns and raises, with or without `-f GPKG`. The original
probe used `tryCatch(error =, warning =)`, which takes the warning first and never reaches the
error — the trap `code-check-r.md` already documents. The probe was broken before the world
was, which is the standing prior when an ad-hoc probe disagrees with a code read.

Both guards stay, for corrected reasons: the warning guard for its message (`gdal_utils`'s own
error names nothing; the warning names the layer), and the `setequal()` arm as the backstop
over the 65,536-byte carcass a failed call leaves on disk. `findings.md` carries the table.

## Run order the review proposed, adopted for Validation

`stage_years-check.R` already drives the real `01_stage.R` in a sandbox, so items (3) and (4)
need no new harness: `AREA=ufra` first (its `PIN_META_SHA256` is the only byte-pin on
`meta.json` in the repo, and ufra has no foreign layers, so it is the existence proof that
reading areas from the staged copy moved no published number), then `AREA=morr` / `AREA=bulk`
for the 25- and 14-foreign-layer paths, then `WSG=morr` end to end, then `WSG=larl` as the
minimal keep set (3 + 4, no `_by_blue_line_key`, no aspatial table) where a too-aggressive
filter shows first.

## Stale already, unrelated to this change

`gpkg_determinism-check.R:10` and `style_determinism-check.py:18` both suggest
`ITEM=bulk_co_ff04`, a retired id; `readme_functions.R:551` says "MORR has two [items]".
