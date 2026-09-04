#!/usr/bin/env python3
"""attribution_drift-check.py — the human-facing attribution still matches what is published.

    uv run python scripts/attribution_drift-check.py

CLAUDE.md records the rule for the licence literals: they are duplicated verbatim into
`item_validate.py` and a third time as `EXPECT_LICENSE` in `catalogue_release.sh`, never shared,
and the duplication is safe ONLY because every assertion is full equality — token containment
would let the copies drift while still sharing enough words to pass.

`ATTRIBUTION.md` (#53) added a fourth and fifth copy: the `sci:citation` sentence as a
blockquote, and the licence pair in prose. Those are the copies a licensor actually reads, and
until this check existed they were the only ones nothing asserted. An upstream move to `v03`
would turn `check_citation_premise` red and leave the human-facing documents quietly claiming
the old attribution — the guards firing on the machine-readable surface while the readable one
lies.

Compared after stripping markdown decoration only (backticks, angle-bracketed autolinks, the
blockquote marker, and hard line wrapping). Nothing else is normalised: this is an equality
check, and a looser one would defeat its own purpose.

Sibling of `style_drift-check.py`, which byte-compares the committed QGIS styles against the
class table for the same reason. Stdlib only.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ATTRIBUTION = ROOT / "ATTRIBUTION.md"
ITEM_CREATE = ROOT / "scripts" / "item_create.py"


def demarkdown(s: str) -> str:
    """Strip the decoration `ATTRIBUTION.md` adds, and nothing else."""
    s = re.sub(r"^>\s?", "", s, flags=re.M)      # blockquote marker
    s = s.replace("`", "")                        # code spans
    s = re.sub(r"<(https?://[^>]+)>", r"\1", s)   # autolinks
    s = re.sub(r"\s+", " ", s)                    # hard wrapping
    return s.strip()


def citation_from_item_create() -> str:
    """The CITATION literal as `item_create.py` defines it."""
    src = ITEM_CREATE.read_text()
    m = re.search(r'^CITATION\s*=\s*\(\s*\n(.*?)^\)', src, re.S | re.M)
    if not m:
        m = re.search(r'^CITATION\s*=\s*(".*?"|\'.*?\')\s*$', src, re.S | re.M)
        if not m:
            raise SystemExit("could not find CITATION in item_create.py — the parser needs "
                             "updating, and an unparsed literal must not read as a pass")
        return re.sub(r"\s+", " ", m.group(1).strip("\"'")).strip()
    parts = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))
    if not parts:
        raise SystemExit("CITATION matched but no string parts parsed — refusing to pass")
    text = re.sub(r"\s+", " ", "".join(parts)).strip()
    # CITATION is an f-string. Resolve its placeholders from the same file rather than
    # comparing against the literal braces, and refuse on any that does not resolve — an
    # unresolved `{FOO}` would otherwise be compared as text and read as a real difference,
    # or worse, be silently dropped by a tolerant substitution.
    for name in set(re.findall(r"\{([A-Z_]+)\}", text)):
        m2 = re.search(rf'^{name}\s*=\s*"([^"]*)"', src, re.M)
        if not m2:
            raise SystemExit(f"CITATION interpolates {{{name}}}, which this checker cannot "
                             "resolve from item_create.py — refusing to pass")
        text = text.replace("{" + name + "}", m2.group(1))
    return text


def const(name: str) -> str:
    """The value of a top-level string constant in `item_create.py`."""
    m = re.search(rf'^{name}\s*=\s*"([^"]*)"', ITEM_CREATE.read_text(), re.M)
    if not m:
        raise SystemExit(f"could not read {name} from item_create.py — refusing to pass on a "
                         "literal this checker cannot see")
    return m.group(1)


def blockquote_from_attribution() -> str:
    """The blockquote under 'What the collection publishes'."""
    lines = ATTRIBUTION.read_text().splitlines()
    block = [l for l in lines if l.startswith(">")]
    if not block:
        raise SystemExit("no blockquote in ATTRIBUTION.md — refusing to pass on an absence")
    return demarkdown("\n".join(block))


def main() -> int:
    published = citation_from_item_create()
    documented = blockquote_from_attribution()

    fails = []
    if published != documented:
        # Show where they part company; a bare "differ" sends the reader to a diff by eye.
        i = next((i for i, (a, b) in enumerate(zip(published, documented)) if a != b),
                 min(len(published), len(documented)))
        fails.append(
            "ATTRIBUTION.md's citation blockquote does not match item_create.py's CITATION.\n"
            f"  first difference at character {i}:\n"
            f"    item_create.py : …{published[max(0, i - 40):i + 60]}…\n"
            f"    ATTRIBUTION.md : …{documented[max(0, i - 40):i + 60]}…"
        )

    # The collection id and the outbound licence, compared against the PARSED constants.
    # A first attempt asked whether the literal appeared anywhere in item_create.py, and that
    # arm stayed silent through a v02 -> v03 mutation because a COMMENT still named v02 --
    # containment over a whole file is exactly the predicate this checker's own docstring says
    # is unsafe. Take the value, then assert no competing spelling survives in the document.
    text = ATTRIBUTION.read_text()
    for label, name, pattern in (
        ("landcover collection id", "SOURCE_COLLECTION_ID", r"io-lulc-annual-v\d+"),
        ("outbound licence", "COLLECTION_LICENSE", r"CC[- ]BY[- ][\d.]+"),
    ):
        want = const(name)
        # ATTRIBUTION.md writes the licence with spaces (`CC BY 4.0`) where the constant is
        # hyphenated, because one is prose and the other is an SPDX id. Compare on a form that
        # ignores only that.
        norm = lambda s: s.replace("-", " ")
        found = set(re.findall(pattern, text))
        if not found:
            fails.append(f"{label}: ATTRIBUTION.md names none — expected {want}")
        elif {norm(f) for f in found} != {norm(want)}:
            fails.append(f"{label}: item_create.py says {want}, ATTRIBUTION.md says "
                         f"{', '.join(sorted(found))} — the two must move together")

    if fails:
        print("ATTRIBUTION DRIFT\n")
        for f in fails:
            print(f"- {f}\n")
        return 1

    print(f"ATTRIBUTION.md matches item_create.py — citation {len(published)} chars, "
          "collection id and licence agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
