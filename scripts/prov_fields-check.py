#!/usr/bin/env python3
"""prov_fields-check.py — prove item_validate.py's renamed-provenance arms fire (#74).

    uv run python scripts/prov_fields-check.py     # exit = number of failed assertions

#74 moved the twelve provenance fields off the `nge:` prefix onto `processing:datetime`,
`processing:software`, `link:*` and `landcover:*`, and stopped publishing an explicit null.
That retired the guard this repo leaned on hardest — set equality over the `nge:` key set —
and replaced it with a declared-key arm, a per-field census, a biconditional on the processing
extension, and a prefix table. None of those is reached by a normal build: the census and the
floor are release-only, and the COG-tag arms sit behind ~670 MB of real hashing.

Each case builds a tiny synthetic `data/stac`-shaped tree. The COG arms write real
single-pixel GeoTIFFs with real GDAL tags, because `check_cog_tags` opens the file.

Every assertion greps for ITS OWN message. A suite with N guards has N ways to return a
non-empty problem list, and every one of them looks the same to a check that counts.

Sibling of `year_sets-check.py` and `fp_provenance-check.R`; like them it is NOT wired into
`run_pipeline.sh`, because it exercises guards a normal build never trips.
"""

import ast
import hashlib
import json
import pathlib
import shutil
import sys
import tempfile

import numpy as np
import pystac
import rasterio

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from item_validate import (  # noqa: E402
    PROV_CENSUS, PROV_FIELDS, PROV_PROPERTIES, PROV_SOFTWARE, SOFTWARE_PROPERTY,
    SHARED_TAG_PROPERTIES, check_cog_tags, check_field_prefixes, check_processing_stamp,
    check_provenance,
)

ROOT = pathlib.Path(__file__).resolve().parent.parent
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

    Not `problems != []`: a fixture that trips the declared-key arm, the census and the
    prefix table at once reads identically to one that trips the arm being measured.
    """
    if not problems:
        bad(desc, "no problem reported")
    elif not any(needle in p for p in problems):
        bad(desc, f"a DIFFERENT arm fired: {problems[0][:160]}")
    else:
        ok(desc)


# --- fixtures --------------------------------------------------------------------------

# The staged values, by staged field name — what 01_stage.R writes into meta.json.
STAGED = {
    "link_run_uid": "20260901_234743-6628379d",
    "link_config_sha256": "sha256:19e3a0",
    "link_sha": "689146867a5f",
    "link_version": "0.50.0",
    "flooded_version": "0.5.0",
    "drift_version": "0.8.0",
    "produced_datetime": "2026-09-03T07:39:25Z",
    "landcover_source": "io-lulc",
    "landcover_collection": "io-lulc-annual-v02",
    "landcover_stac_url": "https://planetarycomputer.microsoft.com/api/stac/v1",
    "landcover_key": "sha256:97095d",
    "landcover_item_hash": "sha256:f83e23",
}
SHARED = {
    "wsg": "aaaa", "species": "ch", "scenario": "ff04", "region": "Test",
    "floodplain_ff02_km2": 1.0, "floodplain_ff04_km2": 2.0, "floodplain_ff06_km2": 3.0,
    "gross_loss_ha": 1.5, "gross_gain_ha": 0.5, "net_ha": -1.0,
}
PROCESSING_EXT = "https://stac-extensions.github.io/processing/v1.2.0/schema.json"
OTHER_EXTS = ["https://stac-extensions.github.io/projection/v1.1.0/schema.json",
              "https://stac-extensions.github.io/file/v2.1.0/schema.json",
              "https://stac-extensions.github.io/classification/v2.0.0/schema.json"]


def publish(staged: dict) -> dict:
    """What item_create.py would publish for these staged values.

    A deliberate mirror of the writer, not an import: importing item_create.py runs the whole
    build. The two are tied together statically by `the two copies of the map` case below,
    which parses both files rather than trusting this function.
    """
    props = {}
    for field, prop in PROV_PROPERTIES.items():
        if staged.get(field) is not None:
            props[prop] = staged[field]
    software = {}
    for entry, fields in PROV_SOFTWARE.items():
        values = [staged.get(f) for f in fields]
        if all(v is None for v in values):
            continue
        software[entry] = "+".join("" if v is None else str(v) for v in values)
    if software:
        props[SOFTWARE_PROPERTY] = software
    return props


def write_item(base: pathlib.Path, item_id: str, staged: dict | None = None, *,
               props_extra: dict = (), asset_extra: dict = (), cog: bool = False,
               tags_override: dict = (), exts: list | None = None,
               shared: bool = True) -> None:
    """One item, optionally with a real tagged GeoTIFF beside it."""
    staged = STAGED if staged is None else staged
    props = {"datetime": "2023-12-31T00:00:00Z"}
    if shared:
        props.update(SHARED)
    props.update(publish(staged))
    props.update(dict(props_extra))
    if exts is None:
        exts = list(OTHER_EXTS)
        if any(k.startswith("processing:") for k in props):
            exts.append(PROCESSING_EXT)
    assets = {}
    if cog:
        d = base / item_id
        d.mkdir(parents=True, exist_ok=True)
        name = "transition_2017_2023.tif"
        tags = {f"NGE_{f.upper()}": str(v) for f, v in staged.items() if v is not None}
        nulls = sorted(f for f in PROV_FIELDS if staged.get(f) is None)
        if nulls:
            tags["NGE_PROVENANCE_NULL"] = ",".join(nulls)
        if shared:
            tags.update({k.upper(): str(v) for k, v in SHARED.items()})
        tags.update(dict(tags_override))
        with rasterio.open(d / name, "w", driver="GTiff",
                           width=1, height=1, count=1, dtype="uint8") as ds:
            ds.write(np.zeros((1, 1), dtype="uint8"), 1)
            ds.update_tags(**tags)
        payload = (d / name).read_bytes()
        assets["transition_2017_2023"] = {
            "href": f"https://example.invalid/{item_id}/{name}",
            "type": pystac.MediaType.COG,
            "file:checksum": "1220" + hashlib.sha256(payload).hexdigest(),
            "file:size": len(payload),
            **dict(asset_extra),
        }
    (base / f"{item_id}.json").write_text(json.dumps(
        {"type": "Feature", "id": item_id, "stac_extensions": exts,
         "properties": props, "assets": assets}))


def tree(items) -> pathlib.Path:
    base = pathlib.Path(tempfile.mkdtemp(prefix="prov_fields_"))
    for kwargs in items:
        write_item(base, **kwargs)
    return base


def without(*fields) -> dict:
    return {f: (None if f in fields else v) for f, v in STAGED.items()}


NONE_STAGED = {f: None for f in PROV_FIELDS}
# The three populations the live catalogue actually carries, measured 2026-10-13: 18 items
# with all twelve, 3 missing only link_run_uid, 2 with none. A fixture that covered only the
# first two would never reach the all-absent arms, which is where the NGE_PROVENANCE_NULL
# derivation and the conditional extension both live.
def catalogue() -> list[dict]:
    items = [{"item_id": f"full{i:02d}_ch_ff04"} for i in range(18)]
    items += [{"item_id": f"part{i:02d}_bt_ff04", "staged": without("link_run_uid")}
              for i in range(3)]
    items += [{"item_id": f"none{i:02d}_ch_ff04", "staged": NONE_STAGED} for i in range(2)]
    return items


# --- the literals themselves -----------------------------------------------------------

print("the literals")
# Every case below reads the census, so what it says is asserted rather than assumed.
expect_clean("PROV_CENSUS matches the live catalogue measured for this release",
             [] if (PROV_CENSUS["link_run_uid"] == 18
                    and {PROV_CENSUS[f] for f in PROV_FIELDS if f != "link_run_uid"} == {21})
             else [f"PROV_CENSUS is {PROV_CENSUS}"])


def literal(path: pathlib.Path, name: str):
    """A module-level literal, read statically — the two copies of the map cannot import."""
    for node in ast.parse(path.read_text()).body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, "id", None) == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise SystemExit(f"{path.name}: no module-level literal {name}")


# The three copies of the field list are deliberately not shared (a guard that imports the
# value it checks is x == x), so something has to join them. test_pipeline.R joins staging to
# the item; this joins the publish map to the writer and to the COG tags. A field dropped from
# BOTH sides of a pair is invisible to every runtime arm.
_create_props = literal(ROOT / "scripts" / "item_create.py", "PROV_PROPERTIES")
_create_software = literal(ROOT / "scripts" / "item_create.py", "PROV_SOFTWARE")
_tag_fields = literal(ROOT / "scripts" / "02_raster_tag.py", "PROV_FIELDS")
expect_clean("item_create.py and item_validate.py publish the same map",
             [] if (_create_props == PROV_PROPERTIES
                    and {k: tuple(v) for k, v in _create_software.items()} == PROV_SOFTWARE)
             else [f"item_create.py says {_create_props} / {_create_software}"])
expect_clean("02_raster_tag.py tags exactly the fields the map publishes",
             [] if set(_tag_fields) == set(PROV_FIELDS)
             else [f"02_raster_tag.py tags {sorted(set(_tag_fields) ^ set(PROV_FIELDS))} "
                   f"differently"])

# --- controls --------------------------------------------------------------------------

print("controls (a guard that has never passed is as untested as one that never fired)")
b = tree(catalogue())
problems, traced, seen, per_section = check_provenance(b, floor=21)
expect_clean("the three live populations pass the census and the floor", problems)
expect_clean("...with 21 of 23 carrying provenance",
             [] if (traced, seen) == (21, 23) else [f"traced={traced} seen={seen}"])
expect_clean("...and every section counted",
             [] if per_section == {"network": 21, "floodplain": 21, "landcover": 21}
             else [str(per_section)])
expect_clean("...no undeclared prefixes", check_field_prefixes(b))
expect_clean("...and the processing extension paired on every item", check_processing_stamp(b))
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "cog": True},
          {"item_id": "none_ch_ff04", "staged": NONE_STAGED, "cog": True}])
expect_clean("COG tags agree with the item, with and without provenance", check_cog_tags(b))
shutil.rmtree(b)

# --- the declared-key arm --------------------------------------------------------------

print("declared keys: what survives of the retired key-set equality")
b = tree([{"item_id": "aaaa_ch_ff04", "props_extra": {"landcover:sourc": "io-lulc"}}])
problems, *_ = check_provenance(b)
expect_problem("a typo under an ALLOWED prefix is refused", problems,
               "does not declare")
expect_clean("...and the prefix table alone cannot see it", check_field_prefixes(b))
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "props_extra": {"processing:level": "L3"}}])
problems, *_ = check_provenance(b)
expect_problem("a processing: field this build does not publish is refused", problems,
               "does not declare")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04",
           "props_extra": {SOFTWARE_PROPERTY: {**publish(STAGED)[SOFTWARE_PROPERTY],
                                               "gdal": "3.12.0"}}}])
problems, *_ = check_provenance(b)
expect_problem("an undeclared software entry name is refused", problems,
               "undeclared entry name")
shutil.rmtree(b)

b = pathlib.Path(tempfile.mkdtemp(prefix="prov_fields_"))
problems, *_ = check_provenance(b, floor=21)
expect_problem("an empty tree is not a pass", problems, "was not actually checked against")
shutil.rmtree(b)

# --- the census ------------------------------------------------------------------------

print("the census: the arm that replaced set equality")
# The uniform loss #23 could not see and #74 would otherwise have re-opened: EVERY item loses
# the same field, so nothing is left to compare against.
b = tree([dict(kw, staged=without("link_run_uid", "landcover_key"))
          if "staged" not in kw else kw for kw in catalogue()])
problems, *_ = check_provenance(b, floor=21)
expect_problem("a field lost on every item is refused", problems,
               "PROV_CENSUS says 21")
expect_clean("...and NOT on a rebuild, where no release expectation applies",
             check_provenance(b, floor=None)[0])
shutil.rmtree(b)

# One item, one field: the shape the floor and the section counts both wave through.
items = catalogue()
items[0] = {"item_id": "full00_ch_ff04", "staged": without("landcover_key")}
b = tree(items)
problems, traced, _, _ = check_provenance(b, floor=21)
expect_problem("one field lost on ONE item is refused", problems, "PROV_CENSUS says 21")
expect_clean("...which the item-level floor cannot see on its own",
             [] if traced == 21 else [f"traced={traced}"])
shutil.rmtree(b)

# A whole section lost on every item — passed every arm before #74, because the floor was
# still met by the surviving sections and the per-section counts were only printed.
b = tree([dict(kw, staged=without("landcover_source", "landcover_collection",
                                  "landcover_stac_url", "landcover_key",
                                  "landcover_item_hash", "drift_version",
                                  "produced_datetime"))
          if "staged" not in kw else kw for kw in catalogue()])
problems, *_ = check_provenance(b, floor=21)
expect_problem("a whole section lost on every item is refused", problems, "PROV_CENSUS says")
shutil.rmtree(b)

b = tree(catalogue() + [{"item_id": "zzzz_ch_ff04"}])
problems, *_ = check_provenance(b, floor=21)
expect_problem("a census behind the build is refused, naming the number to set", problems,
               "set it to 22")
shutil.rmtree(b)

print("the floor, beside the census rather than derived from it")
b = tree(catalogue())
expect_problem("a floor behind the build is refused", check_provenance(b, floor=20)[0],
               "the floor is behind the build")
expect_problem("a floor ahead of the build is refused", check_provenance(b, floor=22)[0],
               "the release floor is 22")
shutil.rmtree(b)

# --- the prefix table ------------------------------------------------------------------

print("the prefix table: a resurrected nge: key")
b = tree([{"item_id": "aaaa_ch_ff04", "props_extra": {"nge:link_run_uid": "u"}}])
expect_problem("an nge: property is refused", check_field_prefixes(b),
               "is not declared in FIELD_PREFIXES")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "cog": True, "asset_extra": {"nge:kept": "same"}}])
expect_problem("an nge: ASSET field is refused too", check_field_prefixes(b),
               "is not declared in FIELD_PREFIXES")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "exts": list(OTHER_EXTS)}])
expect_problem("a processing: field with the extension absent is refused",
               check_field_prefixes(b), "does not declare")
shutil.rmtree(b)

# --- the processing extension ----------------------------------------------------------

print("the processing extension, both directions")
b = tree([{"item_id": "aaaa_ch_ff04", "exts": list(OTHER_EXTS)}])
expect_problem("...and reported as half-applied", check_processing_stamp(b),
               "processing extension half-applied")
shutil.rmtree(b)

b = tree([{"item_id": "none_ch_ff04", "staged": NONE_STAGED,
           "exts": OTHER_EXTS + [PROCESSING_EXT]}])
expect_problem("the extension declared with no processing: field is refused",
               check_processing_stamp(b), "no processing: field")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "props_extra": {SOFTWARE_PROPERTY: {}}}])
expect_problem("an empty software map is refused", check_processing_stamp(b),
               "is empty")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04",
           "props_extra": {SOFTWARE_PROPERTY: {"link": "+689146867a5f",
                                               "flooded": "0.5.0", "drift": "0.8.0"}}}])
expect_problem("a half-present version+sha pair is refused", check_processing_stamp(b),
               "expected <version>+<sha>")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04",
           "props_extra": {SOFTWARE_PROPERTY: {"link": "0.50.0+abc", "flooded": 5,
                                               "drift": "0.8.0"}}}])
expect_problem("a non-string entry value is refused", check_processing_stamp(b),
               "expected a non-empty string")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04",
           "staged": {**STAGED, "produced_datetime": "2026-09-03T07:39:25"}}])
expect_problem("a datetime with no UTC designator is refused", check_processing_stamp(b),
               "pins a UTC designator")
shutil.rmtree(b)

# --- the COG tags ----------------------------------------------------------------------

print("the COG tags, bridged through the map")
for tag in ("NGE_LINK_VERSION", "NGE_LINK_SHA"):
    b = tree([{"item_id": "aaaa_ch_ff04", "cog": True, "tags_override": {tag: "tampered"}}])
    expect_problem(f"{tag} perturbed is caught by the reassembly", check_cog_tags(b),
                   "reassemble to")
    shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "cog": True,
           "tags_override": {"NGE_PRODUCED_DATETIME": "2020-01-01T00:00:00Z"}}])
expect_problem("a plain tag perturbed is caught by the diff", check_cog_tags(b),
               "GDAL tags disagree")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "cog": True,
           "tags_override": {"NGE_LANDCOVER_KEY": None}}])
# None drops the tag on write, so this is the "tag went missing" direction, which only the
# union with the COG's own keys can see in one direction and `want` in the other.
expect_problem("a tag missing from the COG is caught", check_cog_tags(b),
               "GDAL tags disagree")
shutil.rmtree(b)

# The arm that a mechanical port of the old `v is None` derivation silences: with no null
# properties left to find, NGE_PROVENANCE_NULL would never enter `want` and this tag could
# hold anything. It is also the only tag the two all-absent items carry at all.
b = tree([{"item_id": "none_ch_ff04", "staged": NONE_STAGED, "cog": True,
           "tags_override": {"NGE_PROVENANCE_NULL": "garbage"}}])
expect_problem("NGE_PROVENANCE_NULL overwritten on an all-absent item is caught",
               check_cog_tags(b), "NGE_PROVENANCE_NULL")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04", "cog": True, "shared": False}])
expect_problem("a missing shared property is reported as unverifiable", check_cog_tags(b),
               "so its GDAL tag cannot be verified")
shutil.rmtree(b)

b = tree([{"item_id": "aaaa_ch_ff04"}])
expect_problem("a tree with no COG asset is not a pass", check_cog_tags(b),
               "no COG assets compared")
shutil.rmtree(b)

print(f"\n{N} assertions, {FAILS} failed")
sys.exit(FAILS)
