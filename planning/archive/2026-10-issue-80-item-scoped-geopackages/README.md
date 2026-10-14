# #80 — stage each item's GeoPackages with only that item's layers

**Closed by** PR on branch `80-stage-each-item-s-geopackages-with-only`, commits `d370961`
(PWF baseline) through `5fe7400`. **Nothing published yet:** the republish is the next full
release, which syncs the whole tree anyway.

`01_stage.R` copied `floodplain.gpkg` and `floodplain_landcover.gpkg` whole from the producer's
per-group bundle into every item's staging dir. Self-describing while a group's layers were all
one species'; not once groups went whole-network, because upstream keeps the retired species'
layers on disk until floodplains#131 prunes them. `bulk_all_ff04` was publishing BULK's **coho**
floodplain and coho transition inside the whole-network item's own assets, and `morr_all_ff04`
both coho's and chinook's — #76's problem happening inside a single item. Staging now writes
both files, selecting each layer by its own `wsg`/`species`/`scenario` (floodplains#30) rather
than by its name, through one `vectortranslate` call into an unlinked destination.

Two things came out of the work that were not in the plan. **Layer order changes the bytes**, so
the writer sorts (`method = "radix"`, C-locale rather than the operator's `LC_COLLATE`) — without
that, every published `file:checksum` depended on `st_layers()` order and the determinism check
was proving a file the stage does not write. And the two files are keyed **differently**, which is
a property of the data: `floodplain.gpkg`'s ff02/ff06 delineations each record their *own* flood
factor in `scenario` and the item publishes all three, so that file is keyed on the item's ff set
while the landcover bundle is keyed on its single scenario.

## Measurement

Published volume, all 23 rostered groups, both bundles: **826.9 → 642.9 MB**, 184 MB less to
publish. MORR −70% (116.3 → 35.4), BULK −36% (169.0 → 107.8), KISP −35% (57.2 → 37.0); the other
20 shrink 0–19% from repacking alone — which is why **every** item's `file:checksum` moves for
both assets, not only the three groups that carried foreign layers. The same 642.9 MB was reached
twice, once by projection through `gpkg_copy_layers()` into a tempdir and once by auditing the
staged tree with stdlib `sqlite3` only, sharing no code with the selector.

No published **value** changes. `stage_years-check.R`'s `PIN_META_SHA256` — the only byte-pin on
`meta.json` in the repo — passes unskipped, so moving the area, bbox and geometry reads onto the
staged copy moved no published number; and MORR's areas and loss/gain figures are identical read
from upstream and from the staged copy, which extends that beyond the one digest-pinned item.
`transition_vector.gpkg`'s checksum does not move at all: extracting its layer from upstream and
from the staged bundle gives the same md5 and byte count.

Enabling measurement, over all 24 upstream area dirs: **276 of 276** layers carry all three key
columns, each single-valued (246 `features`, 30 `attributes`). Foreign layers exist in exactly
three groups — bulk 14, kisp 9, morr 25.

## Evidence

The PWF triple here, plus four review reports. `review-1.md` is the plan review (14 adopted
findings, two of which changed the writer); `review-round1.md` through `review-round3.md` are
`/code-check branch`.

Every refusal in the change was fired against the mutation only it can see, and the tables in
`progress.md` list each with its mutation and the message it produced — the whole-copy defect
restored, one of the item's *own* layers dropped, `UPDATE … SET wsg='BULK'`, `species='xx'` on
every layer and on the feature layers only, `ALTER TABLE … DROP COLUMN species`, a bundle
overwritten with garbage, a `bt_ff04_reach_summary` table registered `attributes`, a selector
made to lose a whole family, and `NO_PIN=1`.

## The wrong turns, kept

Three rounds of review, and **each round's best finding was a correction whose own enumeration
was one short** — round 1 fixed one of three statements sharing a control-flow position, round 2
fixed one of ten copies of a retired premise, round 3 found one of three copies of a corrected
number. What ended it was grepping for the sentence rather than recalling where it appeared.

Two of round 2's and round 3's findings were defects *inside this branch's own fixes*, and two
more were **false reasons recorded for correct code** — a fix whose comment claimed
`withCallingHandlers`/`tryCatch` nesting order mattered (it does not; both capture both), and a
guard citing NEEXDZII as its instance when the group-level `wsg` refusal fires before that arm
can ever run.

Round 1's actual bug was mine: the warning guard captured the GDAL warning, muffled it, and
raised *after* the call — but `gdal_utils()` raises on the same call, unwinding the handler stack
first, so the layer name was discarded and the muffle killed the one place it would have printed.
**Strictly worse than having no handler.** It was visible in my own Phase 1 probe output, misread
there as `-f GPKG` changing the failure path. The probe that produced the original "it only
warns" claim was itself the artifact: `tryCatch(error =, warning =)` takes the warning first and
never reaches the error.

Four claims in these planning files were wrong when written and are corrected in place rather
than erased: a proof that misdescribed its own mutation, an md5 equality that holds only before
`04_gpkg_style.py` runs, "21 groups" for 20, and a planted mutation left in the working `data/`
tree that would have sent the next run red on a defect I planted.

## Left open, deliberately

- **#76** — the four live orphans are the only whole-group GeoPackages left in the catalogue once
  this publishes, so #76 finishes what this starts.
- **#65 / #70** — `patch_watercourse_*` (18 groups) and `composition_*` (5) are published and
  described nowhere. This reports them per item, across both bundles, and reports any staged
  layer matching no known family; it does not document them.
- **floodplains#131** — upstream's prune, now disk hygiene rather than a blocker.
- **The release** — `PROVENANCE_FLOOR` and `PROV_CENSUS` are re-taken on the build a release is
  cut from, and DUNC cannot publish until floodplains#133.
