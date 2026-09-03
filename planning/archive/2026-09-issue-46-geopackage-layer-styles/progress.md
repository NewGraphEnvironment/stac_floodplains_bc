# Progress — Ship the class palette with the GeoPackages: embedded layer_styles + published .qml, generated from classes.json (#46)

## Session 2026-09-03

- Plan-mode exploration across staging, item build/validate and the release path — phases approved by user
- Created branch `46-ship-the-class-palette-with-the-geopacka` off main
- Scaffolded PWF baseline from issue #46 with approved phases
- Carried in from the pre-branch session: `scripts/style_qml-write.py` and three generated
  styles in `styles/`, all three verified loading in QGIS 4.2.1
- Decisions locked: gain categories ship present-but-off; 50% symbol opacity; styles
  committed and drift-checked rather than generated at build time; closes with NO release
- Next: Phase 1 — rename `transition_trees.qml`, settle asset names, add the drift check

### Phase 1 — done

- `transition_trees.qml` renamed to `transition.qml`; names settled as `floodplain.qml` /
  `classified.qml` / `transition.qml`, asset keys `style_floodplain` / `style_classified` /
  `style_transition` (applied in Phase 4)
- `scripts/style_qml-write.py` gained `build_all()` as its single entry point
- `scripts/style_drift-check.py` added, two-sided on the file set and the bytes, and refusing
  when it compared nothing
- **The drift check found a real defect on its first run.** The generator used `uuid4()` for
  symbol-layer and category ids, so every run emitted different bytes at identical length —
  the committed styles could never have been byte-compared, and the embedded copy would have
  churned `transition_vector.gpkg`'s published `file:checksum` on every rebuild. Replaced with
  `uuid5` over a fixed namespace and stable keys. Two independent runs now produce identical
  sha256 for all three files.
- Both drift arms proven to fire: a perturbed committed style exits 1, an uncommitted
  generator output exits 1
- Re-verified in QGIS 4.2.1 after the UUID change — all three still load, opacity 0.5,
  0 data values unmatched, 8 gain categories present and off
- Documented in `scripts/README.md`

### Phase 2 — done

- `scripts/04_gpkg_style.py` added, stdlib `sqlite3` only, wired into `run_pipeline.sh`
  and `test_pipeline.R` between step 03 and `item_create.py`
- **Two design improvements over what QGIS's own writer produces**, both measured:
  - No `gpkg_contents` row and no triggers. QGIS auto-styles perfectly without them, and
    registering the table would add a second wall-clock stamp (`gpkg_contents.last_change`)
    on top of `layer_styles.update_time`. GDAL lists `layer_styles` as a layer either way,
    so the registration bought nothing and cost a churn vector. One vector remains, pinned.
  - `update_time` read from `fp_gpkg.R`'s `GPKG_EPOCH` rather than restated, so the pin has
    one source.
- **Determinism took two attempts.** One pass over a virgin file is byte-reproducible, but a
  second pass was not: SQLite bumps its header change counter on any write transaction and a
  DELETE leaves freelist pages, so rewriting identical rows still moved the bytes. Now the
  rows are compared first and the write skipped when they match. Three consecutive passes
  give one digest on all three files.
- An unmapped layer raises rather than being skipped — a new or renamed upstream layer must
  not ship unstyled while its neighbours look correct.
- Verified in QGIS 4.2.1: all 8 layers across the 3 GeoPackages auto-style on a plain open
  with no `.qml` loaded — 3 single-symbol, 3 categorized at 9 classes, 2 categorized at 73,
  every symbol at opacity 0.5.

### Phase 3 — done

- Confirmed the break before fixing it: the unmodified `test_pipeline.R` loop errors with
  `layer 'layer_styles' ... has no wsg column` against a styled GeoPackage.
- Fixed by filtering to layers that HAVE a geometry, not by excluding the name
  `layer_styles` — a name test would pass the day a second non-spatial table appears. The
  filter refuses if it removed everything, so it cannot make the assertions vacuous.
- Audited the other two `st_layers()` callers: `fp_gpkg.R:65` and `01_stage.R:294` are a
  membership test and a `setdiff` against a needed set, both of which tolerate an extra
  layer. Neither needed changing.
- `scripts/style_determinism-check.py` added rather than extending the R check: the style
  pin is a different mechanism in a different language, and `OGR_CURRENT_DATE` cannot reach
  a row written through `sqlite3`. Warm, cold and re-run-is-a-no-op arms all pass.
- The check's first run failed usefully — the writer refused a temp file named
  `a_floodplain.gpkg` because it keys its style map on the basename. That is the production
  behaviour we want, so the check moved to subdirectories instead.

### Phase 4 — done

- `04_gpkg_style.py` now also copies the three `.qml` into each item directory, writing
  only when the bytes differ so an unchanged rerun does not move an mtime.
- `item_create.py` publishes them as `style_floodplain` / `style_classified` /
  `style_transition`, media type `application/xml`, `roles: ["style"]`, each with
  `file:checksum` and `file:size` from the existing `file_meta()`.
- Keys are prefixed rather than named for the file stem, deliberately: `floodplain` and
  `transition_vector` are already asset keys, so a stem-keyed style would replace a data
  asset and leave the asset count unchanged — the same trap the `transition_vector`
  comment in that file already describes.
- Both preflight filename lists extended from `STYLE_ASSETS`, so the list has one source.
- `test_pipeline.R`: asset count 7 -> 10, plus per-key presence and a `roles == ["style"]`
  assertion, since a count alone cannot tell a style from a replaced data asset.
- Built and validated: 10 assets on `kotl_bt_ff04`, `item_validate.py` green including its
  re-hash of every asset.

### Phase 5 — done

- `check_layer_styles()` added to `item_validate.py`: every feature layer carries a style
  row, `f_table_schema` is `''`, `useAsDefault` is 1, and — the arm that matters — the
  embedded QML's categories are compared against **this item's own**
  `classification:classes`, so a vector legend that disagrees with the raster of the same
  ground is refused. Absolute literals (`STYLED_GPKGS`, `EXPECTED_STYLE_CATEGORIES`),
  matching the file's existing convention, and it refuses if it opened nothing.
- The comparison has to translate: the producer writes the vector's `transition` column
  with an ASCII arrow and the RAT's titles with U+2192. Both deliberate, so the check
  converts rather than assuming they match.
- **The first restore-the-bug run was a false pass, and checking the message is what
  caught it.** All five mutations exited 1, but none printed a style message: mutating the
  GeoPackage changes its bytes, so `check_checksums` fired first and short-circuited. The
  proofs only mean anything with `item_create.py` re-run in between so the checksums match.
- Six arms, each fired for its own reason after that fix: NULL `f_table_schema`, a missing
  row, no table at all, `useAsDefault = 0`, a colour disagreeing with the raster, and a
  category the raster does not name.
- One of those six needed a second attempt too: ElementTree escapes the arrow as `-&gt;`
  in the raw file, so a plain string replace on `styleQML` matched nothing and the test
  silently mutated nothing. A test artifact, not a code defect — the validator parses the
  XML and sees the unescaped value.
- Full `WSG=kotl Rscript scripts/test_pipeline.R` green end to end, and all three
  standalone checks pass on both arms.

### Known limitation, stated rather than papered over

`check_checksums`'s cross-item asset-key equality check cannot discriminate on a
single-item tree: with one item, the largest observed key set IS that item's set. The
three style keys were verified present by the absolute count in `test_pipeline.R` (10) and
by per-key assertions, which is the pairing this repo already prescribes for that blind
spot (#23). A full `run_pipeline.sh` over all rostered groups is what exercises the
cross-item arm, and that happens in #26.

### Phase 5 addendum — the arm a single-group fixture could not reach

Ran the smoke test on **MORR**, the multi-target group, after KOTL passed. It carries 24
styled layers per item against KOTL's 8, and three layer shapes KOTL has none of:
`classified_<sp>_<scen>_<year>_patches`, `<sp>_ff0N_by_blue_line_key` and
`<sp>_ff04_by_gnis_name`. The style mapping handled all of them, and both MORR items
built with 10 assets and validated clean — which also exercises the cross-item asset-key
check with more than one item for the first time.

Checking those layers in QGIS surfaced a property nothing structural could see: **a style
can be present, well-formed, load cleanly and render nothing**, if it categorizes on a
column the layer lacks or on values none of its features carry. Every existing arm passes
in that state.

Added it to `check_layer_styles()` without needing QGIS — read the renderer's attribute
from the QML, confirm the layer has that column, and confirm at least one distinct value
in the layer falls in a category the style actually draws. Both arms proven to fire: a
style pointed at `no_such_column`, and a style with every category switched to
`render="false"` (which keeps all 9 categories, so a count-based check stays green).

Eight guard arms now restored and confirmed.

### Review round — two concurrent reviewers, 20 findings

Both read the branch at `7c41af5`. Everything below was reproduced before acting on it.

**The blocker both found, in different words: `if not cats: continue` turned "I could not
read a palette here" into "this is fine".** A style whose renderer is `nullSymbol` (a real
QGIS renderer that draws nothing) or `singleSymbol` skipped the palette check, the category
count and the renders-blank arm — every classified layer in every item could have drawn
nothing, green. Closed by asserting the expected renderer per style, keyed off `styleName`.

**`floodplain.qml` had no content check at all.** Nine layers per item on some groups, and
the only assertions were about loading. A white fill, `alpha="0"`, or fill and outline both
`no` all passed. Closed with `_single_symbol_paints()`.

**A false refusal that would have blocked a correct release.** The renders-blank arm asked
whether the style draws any value the layer holds. For `transition`, 64 of 72 categories
ship off by design, so a watershed with no Trees-origin change is a correct dataset with a
correct style and was refused. Measured margin across the 48 staged transition layers: the
thinnest was 3 distinct Trees-origin values. Split into two properties — every value has a
category (a style property, both kinds) and at least one is drawn (only where all categories
ship on, i.e. classified). Both directions re-proven.

**The style assets had no absolute assertion in the release gate.** `check_checksums`
compares each item's key set against the largest one it saw, so three keys lost from every
item is uniform and invisible; the only absolute count lived in the smoke test, which
`catalogue_release.sh` never runs. Added `EXPECTED_STYLE_ASSETS` to the validator, with
`roles` and href checks.

**Three copies of one artifact, no guard tying any pair.** `styles/x.qml`, the copy beside
the assets, and the blob inside the GeoPackage. A one-word edit to `STYLE_ASSETS` would
publish the wrong style under the right key with href, checksum and size all agreeing.
All three are now compared.

Also fixed: `present & drawn` was an intersection test, so one renamed class of nine passed
— now coverage; a NULL `styleQML` raised an uncaught `ParseError` instead of a named
problem; `f_geometry_column` was written from a fallback and never validated; the classified
palette was merged across years, hiding a per-year bug; `kind` duplicated the writer's
mapping rule and is now read from `styleName`; `read_text`/`write_text` had no `encoding=`;
the drift check ran in nothing and is now a pipeline step; the docstrings described the
single-species layer set.

**11 guard arms restored and confirmed to fire**, plus the false-refusal case confirmed to
be accepted and its genuine counterpart still refused. `check_layer_styles` runs in 0.7 s
over all 23 items, so none of this is a cost.

Declined: the S3 object content type for `.qml` will be `binary/octet-stream` because
`aws s3 sync` cannot set per-extension types. The STAC declaration is the authoritative one
and it is correct.
