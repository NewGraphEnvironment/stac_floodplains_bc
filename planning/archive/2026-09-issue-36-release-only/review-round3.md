# Review round 3 — the all-assets read-back fix (#36)

Scope: the only code changed since round 2 — `scripts/catalogue_release.sh:329–353` (the
"prove the pgstac ROW is the one just built" block) and case 6 / the `*/items/*` shim branch in
`scripts/catalogue_release-check.sh` — plus a re-read of both scripts in full against the
Shell Scripts checklist. Rounds 1 and 2 were read; their accepted items are not re-flagged.

## Findings

- **[fragile] `scripts/catalogue_release.sh:329–347`** — the read-back still asserts a proxy
  for "the row is the one just built". It compares only `href -> file:checksum`, so it is blind
  to every field of the item that changes **without** changing asset bytes, and this catalogue
  has three such fields that are exactly what a republish is likely to carry:

  | field | where | source |
  |---|---|---|
  | `classification:classes` | every raster asset dict | `05_stac_register.py:231,249` (#34/#35) |
  | `nge:*` provenance | `properties` | `05_stac_register.py:314` (#17) |
  | `gross_loss_ha` / `gross_gain_ha` / `net_ha` | `properties` | `05_stac_register.py:296–298` (#26) |

  The gpkg checksums are pinned byte-stable across rebuilds (`OGR_CURRENT_DATE`, CLAUDE.md), and a
  COG rebuild from unchanged inputs is deterministic, so a republish that fixes a class label, a
  provenance value, or a loss number — with no byte change — reads back `OK 2` from a row that
  was never upserted, and prints `RELEASE COMPLETE`. Measured by driving the exact python snippet
  (extracted verbatim) with adversarial live/built pairs:

  ```
  identical row                                              OK 2   -> PASS
  extra live asset (build dropped one)                       OK 2   -> PASS   <- stale row passes
  same hrefs+checksums, live lacks classification:classes    OK 2   -> PASS   <- stale row passes
  same assets, live properties differ (nge:net_ha)           OK 2   -> PASS   <- stale row passes
  live keyed differently, same hrefs                         OK 2   -> PASS
  live asset missing href                                    STALE classified_2017.tif
  live asset missing file:checksum                           STALE classified_2017.tif
  live has no assets key                                     rc=1 ''            -> FAIL
  live assets empty                                          STALE <both>       -> FAIL
  empty body (curl -f failed) / html body                    rc=1 ''            -> FAIL
  BUILT asset lacks file:checksum                            rc=1 '' (KeyError) -> FAIL
  BUILT has no assets                                        NOASSETS           -> FAIL
  ```

  The abort direction is sound in every case probed — `live_state` is empty on any failure and
  the `*` arm fires, and `NOASSETS`/`STALE` never match `"OK "*`. The pass direction is the gap.
  It is **not** a false pass for the pilot this flag was written for (#33/#34/#35 all change COG
  bytes), which is why this is fragile rather than a bug — but the block's comment ("prove the
  pgstac ROW is the one just built") and the README row ("the only proof the pgstac row changed")
  claim the general property, and the *next* use of `--only` is the metadata-only kind.

  Fix, same GET, two lines: compare the whole `assets` dict and `properties` instead of a
  projection of them —
  ```python
  live = json.load(sys.stdin); built = json.load(open('$STAC_DIR/$ONLY.json'))
  same = live['assets'] == built['assets'] and live['properties'] == built['properties']
  ```
  (keep `NOASSETS` on empty built assets; on mismatch print which top-level keys differ). This
  also closes the extra-live-asset case (a dropped asset lingering in the row), which a
  `want`-only iteration cannot see. pgstac stores `properties`/`assets` in the item `content`
  and hydrates them back unchanged, and stac-fastapi rewrites only `links`, so equality should
  hold — but that is a claim about the consumer, so **verify it once against the live API before
  relying on it**: `curl $API/items/<id>` vs the same item's JSON fetched from S3 (not the local
  build, which is ahead of the live catalogue). If some field is normalised on the way out,
  exclude that one field by name rather than falling back to checksums. Then add a case 7 that
  stales only a property (`sed` on `nge:` or `net_ha` in the served row) so the fixture reaches
  this direction too.

## Probed and clean

Everything below was executed, not read.

| probe | result |
|---|---|
| `bash scripts/catalogue_release-check.sh` (bash 5.3.9) | ALL PASS, 37/37, rc=0 |
| same under `/bin/bash` 3.2.57 | ALL PASS, rc=0 — `"OK "*` case pattern and `${live_state#OK }` are 3.2-safe |
| **restore the round-2 bug** (compare only `$probe_href`) in a scratch copy of `scripts/`, run the check | case 6 goes **red** on all three assertions and case 1's `all 2` assertion goes red (rc=4); the run prints `pgstac serves all 1 asset checksums` then `RELEASE COMPLETE`. So the fixture reaches the compare on the non-probe asset and the guard is not decoration. |
| case 6 fixture: first asset is `classified_2017.tif`, probe is the largest (`floodplain_landcover.gpkg`, 40× vs 3×) | confirmed by the red run above and by `STALE classified_2017.tif` (not both names) in the green run |
| `sed` with no `/g` on the one-line `json.dump` output | stales exactly the first `"file:checksum": "1220` — the first asset; separator `": "` is json.dump's default, and a non-match would serve the correct JSON and turn case 6 red (fails loud) |
| built asset with no `file:checksum` | KeyError → traceback on stderr, nothing on stdout, pipeline non-zero under pipefail → `|| live_state=""` → `*` arm → `fail=1`. Abort, not skip. |
| `case` on empty / traceback / `NOASSETS` | all fall to `*`; the message prints `read-back failed` for the empty case. None can match `"OK "*`. |
| python prints `OK` but curl exits non-zero (partial body after a 200) | pipefail makes the substitution non-zero → `live_state=""` → fail. Safe direction. |
| a CDN/cache in front of the API serving the old row | would read as STALE → abort, not a false pass |
| shim routing for the read-back call (`-sf --max-time 60 <url>`) | no `-w`, no `-*I*` match (`--max-time` has no capital I), `http*` sets url, `*/items/*` arm serves the fixture JSON; S3 hrefs never match `*/items/*` |
| case 6 assertion pattern is a substring of the both-assets message | a compare that staled everything would pass case 6 but fail case 1 (`all 2` absent), so the pair discriminates |
| `FAKE_LIVE_ITEM_STALE` always exported (possibly empty) | `[ -n "${…:-}" ]` handles both; `STALE=""` reset after case 6 |

## Not flagged

- Round 1's items 1–4 and round 2's notes stand. The README "5 verify" row now describes the
  read-back; its "every asset checksum … the only proof the pgstac row changed" wording is the
  over-claim named in the finding above and should move with the fix.
- The live-row read-back runs after the S3 probes, so a stale row is reported alongside — not
  instead of — a checksum-probe failure. Fine.
