#!/usr/bin/env python3
"""only_preflight.py — compare a live item against the build, for catalogue_release.sh --only.

    curl -sf "$API/items/$ONLY" | python3 scripts/only_preflight.py <built.json> <bucket.json>

Prints one `|`-separated line for the shell to read:

    <live value count>|<built value count>|<lost fields>|<dropped keys>|<gained keys>

A FILE, not an inline program, and that is the whole point (#74). It used to be the argument of
a double-quoted `python3 -c` inside the release script, where bash got to it before python did
and three separate characters broke it in one afternoon: a markdown backtick span ran as a
command on every preflight, the comment that recorded THAT carried a double quote which
truncated the program, and the enumeration written to catch both matched `$NAME` patterns and
so missed `$(…)`, which a reviewer used to make bash create a file while the guard reported
clean. Each fix was correct and each left a new hole, because the hazard was the construct, not
the characters. In a file there is no shell quoting to get wrong, prose can say anything, and
`prov_fields-check.py` compares this module's map against the validator's by importing it
rather than by slicing a shell script.

Stdlib only, and run as `python3` rather than `uv run`: it must work on a release machine that
holds no source tree beyond this repo, and `catalogue_release-check.sh` shims `uv`.

Two arguments, both required, and both read rather than trusted: the item JSON this build
would publish, and the bucket's current copy of it.
"""

import json
import sys

# The publish map, inverted: published property -> staged field name. A fifth copy of the fact,
# declared rather than imported for the reason item_validate.py gives above its own — a guard
# that imports the value it checks is a round trip through our own assignment. The copies are
# joined by `prov_fields-check.py`, which imports THIS module and compares it against the
# validator's, so the duplication is pinned rather than merely intended.
NEW = {
    "link:run_uid": "link_run_uid",
    "link:config_sha256": "link_config_sha256",
    "processing:datetime": "produced_datetime",
    "landcover:source": "landcover_source",
    "landcover:collection": "landcover_collection",
    "landcover:stac_url": "landcover_stac_url",
    "landcover:key": "landcover_key",
    "landcover:item_hash": "landcover_item_hash",
}
SOFTWARE = {
    "link": ("link_version", "link_sha"),
    "flooded": ("flooded_version",),
    "drift": ("drift_version",),
}
# Including the retired `nge:`, which this file alone still reads. That is what lets a renamed
# build be compared against an item published before the rename: scanning for either naming
# scheme alone would compare a full item against an empty one and report nothing lost.
PREFIXES = ("nge:", "processing:", "link:", "landcover:")


def canon(props: dict) -> dict:
    """Published properties -> staged field names, reading BOTH naming schemes.

    Anything under the retired prefix is the staged name already; the rest goes through the
    map. A `processing:software` entry marks every field it was built from, whose value is the
    entry string — nothing here splits `<version>+<sha>`, because only the LAST `+` separates
    the two and the comparison does not need the halves.

    A null value counts as absent, so a build that still published nulls reads the same way as
    one that omits them.
    """
    out = {}
    for key, value in props.items():
        if value is None:
            continue
        if key.startswith("nge:"):
            out[key[len("nge:"):]] = value
        elif key in NEW:
            out[NEW[key]] = value
        elif key == "processing:software" and isinstance(value, dict):
            for entry, fields in SOFTWARE.items():
                if value.get(entry) is not None:
                    for field in fields:
                        out[field] = value[entry]
    return out


def keys(props: dict) -> list:
    """The provenance KEYS a document publishes, nulls included — a shape, not values."""
    return sorted(k for k in props if k.split(":", 1)[0] + ":" in PREFIXES)


def main(argv: list) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <built item json> <bucket item json>", file=sys.stderr)
        return 2
    built = json.load(open(argv[1]))
    bucket = json.load(open(argv[2]))
    live = json.load(sys.stdin)

    live_values = canon(live.get("properties", {}))
    built_values = canon(built["properties"])
    lost = sorted(k for k in live_values if k not in built_values)

    # Asymmetric, deliberately. A key the bucket copy has and this build does not is a rename
    # or a dropped field: refused. A key this build has and the bucket copy does not is a
    # GAIN — an area re-run upstream that now carries a field it did not before, which is the
    # normal forward-only state and exactly what --only exists to publish. Refusing that
    # direction would block the next kotl/larl/sloc republish and call it a renamed contract.
    bucket_keys, built_keys = keys(bucket.get("properties", {})), keys(built["properties"])
    dropped = [k for k in bucket_keys if k not in built_keys]
    gained = [k for k in built_keys if k not in bucket_keys]

    print("|".join([str(len(live_values)), str(len(built_values)),
                    ",".join(lost), ",".join(dropped), ",".join(gained)]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
