## Outcome

`floodplains#30` taught the upstream model to write `wsg`/`species`/`scenario` into every gpkg layer
at generation time, so this issue was a **republish + verify**, not a code change — this repo does no
modelling and `01_stage.R` copies the GeoPackages whole. The same republish picked up **KISP**
(Kispiox, Skeena chinook), newly rostered upstream, taking the collection from 16 to **17 items across
16 watershed groups**. The only code change was a regression guard in `test_pipeline.R` asserting
`wsg == meta$wsg` on every layer of both published GeoPackages, plus README/scripts-README updates.

Three things are worth carrying forward. **The Plan agent asserted a false premise** — that
`floodplain.gpkg` was geometry-only — and `/code-check` disproved it; scoping the new assertion to
one GeoPackage as planned would have let a regression in the other pass green. A confident
exploration finding still needs verifying against the artifact. **Bucket versioning is Suspended and
`01_stage.R` wipes `data/{raw,stac}`**, so there is no rollback: the 16 live item JSONs were
snapshotted before publishing, and the diff afterwards proved them byte-identical on id/bbox/geometry
and all 9 numeric properties — confirming upstream changed schema only. **Verification must come from
S3 and the live API, not local staging**, which trivially passes because it is a byte copy of source;
the checks that made this issue non-silent were 17/17 gpkg `LastModified` newer than publish start,
and a property/asset sweep of the live catalog. A bare item-count probe proved insufficient — one
returned 16 minutes before another returned 17, as the M4 reload landed mid-session.

Also codified: `aws s3 sync` in `04_s3_upload.R` has no `--size-only` and that omission is
**load-bearing** (LCHL's `floodplain.gpkg` is byte-identical in size to its S3 copy, so a future
"optimization" would silently skip it). And `ogrinfo -so` appends `(Multi Polygon)` to only some
layer names — never `$`-anchor a layer-name regex.

Closed by: PR #15 (commits f8feaeb, fbd0e3a, bddfb1c). Catalog reload tracked in rtj#202.
Also closes #13 (publish KISP).
