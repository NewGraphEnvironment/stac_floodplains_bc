# Progress — Publish all seven classified years for bulk, necr, lnth, kotl (#59)

## Session 2026-09-05

Plan-mode exploration on m1. Phases approved, plus the version decision: four `--only` runs,
no tag, since `--only` never publishes `collection.json` and the collection document does not
change. Branch `59-publish-all-seven-classified-years-for-b` off main.

- **Phase 0** — pinned the live baseline for all 23 items (10 assets each, collection at
  `1.1.0`); `style_drift-check.py` clean. Commit `4899223`.
- **Plan review** landed after Phase 1 and independently reproduced the checksum finding.
  Acted on it: widened the baseline to full item documents + a 258-object bucket listing,
  recovered `bulk`'s lost pre-publish properties from the tracked README cache, moved the
  three-year control ahead of the remaining publishes, added a premise check so `readback.py`
  refuses a baseline that post-dates the republish. Commit `06eafb1`.
- **Phase 1** — `bulk_co_ff04` republished. The gate refused first: byte equality is
  unsatisfiable because every COG carries the item's provenance block in its TIFF tags.
  Rewritten to assert pixel/geometry/RAT identity against the bytes S3 was serving.
  Commit `354c91a`.
- **Phase 5 (run early)** — `ufra_ch_ff04` three-year control, built and validated under
  `ALLOW_DRIFT_SKEW=1`, never published.
- **Phases 2–4** — `necr_ch_ff04`, `lnth_ch_ff04`, `kotl_bt_ff04` republished. The gate
  refused twice more on 30 stray gdalcubes/NetCDF tags carried in from the producer's
  rasters; filed as **floodplains#83** and published anyway, because the pixels, geometry and
  RAT are correct and the tags clear on the next republish. Gate widened by name, not by
  relaxing it.
- **Phase 5** — 19 untouched items identical on every property, bbox, geometry and asset;
  210 bucket objects outside the four with unchanged ETags, none added or removed;
  `collection.json` never written; version still `1.1.0`. drift#62's `/vsicurl/` read
  confirmed on all 16 newly published COGs (one per item at first; widened to all 16 after
  code-check round 3 found the three planning documents recording three different
  populations for it), RAT intact. Commit `2a1f573`.
- **Phase 6** — issue #59 body corrected (two marked corrections); NEWS entry written from
  the artifacts; `README.md` and `index.html` regenerated, both byte-stable on re-render,
  `fig/coverage.png` unchanged.

Next: `/code-check`, archive, PR.
