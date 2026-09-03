#!/usr/bin/env python3
"""style_determinism-check.py — prove the embedded style does not churn the checksum.

Sibling of `gpkg_determinism-check.R`, which proves the same property for the OGR
timestamp pin. This one covers `04_gpkg_style.py`, whose writes GDAL never sees:
`OGR_CURRENT_DATE` cannot reach a row written through `sqlite3`, so the style step
carries its own pin and needs its own proof.

Two things can churn `file:checksum` here, and each gets an arm:

  1. `layer_styles.update_time`. Pinned to `GPKG_EPOCH`; the QGIS schema would default
     it to `strftime(...,'now')`.
  2. SQLite's header change counter, which moves on ANY write transaction — so a
     second run that rewrote identical rows would still change the file. The writer
     compares first and skips.

    uv run python scripts/style_determinism-check.py             # warm: must MATCH
    NO_PIN=1 uv run python scripts/style_determinism-check.py    # cold: must DIFFER
    ITEM=bulk_co_ff04 uv run python scripts/style_determinism-check.py

The cold path is the point. A guard nobody has seen fail is decoration: if the two
writes match with a wall-clock stamp, this check is not exercising what it claims and
a green warm run means nothing.

Reads a staged tree; writes only to a temp directory. Never touches `data/`.
"""

import datetime
import hashlib
import importlib.util
import os
import pathlib
import shutil
import sqlite3
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parent.parent

# The real writer, not a copy of it. The filename starts with a digit, so a plain
# import will not reach it.
_spec = importlib.util.spec_from_file_location(
    "gpkg_style", REPO / "scripts" / "04_gpkg_style.py")
_gs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_gs)

GPKGS = ("floodplain.gpkg", "floodplain_landcover.gpkg", "transition_vector.gpkg")


def digest(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main() -> int:
    item = os.environ.get("ITEM", "kotl_bt_ff04")
    # Strict truthiness, matching gpkg_determinism-check.R: a bare presence test would
    # read NO_PIN=0 as enabled, so an operator turning the cold path OFF would turn it
    # on and get a cold-path PASS for what they believe is a warm check.
    no_pin = os.environ.get("NO_PIN", "").lower() in {"1", "true", "yes"}

    src_dir = REPO / "data" / "stac" / item
    missing = [g for g in GPKGS if not (src_dir / g).exists()]
    if missing:
        raise SystemExit(
            f"no staged bundle at {src_dir} (missing {', '.join(missing)}) — run "
            f"scripts/run_pipeline.sh first, or set ITEM=")

    styles = _gs.load_styles()
    pinned = _gs.gpkg_epoch()

    if no_pin:
        print("NO_PIN=1 — cold path; rebuilds MUST differ")
    else:
        print(f"style timestamp pinned to {pinned}")

    failures, checked = [], 0
    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)
        # Subdirectories, not filename prefixes: the writer keys its style map on the
        # BASENAME and refuses a name it does not recognise, which is the behaviour we
        # want in production and would otherwise defeat this check.
        (tmp / "a").mkdir(); (tmp / "b").mkdir()
        for name in GPKGS:
            a, b = tmp / "a" / name, tmp / "b" / name
            shutil.copy(src_dir / name, a)
            shutil.copy(src_dir / name, b)
            # The staged copies are already styled, so strip the table first —
            # otherwise the writer's skip-if-current path would make both arms
            # trivially match and the cold path could never fail.
            for p in (a, b):
                con = sqlite3.connect(p)
                con.execute("DROP TABLE IF EXISTS layer_styles")
                con.commit()
                con.close()

            def stamp() -> str:
                if not no_pin:
                    return pinned
                return datetime.datetime.now(datetime.timezone.utc).strftime(
                    "%Y-%m-%dT%H:%M:%S.") + f"{int(time.time() * 1000) % 1000:03d}Z"

            _gs.style_gpkg(a, styles, stamp())
            # A wall-clock stamp has millisecond resolution, so two writes in the
            # same instant could match by accident and report a false PASS.
            time.sleep(1.2)
            _gs.style_gpkg(b, styles, stamp())

            da, db = digest(a), digest(b)
            same = da == db
            checked += 1
            print(f"  {name:28} a={da[:16]} b={db[:16]} {'match' if same else 'differ'}")
            if no_pin and same:
                failures.append(
                    f"{name}: rebuilds MATCHED with a wall-clock stamp — this check is "
                    f"not exercising what it claims, so a warm pass means nothing")
            if not no_pin and not same:
                failures.append(
                    f"{name}: rebuilds DIFFER with the pin set — the published "
                    f"file:checksum will churn on every rebuild")

            # Third property, warm path only: a re-run must be a true no-op. SQLite
            # bumps the header change counter on any write transaction, so a writer
            # that rewrote identical rows would move the bytes even with the pin.
            if not no_pin:
                before = digest(a)
                _gs.style_gpkg(a, styles, pinned)
                if digest(a) != before:
                    failures.append(
                        f"{name}: re-running the style step changed the file — the "
                        f"skip-if-current check is not holding, and every re-run "
                        f"republishes a new checksum for identical content")

    # A check that compared nothing is not a pass.
    if checked != len(GPKGS):
        failures.append(f"compared {checked} of {len(GPKGS)} GeoPackages")

    if failures:
        print(f"\nFAILED: {len(failures)} problem(s)", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    if no_pin:
        print("\nPASS (cold path): without the pin the rebuilds differ, as expected.")
    else:
        print(f"\nPASS: {checked} GeoPackage(s) byte-identical across rebuilds, and a "
              f"re-run is a no-op — file:checksum is stable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
