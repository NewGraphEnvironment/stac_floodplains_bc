#!/usr/bin/env python3
"""style_drift-check.py — prove the committed styles still match `classes.json`.

`styles/*.qml` are committed so a human reviews what ships, which means they can go
stale the moment drift's class table changes: `01_stage.R` rewrites
`data/raw/classes.json` from `drift::dft_class_table("io-lulc")` on every run, and
nothing else would notice that `styles/` did not follow. The published RAT and
`classification:classes` both move with the table; a stale style would silently
disagree with them, which is the exact drift #46 exists to prevent.

So: re-run the generator into a temp directory and byte-compare. This is a STALENESS
check, not a correctness one — it says the committed bytes are what today's class
table produces, and says nothing about whether QGIS renders them. Correctness is
`item_validate.py` plus the QGIS round-trip in `test_pipeline.R`.

Two-sided on the file set as well as the bytes: a style added to the generator but
never committed fails, and a committed style the generator no longer produces fails
too. Either direction leaves `styles/` describing something that is not shipped.

    uv run python scripts/style_drift-check.py

Exits non-zero on drift, naming every file that differs and how.
"""

import hashlib
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import importlib

_gen = importlib.import_module("style_qml-write")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    if not _gen.CLASSES.exists():
        print(f"FAILED: {_gen.CLASSES} is absent — run scripts/01_stage.R first, which "
              f"ferries the class table from drift.", file=sys.stderr)
        return 1

    classes = json.loads(_gen.CLASSES.read_text())["classes"]
    roots, _ = _gen.build_all(classes)

    problems: list[str] = []

    # Two-sided on the file set. A generator that stopped emitting a style, and a
    # committed style nothing generates, are both drift.
    committed = {p.name for p in _gen.OUT.glob("*.qml")}
    generated = set(roots)
    for extra in sorted(committed - generated):
        problems.append(
            f"{extra} is committed in styles/ but the generator no longer produces it — "
            f"delete it, or restore the build function that made it")
    for missing in sorted(generated - committed):
        problems.append(
            f"{missing} is produced by the generator but is not committed in styles/ — "
            f"run `uv run python scripts/style_qml-write.py` and commit the result")

    # Byte-compare the intersection.
    compared = 0
    with tempfile.TemporaryDirectory() as td:
        for name in sorted(generated & committed):
            fresh = Path(td) / name
            _gen.write(roots[name], fresh, announce=False)
            live = _gen.OUT / name
            compared += 1
            a, b = digest(live), digest(fresh)
            if a != b:
                problems.append(
                    f"{name} differs from what today's classes.json produces "
                    f"(committed sha256 {a[:12]}, regenerated {b[:12]}; "
                    f"{live.stat().st_size} vs {fresh.stat().st_size} bytes) — "
                    f"run `uv run python scripts/style_qml-write.py` and commit the result")

    # A check that compared nothing is not a pass. An empty styles/ would otherwise
    # report clean, which reads identically to every style being current.
    if compared == 0:
        problems.append(
            "no styles were compared — styles/ holds no .qml the generator also "
            "produces, so this check proved nothing")

    if problems:
        print(f"FAILED: {len(problems)} style drift problem(s)", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    print(f"style drift: {compared} style(s) byte-identical to what "
          f"{_gen.CLASSES.name} produces ({len(classes)} classes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
