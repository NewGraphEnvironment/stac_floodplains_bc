#!/usr/bin/env python3
"""year_sets-check.py — prove item_validate.py's classified-year arms fire (#61).

    uv run python scripts/year_sets-check.py     # exit = number of failed assertions

`check_checksums` gained the two-population partition: fixed asset keys compared across
items, `classified_*` keys checked per item against the ALLOWED_YEAR_SETS literal, plus an
arm comparing an item's published classified assets against the COGs actually in its
directory. Those arms are reached only after ~670 MB of real hashing on a real build, and
one of them is dropped under `--partial` — so a full-tree run is a bad place to find out
whether any of them works.

Each case builds a tiny synthetic `data/stac`-shaped tree with real bytes and real
checksums, so the per-asset loop passes and the key arms are what is under test.

Every assertion greps for ITS OWN message. A suite with N guards has N ways to return a
non-empty problem list, and every one of them looks the same to a check that counts.
"""

import hashlib
import json
import pathlib
import shutil
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from item_validate import ALLOWED_YEAR_SETS, check_checksums  # noqa: E402

FAILS = 0
N = 0


def ok(desc: str) -> None:
    global N
    N += 1
    print(f"  ok    {desc}")


def bad(desc: str, why: str) -> None:
    global N, FAILS
    N += 1
    FAILS += 1
    print(f"  FAIL  {desc} — {why}")


def expect_clean(desc: str, problems: list[str]) -> None:
    ok(desc) if not problems else bad(desc, f"{len(problems)} problem(s): {problems[0]}")


def expect_problem(desc: str, problems: list[str], needle: str) -> None:
    """A problem whose MESSAGE names the arm under test.

    Not `problems != []`: the fixtures below can trip the per-asset loop, the fixed-key
    compare, or two different year arms, and all three read as "the guard fired".
    """
    if not problems:
        bad(desc, "no problem reported")
    elif not any(needle in p for p in problems):
        bad(desc, f"a DIFFERENT arm fired: {problems[0][:160]}")
    else:
        ok(desc)


FIXED_ASSETS = ("transition_2017_2023.tif", "floodplain_landcover.gpkg",
                "floodplain.gpkg", "transition_vector.gpkg",
                "floodplain.qml", "classified.qml", "transition.qml")
FIXED_KEYS = ("transition_2017_2023", "floodplain_landcover", "floodplain",
              "transition_vector", "style_floodplain", "style_classified",
              "style_transition")


def write_item(base: pathlib.Path, item_id: str, years, extra_files=(), drop_keys=()):
    """One valid item: real files, real checksums, so only the key arms can fire."""
    d = base / item_id
    d.mkdir(parents=True, exist_ok=True)
    assets = {}

    def add(key, name):
        payload = f"{item_id}/{name}".encode()
        (d / name).write_bytes(payload)
        assets[key] = {
            "href": f"https://example.invalid/{item_id}/{name}",
            "file:checksum": "1220" + hashlib.sha256(payload).hexdigest(),
            "file:size": len(payload),
        }

    for y in years:
        add(f"classified_{y}", f"classified_{y}.tif")
    for key, name in zip(FIXED_KEYS, FIXED_ASSETS):
        add(key, name)
    for name in extra_files:          # on disk, described by no asset
        (d / name).write_bytes(b"stray")
    for key in drop_keys:
        assets.pop(key)
    (base / f"{item_id}.json").write_text(json.dumps(
        {"type": "Feature", "id": item_id, "assets": assets}))


def tree(cases):
    base = pathlib.Path(tempfile.mkdtemp(prefix="year_sets_"))
    for kwargs in cases:
        write_item(base, **kwargs)
    return base


THREE = (2017, 2020, 2023)
SEVEN = tuple(range(2017, 2024))

print("the literal itself")
# The arms below are only meaningful if the literal says what the collection publishes.
# Asserted here rather than assumed, because every case reads it.
expect_clean("ALLOWED_YEAR_SETS holds both populations",
             [] if {tuple(sorted(y)) for y in ALLOWED_YEAR_SETS} == {THREE, SEVEN}
             else [f"ALLOWED_YEAR_SETS is {ALLOWED_YEAR_SETS}"])

print("controls")
# A guard that has never passed is as untested as one that has never fired.
b = tree([{"item_id": "aaa_ch_ff04", "years": THREE},
          {"item_id": "bbb_ch_ff04", "years": SEVEN}])
problems, used = check_checksums(b)
expect_clean("two populations side by side are clean", problems)
expect_clean("...and both sets are reported as used",
             [] if sorted(len(v) for v in used.values()) == [1, 1] else [str(used)])
shutil.rmtree(b)

b = tree([{"item_id": "aaa_ch_ff04", "years": THREE},
          {"item_id": "bbb_ch_ff04", "years": THREE}])
problems, _ = check_checksums(b, partial=False)
expect_problem("a set no item uses is reported as a stale literal", problems,
               "is an entry in ALLOWED_YEAR_SETS that nobody updated")
# The --partial partition, and this is the arm that must come OFF: it asks about a year set
# ABSENT from the tree, which is the normal state of a subset (#26). Getting this wrong
# would refuse every single-item release, exactly as #26 did.
problems, _ = check_checksums(b, partial=True)
expect_clean("...and NOT under --partial, where an absent set is the normal state", problems)
shutil.rmtree(b)

print("arm (a): the classified key set against the literal")
b = tree([{"item_id": "aaa_ch_ff04", "years": THREE, "drop_keys": ("classified_2020",)}])
problems, _ = check_checksums(b, partial=True)
expect_problem("an item missing a classified year is refused", problems,
               "are not any sanctioned year set")
shutil.rmtree(b)

# The uniform loss #23 cannot see: EVERY item drops the same key, so the cross-item compare
# has nothing to disagree with. This is the whole reason the literal exists.
b = tree([{"item_id": "aaa_ch_ff04", "years": THREE, "drop_keys": ("classified_2020",)},
          {"item_id": "bbb_ch_ff04", "years": THREE, "drop_keys": ("classified_2020",)}])
problems, _ = check_checksums(b, partial=True)
expect_problem("a year lost from EVERY item is still refused — the uniform case (#23)",
               problems, "are not any sanctioned year set")
shutil.rmtree(b)

b = tree([{"item_id": "aaa_ch_ff04", "years": (2017, 2019, 2021, 2023)}])
problems, _ = check_checksums(b, partial=True)
expect_problem("an unsanctioned span is refused even though it is self-consistent",
               problems, "are not any sanctioned year set")
shutil.rmtree(b)

print("arm (d): the published assets against the COGs on disk")
# `aws s3 sync` uploads the DIRECTORY, not the asset list, so a stray COG reaches a public
# bucket described by nothing. Caught by no other guard in this repo.
b = tree([{"item_id": "aaa_ch_ff04", "years": THREE,
           "extra_files": ("classified_2019.tif",)}])
problems, _ = check_checksums(b, partial=True)
expect_problem("a COG on disk that no asset describes is refused", problems,
               "present-but-unpublished ['classified_2019']")
shutil.rmtree(b)

print("the fixed half is still compared across items")
b = tree([{"item_id": "aaa_ch_ff04", "years": THREE},
          {"item_id": "bbb_ch_ff04", "years": SEVEN, "drop_keys": ("style_transition",)}])
problems, _ = check_checksums(b, partial=True)
expect_problem("a dropped style asset is caught across two DIFFERENT populations", problems,
               "non-classified asset set differs from the other items")
shutil.rmtree(b)

print(f"\n{N} assertions, {FAILS} failed")
sys.exit(FAILS)
