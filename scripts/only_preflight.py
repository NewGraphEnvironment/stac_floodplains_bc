#!/usr/bin/env python3
"""only_preflight.py — compare a live item against the build, for catalogue_release.sh --only.

    curl -sf "$API/items/$ONLY" | python3 scripts/only_preflight.py <built.json> <bucket.json>

Prints one `|`-separated line for the shell to read:

    <live value count>|<built value count>|<lost fields>|<dropped keys>|<gained keys>

Counts and KEY NAMES only on stdout — never a value. That is what makes the `|` protocol safe: a
provenance value is a free-form string that could contain anything, while the names come from
this repo's own declared map and the document being compared. (A key carrying a `|` would
corrupt its own field, which is one of the fields that refuses, so it cannot turn a refusal
into a pass — measured through the real `IFS=|` read.)

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

# The headline figures, which carry NO prefix and so are invisible to everything above (#98).
# Declared, not imported, for the same reason the map is — and the sixth copy of this fact,
# joined to the validator's by `prov_fields-check.py`.
#
# They need their own arm because the two arms above cannot see a RESCOPING. #98 changed what
# `floodplain_ffNN_km2` MEANS without changing any key: the live item would carry every key
# this build carries, with a different value, and `canon()` would report `0 lost`. A `--only`
# republish would then leave one item measuring its own watershed group while the other 22
# measured their whole footprint — permanently, on a bucket with versioning Suspended, which
# is the harm the `lost` and `dropped` arms exist to prevent. So a value move here REFUSES
# rather than printing a count: a redefinition is a full-release change by construction.
#
# Not an equality on every property, deliberately. Only these twelve are a cross-item
# CONTRACT: a figure means the same thing on every item or a cross-group aggregate is a lie.
# A per-item value that legitimately moves when one area is re-run — a checksum, a provenance
# digest, a year set — is exactly what `--only` exists to publish.
METRIC_PROPERTIES = (
    "floodplain_ff02_km2", "floodplain_ff04_km2", "floodplain_ff06_km2",
    "gross_loss_ha", "gross_gain_ha", "net_ha",
    "floodplain_ff02_footprint_km2", "floodplain_ff04_footprint_km2",
    "floodplain_ff06_footprint_km2",
    "gross_loss_footprint_ha", "gross_gain_footprint_ha", "net_footprint_ha",
)


# The six names whose presence says the live item was published UNDER the two-scope contract.
FOOTPRINT_PROPERTIES = tuple(n for n in METRIC_PROPERTIES if "_footprint_" in n)


def missing_footprint(live: dict, built: dict) -> list:
    """The `*_footprint_*` keys this build publishes that the live item does not carry.

    Non-empty is the un-rescoped window. Named rather than inlined so the refusal message can
    report WHICH keys put the item inside it: the first version of that message said the live
    item "carries no *_footprint_* key" while the condition is "at least one missing", so it
    was wrong in exactly the half-rescoped case the docstring below reserves.
    """
    return [n for n in FOOTPRINT_PROPERTIES if n in built and n not in live]


def metric_drift(live: dict, built: dict) -> list:
    """A figure whose MEANING may have moved — and only while that is still possible.

    **Scoped to the un-rescoped window, and it expires by its own mechanism.** The first
    version refused ANY `--only` whose twelve figures differed from the live item, which was
    over-refusal with no way past it: after #98 is published, the ordinary reason to republish
    one item is that its area was RE-RUN upstream, and a re-run moves loss/gain/net and the
    three areas without redefining anything. That is the case this module's own docstring says
    `--only` exists for, and the case the `gained` arm below cites by name — kotl/larl/sloc
    gain `link_run_uid` precisely BY being re-run, and the same re-run moves the metrics. Two
    arms disagreeing about one event is the shape a guard that fails toward refusal takes.

    So the discriminator is read off the live document rather than assumed: a live item that
    carries no `*_footprint_*` key predates the rescoping, and only then can a value move be a
    redefinition rather than a re-run. Measured 2026-10-19, before v2.1.0: 0 of the 23 live
    items carry one. Once the release has published them the arm goes quiet on its own, the
    way the `deprecated` marker expired at v2.0.0 — which is the point of it, not a tidy-up.
    A HALF-rescoped live item (some footprint keys, not all) is still inside the window.

    Absent on one side is not drift — it is the forward-only state these six siblings were in
    before they existed, and the shape arm reports it as a gain. Only a value move on a key
    both documents carry can be a redefinition.

    Compared as floats where both parse, so `659.99` and `659.990` agree, with a string
    fallback for anything that does not — the same shape as item_validate's `_same()`.
    """
    rescoped = missing_footprint(live, built)
    if not rescoped:
        return []
    moved = []
    for name in METRIC_PROPERTIES:
        if name not in live or name not in built:
            continue
        a, b = live[name], built[name]
        if a == b:
            continue
        try:
            if float(a) == float(b):
                continue
        except (TypeError, ValueError):
            pass
        moved.append((name, a, b))
    return moved


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
        elif key == "processing:software":
            if not isinstance(value, dict):
                # Not skipped. A live item serving this as a string or a list would silently
                # drop up to four fields from the comparison and report nothing lost, which
                # is the direction that publishes.
                raise SystemExit(f"processing:software is {type(value).__name__}, expected an "
                                 f"object of name -> version — refusing to compare against a "
                                 f"document this shape")
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

    # The live side is asserted, not defaulted. `live.get("properties", {})` returns {} for
    # ANY readable JSON that is not an item — an error page, a redirect body, a collection —
    # and then `lost` is empty and this prints a clean line: a reader that compared nothing,
    # passing. Measured before this guard: `echo {} | only_preflight.py …` printed `0|2|||`
    # and exited 0. The built side already raised a KeyError on the same shape, so only one
    # of the two sides was honest. This is the same premise check_provenance makes with
    # `seen == 0` and check_cog_tags with `compared == 0`.
    # Both documents this does not construct itself are asserted, not defaulted.
    # `doc.get("properties", {})` returns {} for ANY readable JSON that is not an item — an
    # error page, a redirect body, the collection fetched by mistake — and then the comparison
    # finds nothing: a reader that compared nothing, passing. Measured before this guard:
    # `echo {} | only_preflight.py …` printed `0|2|||` and exited 0 on the live side, and a
    # bucket copy of that shape read every built key as GAINED, which is reported rather than
    # refused. The built side already raised a KeyError on the same shape, so one of three
    # inputs was honest. Same premise as check_provenance's `seen == 0` and check_cog_tags'
    # `compared == 0`.
    for label, doc in (("live", live), ("bucket", bucket)):
        if doc.get("type") != "Feature" or not isinstance(doc.get("properties"), dict):
            raise SystemExit(f"the {label} document is not a STAC item (type="
                             f"{doc.get('type')!r}, properties="
                             f"{type(doc.get('properties')).__name__}) — refusing to compare "
                             f"against it rather than reporting nothing lost")

    # Before the provenance arms, because this one refuses outright: a redefined figure is a
    # full-release change, and there is nothing to weigh it against.
    moved = metric_drift(live["properties"], built["properties"])
    if moved:
        rescoped = missing_footprint(live["properties"], built["properties"])
        detail = "; ".join(f"{n}: live {a!r} -> build {b!r}" for n, a, b in moved)
        raise SystemExit(
            f"{len(moved)} headline figure(s) change value on this item, and the live item "
            f"is missing {len(rescoped)} of the {len(FOOTPRINT_PROPERTIES)} *_footprint_* "
            f"key(s) this build publishes ({', '.join(rescoped)}), so it predates the "
            f"two-scope contract: {detail}. "
            f"Those figures are a cross-item contract — one means the same thing on every item "
            f"or a cross-group aggregate is a lie — so republishing ONE item would leave the "
            f"other live items measuring something else, with no way to tell from the API. "
            f"That is a full-release change: publish the whole collection once, after which "
            f"this arm goes quiet on its own and an ordinary re-run can be published with "
            f"--only again. Refusing before anything is written.")

    live_values = canon(live["properties"])
    built_values = canon(built["properties"])
    lost = sorted(k for k in live_values if k not in built_values)

    # Asymmetric, deliberately. A key the bucket copy has and this build does not is a rename
    # or a dropped field: refused. A key this build has and the bucket copy does not is a
    # GAIN — an area re-run upstream that now carries a field it did not before, which is the
    # normal forward-only state and exactly what --only exists to publish. Refusing that
    # direction would block the next kotl/larl/sloc republish and call it a renamed contract.
    bucket_keys, built_keys = keys(bucket["properties"]), keys(built["properties"])
    dropped = [k for k in bucket_keys if k not in built_keys]
    gained = [k for k in built_keys if k not in bucket_keys]

    print("|".join([str(len(live_values)), str(len(built_values)),
                    ",".join(lost), ",".join(dropped), ",".join(gained)]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
