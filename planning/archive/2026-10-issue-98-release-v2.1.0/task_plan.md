# Task: Publish v2.1.0 — the last box on #98

**The catalogue IS released and verified. What remains is bookkeeping behind it.**
Measured 2026-10-22: API and bucket `collection.json` both serve `2.1.0` with 23
`rel: item`, they agree, and a published GeoPackage is byte-identical to the local build.

Issue #98's one remaining box is the republish; everything else closed in #99 (`44dc70c`).
The box is **done in substance** — tick it when the items below land.

**No feature branch.** `catalogue_release.sh` wanted HEAD exactly at a `vX.Y.Z` tag with a
clean tracked tree, so the PWF was committed before the tag and these boxes tick after.
That constraint is now **spent** — the release has run, so the tree may move freely.

## Phase 1: Rebuild the tree the release is cut from — DONE

- [x] `bash scripts/run_pipeline.sh` — 2026-10-19 08:37–08:52 PDT, exit 0, 15 min
- [x] 23 items + collection, run's own validate green; 108 COGs, 0 failed
- [x] Build's twelve provenance counts and metric-scope line recorded (findings.md)

## Phase 2: Hand-run guards, and re-take the literals — DONE

- [x] `claim_drift-check.py` — 156 arms over 9 files, 0 problems
- [x] `attribution_drift-check.py` — exit 0
- [x] `prov_census-measure.R` — agrees with the build's own line
- [x] Literals re-taken: **none moved** (floor 23, `link_run_uid` 18 / other eleven 23,
      straddle 23 of 23 on all five)
- [x] `item_validate.py --base data/stac --expect 23 --expect-provenance 23` — exit 0,
      floor and per-field census asserted
- [x] `test_pipeline.R` skipped deliberately — it restages into the real `data/` and would
      have destroyed the build (findings.md)

## Phase 3: Date, commit, tag — DONE

- [x] PWF committed (`33b30b0`)
- [x] `NEWS.md` dated `## v2.1.0 (2026-10-19)`, committed (`d9fc691`)
- [x] `git tag v2.1.0` on `d9fc691`, local

## Phase 4: Release — DONE (run by airvine, 2026-10-19 or later)

- [x] `catalogue_release.sh` — refused to the agent by auto mode's classifier
      (*Production Deploy*), run by the user instead
- [x] API serves `2.1.0`; bucket `collection.json` serves `2.1.0` with 23 `rel: item`
- [x] Verified on the bytes a consumer downloads, 2026-10-22:
      `bulk_all_ff04/floodplain_landcover.gpkg` sha256
      `f2505c25a4f2fb4c980ac77aceacdcad3598f4c8620dba6d8769c9f81bd1b4a5` from the bucket
      **equals** the local build's; `ogrinfo -so` opens it and GDAL lists the aspatial
      tables
- [x] `sloc_all_ff04` from the API carries all twelve figures, `in_wsg` below footprint on
      the five, `gain - loss = net` in both scopes (83.5 − 119.7 = −36.2;
      83.9 − 123 = −39.1)

## Phase 5: Post-release — THE REMAINING WORK

- [ ] **Push the tag and main.** Both refused to the agent by the auto-mode classifier
      (*Excess Sensitive Detail*), so they are hand-run. 2 commits unpushed
      (`33b30b0`, `d9fc691`); `v2.1.0` is absent from origin.

      ```
      cd ~/Projects/repo/stac_floodplains_bc
      git push origin v2.1.0 && git push origin main
      ```

      The tag is pushed only now because a pushed tag says the catalogue IS in this state,
      and it is.

- [x] **Release step 6 — regenerate the landing page** — DONE 2026-10-22, in this order. Reversed, the site
      publishes the previous release's figures: the `github_document` render is the one
      that refreshes `data/readme_items.rds` and `fig/coverage.png` from the live API, and
      `index.html` reads the cache it leaves. `README.md` and `index.html` currently
      describe the **v2.0.1** catalogue (last rebuilt 2026-10-17).

      ```
      cd ~/Projects/repo/stac_floodplains_bc
      Rscript -e 'rmarkdown::render("README.Rmd", "github_document", params = list(rmd_on = FALSE, update_query = TRUE))'
      Rscript -e 'rmarkdown::render("README.Rmd", "html_document", output_file = "index.html", params = list(rmd_on = TRUE, update_query = FALSE))'
      ```

      Both renders exit 0 and both captions read `catalogue version 2.1.0`. This could not
      have been run before the release: `README_MIN_VERSION <- "2.1.0"` (`README.Rmd:66`)
      refuses any render while the API serves less, so a **successful render is itself proof
      the release landed**.

- [ ] Tick #98's last box and close it, naming v2.1.0. The trailer belongs on the
      NEWS-date commit the tag sits on (`d9fc691`).
- [ ] `/planning-archive` -> `planning/archive/2026-10-issue-98-release-v2.1.0`
      (**not** `2026-10-issue-98-publish-in-wsg`, which already exists from #99).

## Validation

- [x] Tests pass — the full rebuild's own gate, `test_pipeline.R` skipped with cause
- [ ] `/code-check` — **deliberately not run**, and flagged to the user: no literal moved,
      the only edit is a NEWS heading date, which is release bookkeeping of the kind
      `feature-workflow.md` exempts and which `claim_drift-check.py` already gates
      mechanically. Open for them to overrule.
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
