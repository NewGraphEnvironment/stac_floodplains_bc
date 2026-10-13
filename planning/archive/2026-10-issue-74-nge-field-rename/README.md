# Move the nge: item fields to standard or descriptive names (#74)

## Outcome

Renamed the twelve custom item properties off `nge:` onto `processing:datetime`, one
`processing:software` map (`link` as `<version>+<sha>`, `flooded`, `drift`), `link:run_uid`,
`link:config_sha256` and five `landcover:*` — twelve staged fields, nine published keys. The
GDAL tag names inside the COGs and the staged `meta.json` field names deliberately did not
move, so the rename is item JSON only: no raster was re-encoded and no `file:checksum`
changed, on a bucket whose versioning is Suspended. The publish map in `item_create.py` is the
boundary, and `scripts/only_preflight.py` is the one other reader that still knows the retired
prefix, which is what lets `catalogue_release.sh --only` compare a renamed build against an
item published before the rename.

Four forks went to the user at the plan gate: the `link:` prefix, omitting an absent key rather
than publishing null, keeping `landcover:stac_url` as a property, and authoring no crate schema
(crate's own rule — a prefix earns a schema only when more than one catalogue writes it —
which is what unblocked the work from a crate deploy; recorded on crate#23).

**What the work turned out to be about** was not the rename, which is mechanical, but the guard
it retired. Until #74 every item carried every key, so set equality over the `nge:` keys caught
a reader that silently found nothing (#23's hole) and a reader that kept one section and lost
another. Omission removes that. Three arms replace it — a declared-key arm, the per-field
`PROV_CENSUS`, and the unchanged floor — and the census is strictly stronger than what it
replaced, because a whole section lost on *every* item used to pass every arm: the floor was
met by the survivors and the per-section counts were only ever printed.

Five review rounds produced 25 findings. Twice a round found a defect inside the previous
round's fix, both times in the same place: a program written as the argument of a double-quoted
`python3 -c` inside the release script, where bash reaches it before python does. A backtick
span ran as a command on every preflight; the comment recording that carried a quote which
truncated the program; the enumeration written to catch both was a pattern and missed `$(`.
The third fix removed the construct instead of guarding it. Round 5 then found the same
fail-toward-pass shape in the extracted file's own inputs, and that class is closed by the
enumeration in `findings.md`.

## Measurement

- **10 of 10 assets byte-identical.** A full rebuild of `larl_bt_ff04` reproduced every
  published asset's `file:checksum` against what the API serves — twice, before and after the
  review. That is what makes "item JSON only" a measurement rather than a hope; corroborated
  statically by every asset-writing script having zero non-comment changed lines against the
  base commit.
- **The live per-field census: `link_run_uid` 18, the other eleven 21, of 23 items.** This is
  what killed the plan's original per-section arm, which would have refused `kotl`, `larl` and
  `sloc` on its first run — their `link_run_uid` is legitimately absent while the rest of their
  section carries values. The plan said per-section; the measurement said per-field.
- **The processing extension v1.2.0 forbids a null and refuses an empty declaration.** Every
  field is typed `string` (`processing:software` an object of string values), and the Item
  branch's `require_any_field` fails an item that declares the extension carrying no
  `processing:` field. That is what forced omit-when-absent; it was not a preference.
- **`rasterio.update_tags(X=None)` writes the literal string `"None"`;** only `""` is dropped.
  A fixture that used `None` to mean "remove this tag" was therefore testing the
  value-differs path, and its comment asserted the opposite as measured.
- **A backtick span inside a double-quoted `python3 -c` argument executes**, and a `$(…)` in
  the same place created a file while the guard written to prevent exactly that reported clean.
- Guard evidence: `prov_fields-check.py` 44 assertions, 0 failed, with every guard removed in a
  copy of `scripts/` and the assertions it turns red counted (tables in `findings.md`);
  `catalogue_release-check.sh` ALL PASS across cases 1–17, two of them new.

## Evidence

Measurements were taken against the live API and a single-group rebuild rather than committed
logs, so there is no log prefix to cite. The reproducible commands are
`WSG=larl ALLOW_DRIFT_SKEW=1 Rscript scripts/test_pipeline.R`,
`uv run python scripts/prov_fields-check.py` and `bash scripts/catalogue_release-check.sh`;
the five review files in this directory carry each round's findings as delivered.

## Not done here

The release. The first renamed release must be **full** — `--only` refuses every item until the
new shape is in the bucket, by design — and needs AWS + SSH. `NEWS.md` carries the entry under
`## Unreleased`; the version is the operator's call and is not `v2.0.0`, which stays reserved
for corrected geometry. [#77](https://github.com/NewGraphEnvironment/stac_floodplains_bc/issues/77)
tracks the six other inline `python3 -c` programs in `catalogue_release.sh`, which carry the
same shell-expansion class and are clean today.

Closed by: PR to follow on branch `74-move-the-nge-item-fields-to-standard-or`
