#!/usr/bin/env python3
"""collection_version.py — stamp a release version onto the collection document.

Usage:
    python3 scripts/collection_version.py data/stac/collection.json 1.0.0

Adds the STAC Version Extension to `stac_extensions` (if absent) and sets `version`,
rewriting the file in place with the same formatting item_create.py used to write it.

Called by catalogue_release.sh in preflight, on a full release only, with the tag HEAD
sits on. Never by the build: a version means "the published catalogue is in this state"
(the NEWS.md convention, shared with stac_uav_bc and stac_dem_bc), not "the scripts
changed" — so it is written by the release path, with the version passed in explicitly,
and item_create.py carries none. The build precedes the tag in every real flow (rebuild on
the branch, merge, tag), so a build-time stamp would be the previous tag by construction.

Refuses an empty or non-X.Y.Z version rather than falling back — so a pre-release tag
(`v1.1.0-rc1`) is refused, deliberately: the catalogue has no pre-release state, it is
either in the tagged state or not. A wrong stamp is worse than none: absent says
"unversioned, go and check"; a wrong version says "you already have this one".
Idempotent — re-stamping the same version rewrites the same bytes.

stdlib only, deliberately: the release side runs under python3, not `uv run`, and
catalogue_release-check.sh shims `uv` away, so the stamp has to be real there.
"""

import json
import re
import sys
from pathlib import Path

VERSION_EXT = "https://stac-extensions.github.io/version/v1.2.0/schema.json"
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def stamp(doc: dict, version: str) -> dict:
    if not SEMVER.match(version or ""):
        raise ValueError(f"refusing to stamp version {version!r}: want X.Y.Z")
    if doc.get("type") != "Collection":
        raise ValueError(f"not a Collection document: type={doc.get('type')!r}")
    exts = list(doc.get("stac_extensions") or [])
    if VERSION_EXT not in exts:
        exts.append(VERSION_EXT)
    doc["stac_extensions"] = exts
    doc["version"] = version
    return doc


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <collection.json> <X.Y.Z>", file=sys.stderr)
        return 2
    path, version = Path(argv[1]), argv[2]
    doc = json.loads(path.read_text())
    stamp(doc, version)
    # Same serialisation as item_create.py (indent=2, no trailing newline), so the
    # only bytes that change are the two fields stamped.
    path.write_text(json.dumps(doc, indent=2))
    print(f"stamped {path}: version {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
