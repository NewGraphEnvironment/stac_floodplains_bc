#!/usr/bin/env python3
"""claim_drift-check.py — pin #98's published claims across every copy that makes them.

    uv run python scripts/claim_drift-check.py

Why this exists, specifically. Five rounds of `/code-check` on #98 found 38 defects and
**nineteen of them were inside a previous round's fix**. They were not nineteen different
mistakes: round after round, a claim was corrected in the copies that happened to be open and
left standing in the others. The published collection description, two asset descriptions,
`README.Rmd` twice, `NEWS.md`, `CLAUDE.md`, `scripts/README.md`, `readme_functions.R` and
`01_stage.R` each carry a piece of the same story, and nothing joined them — in a repo that
pins its licence literals with `attribution_drift-check.py` and four copies of its provenance
map with `prov_fields-check.py`.

So this is the join. Three kinds of arm:

  * RETIRED — a phrasing that was measured false and must appear nowhere. This is the arm that
    catches "fixed in three of four copies", which no amount of care did.
  * CO-OCCURRENCE — a rule rather than a string: any file that tells a consumer to read an
    AREA out of `composition_*` must also name the `in_floodplain` filter. It catches a copy
    that does not exist yet, which a string list cannot.
  * MEASURED — a number quoted in prose, re-derived here from `data/stac` and compared. A
    figure that drifts from the build it describes fails rather than ages.

`planning/` is excluded throughout: it is the record of the work and deliberately keeps the
wrong turns (`planning.md`, "Keep the wrong turns"). `CLAUDE.md` and `NEWS.md` may quote a
retired phrasing when they are explicitly recording that it was wrong, so a line carrying one
of the EXEMPT markers is skipped — narrowly, and the markers are listed.
"""

import json
import pathlib
import re
import sqlite3
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
STAC = ROOT / "data" / "stac"

# Files that make claims to a consumer or to a future maintainer. `planning/` is excluded.
CLAIM_FILES = [
    "scripts/item_create.py", "scripts/item_validate.py", "scripts/01_stage.R",
    "scripts/readme_functions.R", "scripts/test_pipeline.R", "scripts/README.md",
    "README.Rmd", "NEWS.md", "CLAUDE.md",
]

# A line that is explicitly recording a retired claim AS retired is not a copy of it.
EXEMPT = ("an earlier draft", "earlier version", "which is not one", "it is not:",
          "measured false", "was wrong", "got that wrong", "the first version",
          "two earlier versions", "code-check round", "until #98", "until code-check")

# Phrasings measured false during #98's review. Each was true of nothing, or true of a
# different quantity than the one the sentence named.
RETIRED = {
    "no other context column": "composition_* also carries in_floodplain, the denominator",
    "3-10%": "the composition excess is 2.9%-11.1% by item, not 3-10%",
    "neighbour's own item also publishes": "only 9.7% of the difference is a neighbour's",
    "that neighbour's own item also publishes": "only 9.7% of the difference is a neighbour's",
    "unsuffixed provincial total": "it is a total of the covered groups, not the province",
    "for those two the patch flag": "three columns are absent from composition_*, not two",
    "both flags are any-touch": "open_water_poly_id is an identifier, and in_wsg a partition",
    "Both new flags are **any-touch**": "same, with in_wsg as the nearest antecedent",
    "`bbox` and `proj:bbox` are unchanged**, and deliberately not rescoped":
        "the geometry DOES change on all 23 items",
    "every** vector layer in both source bundles": "246 of 468 layers carry in_wsg",
    "PARS and\nFINA": "neither PARA nor FINA is in the roster; PARS was a substitution",
    "Williston's PARS": "same",
    "key is now (`name_basin`, `patch_id`, `in_wsg`)": "not a key; blue_line_key completes it",
    "0.48% of that sum": "names the in_wsg sum by antecedent; it is 0.48% of the footprint sum",
}

# The rule, not the string: naming composition_* as a source of AREA obliges the filter.
# Narrow on purpose: the block must direct a READ of an area out of that table, not merely
# mention both words. `test_pipeline.R`'s key-contract comment says "area identifier" beside a
# composition layer name and is not a claim about areas at all — the first version of this arm
# flagged it, which is the false-positive direction a guard like this has to be held to.
AREA_WORDS = re.compile(
    r"(read|reads|reading|take|taken|come[s]? from|comes? out of|filtered on|SUM\(ha\))"
    r"[^.]{0,120}?(areas?\b|`ha`|SUM\(ha\))"
    r"|areas?\b[^.]{0,120}?(from|out of)\s+(the\s+)?`?composition", re.I)


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def composition_para(text: str):
    """Paragraphs (or f-string runs) that name composition_* — the unit a claim lives in."""
    for block in re.split(r"\n\s*\n", text):
        if "composition_*" in block or "composition_" in block:
            yield block


def measured() -> dict:
    """Re-derive every prose number this issue quotes, from the staged build."""
    items = {p.stem: json.loads(p.read_text())
             for p in STAC.glob("*_all_ff04.json")}
    P = {k: v["properties"] for k, v in items.items()}
    pairs = [("floodplain_ff02_km2", "floodplain_ff02_footprint_km2"),
             ("floodplain_ff04_km2", "floodplain_ff04_footprint_km2"),
             ("floodplain_ff06_km2", "floodplain_ff06_footprint_km2"),
             ("gross_loss_ha", "gross_loss_footprint_ha"),
             ("gross_gain_ha", "gross_gain_footprint_ha")]
    out = {
        "items": len(P),
        "ff04_in_sum": round(sum(v["floodplain_ff04_km2"] for v in P.values()), 2),
        "ff04_fp_sum": round(sum(v["floodplain_ff04_footprint_km2"] for v in P.values()), 2),
    }
    for inw, fp in pairs:
        out[f"diff_{inw}"] = round(sum(v[fp] - v[inw] for v in P.values()), 2)
    out["min_share"] = min(v[inw] / v[fp] for v in P.values() for inw, fp in pairs)
    # composition excess over in_floodplain, per item
    ex = []
    for k in P:
        g = STAC / k / "floodplain_landcover.gpkg"
        con = sqlite3.connect(f"file:{g}?immutable=1", uri=True)
        try:
            t = [r[0] for r in con.execute(
                "SELECT table_name FROM gpkg_contents "
                "WHERE table_name LIKE 'composition%'")][0]
            a, = con.execute(f'SELECT SUM(ha) FROM "{t}"').fetchone()
            b, = con.execute(
                f'SELECT SUM(ha) FROM "{t}" WHERE in_floodplain=1').fetchone()
            ex.append(100 * (a / b - 1))
        finally:
            con.close()
    out["comp_min"] = min(ex)
    out["comp_max"] = max(ex)
    return out


def main() -> int:
    bad = []
    n = 0

    # --- arm 1: retired phrasings, nowhere
    for rel in CLAIM_FILES:
        text = read(rel)
        for phrase, why in RETIRED.items():
            n += 1
            if phrase not in text:
                continue
            for i, line in enumerate(text.split("\n"), 1):
                if phrase.split("\n")[0] in line and not any(m in line for m in EXEMPT):
                    bad.append(f"{rel}:{i} carries the retired phrasing {phrase!r} — {why}")

    # --- arm 2: composition_* as a source of area obliges the in_floodplain filter
    for rel in CLAIM_FILES:
        text = read(rel)
        for block in composition_para(text):
            if not AREA_WORDS.search(block):
                continue
            n += 1
            if "in_floodplain" not in block:
                head = " ".join(block.split())[:110]
                bad.append(f"{rel} names composition_* as a source of area without the "
                           f"`in_floodplain` filter: {head}…")

    # --- arm 3: numbers in prose against the build
    m = measured()
    checks = [
        ("519.08", m["diff_floodplain_ff04_km2"], 519.08),
        ("505.82", m["diff_floodplain_ff02_km2"], 505.82),
        ("528.90", m["diff_floodplain_ff06_km2"], 528.90),
        ("908.40", m["diff_gross_loss_ha"], 908.40),
        ("620.20", m["diff_gross_gain_ha"], 620.20),
        # The in_wsg sum is deliberately absent from this list. The prose quotes
        # 10,092.24, the BC Albers union-and-sum from
        # `planning/active/neighbour-measure.R`; the published per-item properties
        # sum to 10,092.27, being UTM and rounded to 2 dp. Both are right about
        # their own method, and mixing them is the defect this file exists for, so
        # the Albers figures are pinned by arm 4 on the METHOD rather than the value.
        ("10,611.35", m["ff04_fp_sum"], 10611.35),
    ]
    # BOTH directions, and the second is the point. Comparing the build against a literal
    # here would only pin this file; the figure also has to be the one the prose actually
    # quotes, or a corrected number in `CLAUDE.md` and a stale one in `NEWS.md` both pass.
    quoted = {rel: read(rel) for rel in CLAIM_FILES}
    for label, got, want in checks:
        n += 1
        if abs(got - want) > 0.011:
            bad.append(f"the expectation {label} is stale: the build gives {got}")
        n += 1
        where = [rel for rel, t in quoted.items() if label in t]
        if not where:
            bad.append(f"no claim file quotes {label} — either the prose dropped it or it "
                       f"was reworded, and this arm is then pinning nothing")
    n += 1
    if not (2.85 <= m["comp_min"] <= 2.95 and 11.05 <= m["comp_max"] <= 11.15):
        bad.append(f"prose quotes a 2.9%-11.1% composition excess where the build gives "
                   f"{m['comp_min']:.2f}%-{m['comp_max']:.2f}%")
    n += 1
    if not 0.55 <= m["min_share"] <= 0.60:
        bad.append(f"prose quotes a 0.581 minimum in_wsg/footprint share where the build "
                   f"gives {m['min_share']:.4f} — METRIC_SCOPE_MAJORITY's margin moved")

    # --- arm 4: an Albers geometry figure must be labelled as one
    #
    # 519.16 / 50.58 / 468.57 / 10,092.24 come from `neighbour-measure.R` over the staged
    # delineations in EPSG:3005, and are close to but not equal to the same quantities summed
    # from the published per-item properties, which are UTM. Round 3 of #98's review withdrew
    # a measurement for exactly this reason: restated without its method it cannot be
    # re-derived, so nothing downstream can disagree with it. A copy quoting one of these
    # without saying how it was taken fails here.
    for rel in CLAIM_FILES:
        text = read(rel)
        for fig in ("519.16", "50.58", "468.57", "10,092.24"):
            if fig not in text:
                continue
            n += 1
            if "Albers" not in text:
                bad.append(f"{rel} quotes the Albers figure {fig} without naming the "
                           f"projection it was measured in")

    print(f"{n} claim arm(s) over {len(CLAIM_FILES)} file(s); {len(bad)} problem(s)")
    for msg in bad:
        print(f"  FAIL  {msg}")
    if not bad:
        print(f"  ok    no retired phrasing survives; every file naming composition_* as a "
              f"source of area names the in_floodplain filter; every prose number matches "
              f"the build ({m['items']} items)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
