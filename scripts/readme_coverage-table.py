#!/usr/bin/env python3
"""readme_coverage-table.py — regenerate README.md's coverage table from the LIVE API.

Usage:
    python3 scripts/readme_coverage-table.py            # prints the table to stdout
    python3 scripts/readme_coverage-table.py --write    # replaces the table in README.md

Run after every full release (#41). The table describes what the API serves, not what a
build holds, so it reads the same fielded search catalogue_release.sh uses and checks the
page is complete against the bucket's collection.json: a short page would otherwise read
as a smaller collection.

stdlib only, like the release side — no uv, no pystac.

Columns: one row per item, in the order the collection lists regions, then by watershed
group. `Floodplain (km²)` is the item's OWN scenario extent (ff04 for most, ff06 for
`morr_ch_ff06`), so the `Scenario` column is load-bearing — the collection mixes flood
factors (CLAUDE.md, "Collection model"), and a reader summing the column across scenarios
would sum different extents. The total row therefore counts the ff04 extent ONCE per
watershed group, while the tree-change totals sum every item, which is what the caption
in README.md says.
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

API_ROOT = "https://images.a11s.one"
COLLECTION = "stac-floodplains-bc"
S3_BASE = "https://stac-floodplains-bc.s3.us-west-2.amazonaws.com"
README = Path(__file__).resolve().parent.parent / "README.md"

SPECIES = {"bt": "bull trout", "ch": "chinook", "co": "coho"}
FIELDS = ["id", "properties.wsg", "properties.region", "properties.species",
          "properties.scenario", "properties.flood_factor", "properties.floodplain_ff04_km2",
          "properties.floodplain_ff06_km2", "properties.gross_loss_ha",
          "properties.gross_gain_ha", "properties.net_ha"]
# Anchors for --write: the generated block is the caption line through the total row, and
# nothing else in README.md starts either way. The caption carries every number the prose
# used to hardcode (item count, group count, regions, live version), so a re-run cannot
# leave the words above the table contradicting it.
TABLE_START = re.compile(r"^\*Generated from the live API by `scripts/readme_coverage-table\.py`")
TABLE_END = re.compile(r"^\| \*\*Total\*\* \|")


def fetch():
    body = json.dumps({"collections": [COLLECTION], "limit": 1000,
                       "fields": {"include": FIELDS}}).encode()
    req = urllib.request.Request(f"{API_ROOT}/search", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        doc = json.load(r)
    feats = doc["features"]
    # A truncated page must not pass as the collection. This API sends no numberMatched
    # (measured 2026-09-02: only numberReturned), so completeness is "no next link" — the
    # page carried everything — cross-checked against the item links in the BUCKET copy of
    # collection.json, which the release writes from the same build (the API rewrites the
    # served collection's links, so it carries none). Either disagreeing is a refusal.
    if any(l.get("rel") == "next" for l in doc.get("links", [])):
        raise SystemExit(f"search paged at {len(feats)} features — raise the limit")
    # Absolute, before the cross-check: 0 == 0 would otherwise pass and --write would
    # replace every row with a bare header.
    if not feats:
        raise SystemExit("search returned no items — refusing to write an empty table")
    with urllib.request.urlopen(f"{API_ROOT}/collections/{COLLECTION}", timeout=60) as r:
        coll = json.load(r)
    with urllib.request.urlopen(f"{S3_BASE}/collection.json", timeout=60) as r:
        bucket = json.load(r)
    n_links = sum(1 for l in bucket.get("links", []) if l.get("rel") == "item")
    if n_links != len(feats):
        raise SystemExit(f"search returned {len(feats)} items but the bucket collection links {n_links}")
    return feats, coll.get("version", "MISSING")


def fmt_int(x, signed=False):
    v = round(x)
    s = f"{abs(v):,}"
    if signed:
        return ("+" if v >= 0 else "-") + s
    return ("-" if v < 0 else "") + s


def table(feats, version):
    rows = []
    for f in feats:
        p = f["properties"]
        ff = p["flood_factor"]
        km2 = p[f"floodplain_ff0{ff}_km2"]
        rows.append((p["region"], p["wsg"], p["species"], ff, km2,
                     p["gross_loss_ha"], p["gross_gain_ha"], p["net_ha"]))
    rows.sort(key=lambda r: (r[0], r[1], r[3], r[2]))
    regions = sorted({r[0] for r in rows})
    n_wsg = len({r[1] for r in rows})
    out = [f"*Generated from the live API by `scripts/readme_coverage-table.py`: {len(rows)} items "
           f"across {n_wsg} watershed groups in {len(regions)} regions "
           f"({', '.join(r.title() for r in regions)}), catalogue version {version}.*",
           "",
           "| WSG | Region | Species | Scenario | Floodplain (km²) | Gross loss (ha) | Gross gain (ha) | Net (ha) |",
           "|----|----|----|----|----:|----:|----:|----:|"]
    for region, wsg, sp, ff, km2, loss, gain, net in rows:
        out.append(f"| {wsg} | {region.title()} | {SPECIES.get(sp, sp)} | ff0{ff} | {fmt_int(km2)} | "
                   f"{fmt_int(loss)} | {fmt_int(gain)} | {fmt_int(net, signed=True)} |")
    # ff04 extent once per WSG: MORR's two items share one physical floodplain. Asserted,
    # not assumed — the search has no sortby, so if a group's items ever disagreed the
    # total would depend on response order and --write would stop being idempotent.
    ff04_by_wsg = {}
    for f in feats:
        p = f["properties"]
        seen = ff04_by_wsg.setdefault(p["wsg"], p["floodplain_ff04_km2"])
        if seen != p["floodplain_ff04_km2"]:
            raise SystemExit(f"{p['wsg']}: items disagree on floodplain_ff04_km2 "
                             f"({seen} vs {p['floodplain_ff04_km2']}) — the once-per-group total needs a rule")
    total_km2 = sum(ff04_by_wsg.values())
    total_loss = sum(r[5] for r in rows)
    total_gain = sum(r[6] for r in rows)
    total_net = sum(r[7] for r in rows)
    out.append(f"| **Total** | | | | **{fmt_int(total_km2)}** | **{fmt_int(total_loss)}** | "
               f"**{fmt_int(total_gain)}** | **{fmt_int(total_net, signed=True)}** |")
    return "\n".join(out), len(rows), n_wsg


def write(text):
    lines = README.read_text().splitlines()
    starts = [i for i, l in enumerate(lines) if TABLE_START.match(l)]
    ends = [i for i, l in enumerate(lines) if TABLE_END.match(l)]
    if len(starts) != 1 or len(ends) != 1 or ends[0] <= starts[0]:
        raise SystemExit(f"README.md: expected exactly one coverage table, found starts={starts} ends={ends}")
    new = lines[:starts[0]] + text.splitlines() + lines[ends[0] + 1:]
    README.write_text("\n".join(new) + "\n")


def main(argv):
    feats, version = fetch()
    text, n_items, n_wsg = table(feats, version)
    if "--write" in argv[1:]:
        write(text)
        print(f"README.md: coverage table replaced — {n_items} items, {n_wsg} groups, "
              f"live version {version}")
    else:
        print(text)
        print(f"\n<!-- {n_items} items, {n_wsg} groups, live version {version} -->", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
