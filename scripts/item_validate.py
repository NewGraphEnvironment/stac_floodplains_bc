"""item_validate.py — QA gate: pystac-validate the STAC JSON that is about to ship.

Validates the bytes on disk, not in-memory objects, so what is checked is exactly
what gets synced and registered. Nonzero exit on any failure — catalogue_release.sh
runs this before a single byte reaches S3.

Usage:
    uv run python scripts/item_validate.py
    uv run python scripts/item_validate.py --base data/stac --expect 17

Two deliberate differences from the stac_uav_bc original, both closing a
silent-success hole:

  * `glob`, not `rglob`. Item + collection JSON live flat at the root of
    data/stac/; the per-item subdirs hold 68 `.tif.aux.json` terra sidecars that
    rglob would sweep up and then silently skip (they are not Features), so the
    printed count would carry no completeness signal.

  * `--expect N`. The original has no lower bound, so a wrong --base prints
    `valid: 0` and exits 0 — the gate opens on nothing. With --expect we require
    exactly N items + 1 collection. Default N is derived from the staged
    data/raw/*/meta.json count.
"""

import argparse
import json
import sys
from pathlib import Path

import pystac


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base", default="data/stac", type=Path,
                   help="directory holding <item_id>.json + collection.json")
    p.add_argument("--raw", default="data/raw", type=Path,
                   help="staging dir used to derive the expected item count")
    p.add_argument("--expect", type=int, default=None,
                   help="expected item count (default: number of data/raw/*/meta.json)")
    args = p.parse_args()

    if not args.base.is_dir():
        print(f"FAILED: --base {args.base} is not a directory", file=sys.stderr)
        return 1

    expected = args.expect
    if expected is None:
        expected = len(list(args.raw.glob("*/meta.json")))
    if expected < 1:
        print(f"FAILED: expected item count is {expected} — nothing staged under "
              f"{args.raw}/*/meta.json, so there is nothing to validate",
              file=sys.stderr)
        return 1

    items = 0
    collections = 0
    failed: list[tuple[str, str]] = []

    for path in sorted(args.base.glob("*.json")):
        try:
            doc = json.loads(path.read_text())
        except Exception as e:  # noqa: BLE001 — a malformed file is a gate failure
            failed.append((path.name, f"unreadable: {e}"))
            continue

        try:
            if doc.get("type") == "Collection":
                pystac.Collection.from_dict(doc).validate()
                collections += 1
            elif doc.get("type") == "Feature":
                pystac.Item.from_dict(doc).validate()
                items += 1
            else:
                failed.append((path.name, f"unexpected type: {doc.get('type')!r}"))
        except Exception as e:  # noqa: BLE001 — collect all failures, report once
            failed.append((path.name, str(e).splitlines()[0][:200]))

    print(f"valid: {items} item(s) + {collections} collection(s)")

    if failed:
        print(f"FAILED: {len(failed)} document(s) did not validate", file=sys.stderr)
        for name, err in failed:
            print(f"  {name}: {err}", file=sys.stderr)
        return 1

    # Count check last, so a genuine validation error is reported in preference to
    # the count symptom it would also cause.
    if items != expected:
        print(f"FAILED: validated {items} item(s) but expected {expected} "
              f"(from {args.raw}/*/meta.json). A short build must not be published — "
              f"it would overwrite the live collection.", file=sys.stderr)
        return 1
    if collections != 1:
        print(f"FAILED: expected exactly 1 collection.json, found {collections}",
              file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
