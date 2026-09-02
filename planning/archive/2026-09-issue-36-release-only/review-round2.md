# Review round 2 — `--only` live-item read-back (#36)

Scope: the delta since round 1 — the step-5 read-back block in `scripts/catalogue_release.sh`
(lines 329–347), the `*/items/*` curl-shim branch, `FAKE_LIVE_ITEM_STALE`, case 6, the case-1
`expect_out`, and `fail()` printing the run tail in `scripts/catalogue_release-check.sh`, plus the
docs in `scripts/README.md`, `scripts/test_pipeline.R`, `CLAUDE.md`. Both scripts were read in full.
Round 1's verdict on the pre-existing paths is not re-litigated.

## Findings

- **[fragile] `scripts/catalogue_release.sh:329–347`** — the read-back proves less than its
  comment and its success line claim. It compares the live row's `file:checksum` for **one** asset,
  the probe asset — which is the largest local asset, `floodplain_landcover.gpkg`. That asset is
  copied from upstream and (per CLAUDE.md, `fp_gpkg.R`'s `OGR_CURRENT_DATE` pin) is byte-stable
  across rebuilds by design. So for the pilot this flag exists for — #33 COG layout, #34/#35 RAT
  labels, i.e. **COG-only changes** — the previous live row and the new build carry the *same*
  checksum for the probe asset, and a row that was never upserted is indistinguishable from one that
  was. The guard then prints `pgstac serves the checksum just built` and `RELEASE COMPLETE`.

  Measured, not reasoned: I ran the real script through the check harness with the curl shim's
  stale mode changed to alter only `classified_2017`'s checksum in the served item (a copy of the
  check script at `<scratchpad>/stale_cog_check.sh`). Output:

  ```
  checksum probe (aaaa_ch_ff04): verified against S3 — 1220222726987615…
  live item (aaaa_ch_ff04): pgstac serves the checksum just built — 1220222726987615…
  RELEASE COMPLETE — aaaa_ch_ff04 republished; collection unchanged at 2 items
  ```

  Exit 0. This is the "proxy assertion" class from the conventions: the quantity that differs
  between old row and new row is the COG checksums, and the assertion samples the one asset that
  does not differ. No data loss — the S3 bytes and the JSON on S3 are correct — but the release
  reports a fact about pgstac it has not established, which is the one fact `--only`'s step 5 was
  extended to establish.

  Fix, same GET, no extra cost: compare **every** asset's `href → file:checksum` between the live
  item and the local build (dict equality in the python, or print `href checksum` lines for both and
  compare sorted). Then a stale row is only invisible when *nothing* in the item changed, which is
  harmless. Keep the `[ -n ... ]` guard so an empty result still fails.

- **[fragile] `scripts/catalogue_release-check.sh:114` (case 6)** — the shim's `sed … /g` stales
  every asset's checksum at once, so case 6 cannot tell "the read-back compared the probe asset"
  from "the read-back compared any asset", and — the direction that matters — cannot reach the
  false-pass above at all. After fixing the script, make the fixture discriminate: stale one asset
  that is **not** the largest (`classified_2017.tif`), leaving `floodplain_landcover.gpkg` correct.
  With the current one-asset read-back that fixture fails all three case-6 assertions (measured,
  above); with an all-assets compare it passes. That is the restore-the-bug check for the fix.

## Probed and clean

Everything below was executed, not read.

| probe | result |
|---|---|
| `bash scripts/catalogue_release-check.sh` (bash 5.3.9) | ALL PASS, 36/36, rc=0 |
| same under `/bin/bash` 3.2.57 | ALL PASS, rc=0 — `${url##*/}`, `${x:0:16}`, `${x:-none}` all 3.2-safe |
| read-back: curl `-f` fails (404, network) | python gets empty stdin → JSONDecodeError → pipeline non-zero under pipefail → `live_expect=""` → **fail** |
| read-back: 200 with HTML / non-JSON body | JSONDecodeError → **fail** |
| read-back: 200 with JSON lacking `assets` | KeyError → exit 1 → **fail** |
| read-back: item present, probe href absent | `next(…, '')` → empty → **fail** |
| read-back: asset present, no `file:checksum` | `.get(…, '')` → empty → **fail** |
| read-back: truncated body + curl non-zero | JSONDecodeError → **fail** |
| `$probe_href` containing `'` | python SyntaxError → exit 1 → **fail** (abort, not false pass). Reachable only via a filename with `'`; hrefs are `S3_BASE/<id>/<fixed name>` from `05_stac_register.py:151`, and `$ONLY` is class-constrained, so not reachable from real input. Same interpolation shape as the pre-existing `probe_expect` at line 318. |
| `|| live_expect=""` under `set -e` | the `\|\|` makes the failed assignment non-fatal; the compare then fails. Direction is abort in every case. |
| same asset as the S3 probe? | yes — both the lookup (`a['href'] == '$probe_href'`) and the reference (`$probe_expect`) are the S3 probe's own values |
| shim ordering | `-w` check precedes `*/items/*`, so the 200-probe of the item endpoint returns `200` and the read-back gets the fixture JSON; S3 hrefs do not match `*/items/*` |
| `fail()` tail | `$OUT` always exists when `fail()` can be reached (every assertion follows a `run_release`); a missing file would abort loudly under pipefail, not hide a failure |
| case-6 sed not matching (e.g. separator change) | serves the correct JSON → case 6 goes red — fails loud |

## Notes, not findings

- `scripts/README.md` "Pilot" table, row `5 verify`: still lists "item endpoint 200; membership
  byte-identical; size + checksum probes" and does not mention the new live-item read-back. Worth
  one clause when the read-back is reworked, so the doc describes what the step asserts.
- The check header's case-6 line says "serving the OLD checksum"; the shim serves a corrupted one,
  not the old one. Fine as prose, but if the fixture is changed per the finding above the line will
  become literally true and can stay.
