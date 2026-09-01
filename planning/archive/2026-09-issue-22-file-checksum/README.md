## Outcome

Every published asset now carries `file:checksum` and `file:size` (STAC file extension v2.1.0) —
120 of 120 live, verified end to end: fetch an item from the API, download the object from S3 with
no local state, recompute sha256, and it matches the published multihash. That is the property the
issue existed to create, and it is checked rather than asserted.

**The sequencing was the point.** `flooded` 0.5.0 corrected a bankfull units defect, so every
published floodplain is over-mapped (#26) and all 20 items will be rebuilt. Landing checksums
*first* gives the current vintage an identity, so the rebuild visibly changes the checksum. Landing
them after would have made checksums and corrected geometry appear in the same moment —
indistinguishable, which is exactly the confusion #26 describes.

**The safety-critical finding was about what NOT to run.** Upstream `$FLOODPLAINS_DATA` is
mid-remodel — MORR, BULK, KISP, NECR and PARS are corrected while the rest are not (verified by
byte-comparing upstream GeoPackages against the staged copies). `run_pipeline.sh` would therefore
have published a **mixed-vintage catalogue** with nothing in the metadata to tell the two apart,
since no item carries a `flooded` version (#17 is blocked upstream). This was a JSON-only rebuild,
proven by md5-ing all 120 assets before and after.

**The schema is not a guard.** `file:checksum`'s pattern is `^[a-f0-9]+$`, so a bare sha256 with no
`1220` multihash prefix validates cleanly — confirmed directly by calling `pystac.validate()` on
one. So does a well-formed checksum of the wrong bytes. Everything that actually matters here had to
be asserted in code, and the negative tests exist to prove the assertions fire.

Review then found **four silent-success holes** in that guard, each the same shape — "nothing was
checked" being indistinguishable from "everything checked out":

- an item that lost an asset iterated zero times and passed; so did every item losing every asset
- the local file was resolved from `item_id` + basename, **discarding the href's directory**, so a
  wrong published prefix was verified against the correct local file and passed
- `--skip-sync` could register a checksum for bytes not on S3, because "the href resolves" no longer
  implies "the bytes match" once checksums exist

The last one is worth remembering: adding a feature **narrowed the contract of an unrelated flag**,
and nothing about that flag changed. The release verify now downloads the probe asset and compares
its real checksum, which is also what caught it in the first place.

Two implementation notes for whoever extends this. pystac's own
`FileExtension.ext(asset, add_if_missing=True)` **raises** on an unowned asset, and this generator
builds all six assets before the Item exists — so the fields go in `extra_fields`, matching how
`proj:*` was already done. And hashing at `05` is correct *only* because `02` writes the COGs and
`03` rewrites their tags in place before it; any later in-place step would silently publish wrong
checksums. That constraint is now recorded at the hash site and in `scripts/README.md`.

Costs measured, not estimated: build 4.7 s for 20 items over 673 MB; the verification guard 0.72 s.

Closed by: PR #27.
