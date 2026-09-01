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
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse

import pystac


MULTIHASH_SHA256 = "1220"


def check_checksums(base: Path) -> list[str]:
    """Verify every asset's `file:checksum` and `file:size` against the file on disk.

    Assets live at `<base>/<item_id>/<name>`, and the S3 href's basename is that
    same name — so the local path is derivable from the href without extra state.

    Returns a list of human-readable problems (empty when everything matches).
    """
    problems: list[str] = []
    asset_keys: dict[str, set] = {}
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc["id"]
        asset_keys[item_id] = set(doc.get("assets", {}))
        for key, asset in sorted(doc.get("assets", {}).items()):
            where = f"{item_id}/{key}"
            checksum = asset.get("file:checksum")
            size = asset.get("file:size")
            if checksum is None or size is None:
                problems.append(f"{where}: missing file:checksum or file:size")
                continue
            # Structural: catches the mistake the JSON schema cannot see.
            if not checksum.startswith(MULTIHASH_SHA256) or len(checksum) != 68:
                problems.append(
                    f"{where}: not a sha256 multihash (want '1220' + 64 hex, got "
                    f"{len(checksum)} chars starting {checksum[:6]!r})")
                continue
            if checksum != checksum.lower():
                problems.append(f"{where}: checksum must be lowercase hex")
                continue

            # Resolve the local file from the LAST TWO href segments, not from
            # item_id + basename. Deriving the directory ourselves would verify the
            # right bytes for a wrong href — a published prefix typo would point S3
            # consumers at a 404 while this guard passed against the correct local
            # file. The href is the thing that ships, so the href is what we check.
            href_parts = PurePosixPath(urlparse(asset["href"]).path).parts
            if len(href_parts) < 2 or href_parts[-2] != item_id:
                problems.append(
                    f"{where}: href does not sit under '{item_id}/' — {asset['href']}")
                continue
            local = base / href_parts[-2] / href_parts[-1]
            if not local.is_file():
                problems.append(f"{where}: asset not on disk at {local}")
                continue
            actual_size = local.stat().st_size
            if actual_size != size:
                problems.append(
                    f"{where}: file:size {size} but file is {actual_size} bytes")
            h = hashlib.sha256()
            with local.open("rb") as fh:
                for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                    h.update(chunk)
            actual = MULTIHASH_SHA256 + h.hexdigest()
            if actual != checksum:
                problems.append(
                    f"{where}: file:checksum does not match the bytes on disk "
                    f"(published {checksum[:16]}…, actual {actual[:16]}…)")

    # An item that lost an asset would otherwise pass by iterating nothing —
    # "no assets to check" and "all assets checked out" produce identical output.
    # Every item is built from the same template, so the key sets must be identical;
    # comparing them catches a dropped asset without hardcoding a count here.
    if asset_keys:
        expected_keys = max(asset_keys.values(), key=len)
        if not expected_keys:
            problems.append("no assets on any item — nothing was actually verified")
        for item_id, keys in sorted(asset_keys.items()):
            if keys != expected_keys:
                problems.append(
                    f"{item_id}: asset set differs from the other items — missing "
                    f"{sorted(expected_keys - keys) or 'none'}, "
                    f"unexpected {sorted(keys - expected_keys) or 'none'}")
    return problems


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

    # --- file extension: do the published checksums describe the bytes we ship? ---
    #
    # This re-reads every asset (~670 MB, ~2.5s). That cost buys the only thing the
    # schema cannot give us: the file extension's pattern is `^[a-f0-9]+$`, so a bare
    # sha256 with no multihash prefix validates cleanly, and so does a well-formed
    # checksum of the wrong bytes. A guard that only checked the field was present
    # would be decoration on an issue whose entire subject is byte integrity.
    bad = check_checksums(args.base)
    if bad:
        print(f"FAILED: {len(bad)} asset checksum/size problem(s)", file=sys.stderr)
        for msg in bad:
            print(f"  {msg}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
