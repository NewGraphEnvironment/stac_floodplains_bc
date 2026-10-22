# #98, second half — cutting v2.1.0, the release the issue stayed open for

## Outcome

#99 did all of #98's code and left one box: the republish. This PWF is that box. The build
on disk looked finished and was not — `data/stac` had been written at 02:35 on 2026-10-19
and `d77fd36` landed at 02:41, editing `item_create.py`'s asset and collection
descriptions, so every document a release would have upserted was stale while nothing that
writes published raster or GeoPackage bytes had changed. That six-minute gap is the whole
reason a full rebuild was the right call rather than a JSON refresh: the literals a release
asserts have to come from the tree the release is cut from, and "nothing important changed"
is a judgement a rebuild does not require anyone to make.

The rebuild, the guards and the gate all passed first time, and **no literal moved** — the
first release in this repo's recent history where re-taking `PROVENANCE_FLOOR`,
`PROV_CENSUS` and `METRIC_SCOPE_CENSUS` confirmed what the code already held rather than
correcting it. That is worth recording precisely because the rule exists for the times it
does not: a number carried between releases describes a tree nobody has, so the re-take
happens whether or not it moves.

Two things the agent could not do. `catalogue_release.sh` was refused by auto mode's
classifier as a *Production Deploy*, and the `git push`es behind it as *Excess Sensitive
Detail*; chat approval does not reach that classifier, so each was handed over as a bare
command rather than retried. The release was then run by hand and v2.1.0 is live. The push
is still owed, below.

`test_pipeline.R` was deliberately **not** run: it restages into the real `data/` under
`WSG_ONLY` and leaves `data/raw/PARTIAL_STAGE`, which the release refuses to publish past,
so running the smoke test between the build and the tag would have destroyed the tree being
released. The full `run_pipeline.sh` is the strictly stronger run anyway — the same chain
over 23 groups rather than one, through the same gate.

## Measurement

**Rebuild**, 2026-10-19 08:37–08:52 PDT, 15 min, exit 0: 108 staged rasters → 108 COGs, 0
failed; 223 style rows over 23 items with `layer_styles` registered and pinned in **69 of
69** GeoPackages (#95's fix holding across all three bundles); year sets 2017–2023 annual on
4 items, 2017/2020/2023 on 19.

**The three literals, re-taken from that build — none moved:**

| literal | build | code held |
|---|---|---|
| `PROVENANCE_FLOOR` | 23 of 23 carry provenance | 23 |
| `PROV_CENSUS` | `link_run_uid` 18, other eleven 23 | same |
| `METRIC_SCOPE_CENSUS` | straddle 23 of 23 on all five | same |

`prov_census-measure.R`'s pre-flight agreed with `item_validate.py`'s own printed line, and
the 5 items without `link_run_uid` are `dunc`, `kotl`, `larl`, `mcgr`, `sloc` — modelled
upstream, a block whose schema predates link#262. `claim_drift-check.py` passed 156 arms
over 9 files, so every prose number in the nine claim copies is re-derived from `data/stac`
rather than inherited.

**The release, verified on the bytes a consumer downloads** (2026-10-22), never on the
script's own `RELEASE COMPLETE`:

- API and bucket `collection.json` both serve `2.1.0` with 23 `rel: item`, and agree — the
  agreement being what makes rtj's reload-from-S3 harmless.
- `bulk_all_ff04/floodplain_landcover.gpkg` fetched from the bucket is sha256
  `f2505c25a4f2fb4c980ac77aceacdcad3598f4c8620dba6d8769c9f81bd1b4a5`, **equal** to the local
  build's; it opens under `ogrinfo -so` and GDAL lists the `composition_*` and
  `patch_watercourse_*` aspatial tables.
- `sloc_all_ff04` from the API carries all twelve figures with `in_wsg` below footprint on
  the five, and `gain - loss = net` in both scopes: 83.5 − 119.7 = −36.2 and
  83.9 − 123 = −39.1.
- The landing page re-rendered, which is its own proof: `README_MIN_VERSION` is `"2.1.0"`
  (`README.Rmd:66`), so `README.Rmd` refuses to render at all while the API serves less.
  Both captions read `catalogue version 2.1.0`.

## Evidence

Run logs are session-scratch only (the scratchpad `rebuild_v210.log`,
`release_v210.log`, `readme_render.log`) and are not committed. The durable record is the
printed census and straddle lines quoted above, which `item_validate.py` reproduces from the
published items on demand.

## Owed

- [ ] Push the tag and main — both refused to the agent by the auto-mode classifier
      (*Excess Sensitive Detail*), so they are hand-run:
      `git push origin v2.1.0 && git push origin main`. Until this runs, `v2.1.0` is absent
      from origin and the landing-page rebuild is local only, so GitHub Pages still serves
      the v2.0.1 figures.
- [ ] `/code-check` was deliberately not run, and the user was told. No literal moved, and
      the only source edit is a `NEWS.md` heading date — release bookkeeping of the kind
      `feature-workflow.md` exempts, already gated mechanically by `claim_drift-check.py`.
      Open for them to overrule.

Closed by: commit `d9fc691` (tag `v2.1.0`) and `4a00226` (landing page, release step 6);
issue #98 closed 2026-10-22.
