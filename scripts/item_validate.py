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
import rasterio
from rio_cogeo.cogeo import cog_validate


MULTIHASH_SHA256 = "1220"

# Run provenance (#17). Declared here as an ABSOLUTE set, deliberately duplicating
# 05_stac_register.py's PROV_FIELDS rather than importing it — importing that module
# would run the entire build, since it is a script and not a library.
REQUIRED_NGE_PROPERTIES = {
    "nge:link_run_uid", "nge:link_config_sha256", "nge:link_sha", "nge:link_version",
    "nge:flooded_version", "nge:drift_version", "nge:produced_datetime",
    "nge:landcover_source", "nge:landcover_collection", "nge:landcover_stac_url",
    "nge:landcover_key",
}


def check_provenance(base: Path) -> list[str]:
    """Verify every item carries every `nge:` provenance KEY. Null values are fine.

    Absolute, not comparative. The asset check below compares items against each other,
    which is structurally blind to a defect that hits all of them uniformly — the exact
    hole #23 fell into. If the staging reader silently found nothing and every item lost
    the same properties, a cross-item check sees no variance and passes, and pystac's
    schema validation cannot see custom properties at all. So the required set is named
    here rather than derived from the data.

    Set EQUALITY, not containment: a property added to 05_stac_register.py without being
    declared here fails too, which is what keeps the two lists in step now that they
    cannot import from one another.

    A null VALUE is expected and allowed — floodplains#33 is forward-only, so an area
    modelled before it lands has no provenance to carry, and publishing the null is the
    point of the issue. Only an absent KEY is a failure.
    """
    problems: list[str] = []
    seen = 0
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        seen += 1
        found = {k for k in doc.get("properties", {}) if k.startswith("nge:")}
        if found != REQUIRED_NGE_PROPERTIES:
            problems.append(
                f"{doc['id']}: nge: property set differs from the declared contract — "
                f"missing {sorted(REQUIRED_NGE_PROPERTIES - found) or 'none'}, "
                f"undeclared {sorted(found - REQUIRED_NGE_PROPERTIES) or 'none'}")
    # Zero items is not a pass. The loop above would report nothing at all for an empty
    # or wrongly-pointed directory, which reads identically to "every item checked out".
    if seen == 0:
        problems.append(
            f"no items found under {base}/*.json — the provenance contract was not "
            f"actually checked against anything")
    return problems


def check_cog_tags(base: Path) -> list[str]:
    """Verify each COG's NGE_ tags agree with its item's non-null `nge:` properties.

    03_cog_tag.py keeps its own copy of the field list, and nothing else in the repo reads
    a COG — so before this check, adding a twelfth field and forgetting that copy would
    ship silently incomplete COGs. Every other copy of the list is tied to another
    (fp_provenance.R stopifnot, 05/item_validate set equality); this was the one with no
    guard in the add direction.

    Compares against the ITEM, not against a second hardcoded list, so the assertion
    cannot drift from what was published.
    """
    problems: list[str] = []
    compared = 0
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc["id"]
        props = doc.get("properties", {})
        # A null property is deliberately NOT tagged: GDAL metadata is string-only and has
        # no null, so 03 encodes absence as the empty string, which GDAL drops on read.
        want = {f"NGE_{k[len('nge:'):].upper()}": str(v)
                for k, v in props.items() if k.startswith("nge:") and v is not None}
        # NGE_PROVENANCE_NULL is included, not excluded. Until floodplains#33 lands it is
        # the ONLY NGE_ tag on a COG — every value tag is absent — so excluding it made
        # this check compare {} against {} for every item in exactly the state the repo
        # expects to be in. Measured: the tag could be overwritten with garbage and the
        # check still passed. It is derivable from the item for free.
        nulls = sorted(k[len("nge:"):] for k, v in props.items()
                       if k.startswith("nge:") and v is None)
        if nulls:
            want["NGE_PROVENANCE_NULL"] = ",".join(nulls)
        for asset in doc.get("assets", {}).values():
            # Compare against pystac's own constant, the same one 05_stac_register.py
            # writes from. A duplicated media-type literal drifting by a single character
            # would silently match no assets and pass.
            if asset.get("type") != pystac.MediaType.COG:
                continue
            local = base / item_id / PurePosixPath(urlparse(asset["href"]).path).parts[-1]
            if not local.is_file():
                continue  # missing assets are already reported by check_checksums
            compared += 1
            with rasterio.open(local) as ds:
                tags = ds.tags()
            got = {k: v for k, v in tags.items() if k.startswith("NGE_")}
            if got != want:
                # Report differing VALUES as well as differing keys. A key-set-only
                # message reads "missing none, unexpected none" when a value is wrong,
                # which is a guard that fires and then says nothing — verified by
                # tampering with a tag before trusting this check.
                changed = [f"{k}: tag {got.get(k)!r} vs property {want.get(k)!r}"
                           for k in sorted(set(got) | set(want)) if got.get(k) != want.get(k)]
                problems.append(
                    f"{item_id}/{local.name}: NGE_ tags disagree with the item's nge: "
                    f"properties — {'; '.join(changed)}")
    # Zero comparisons is not a pass. Same reasoning as check_provenance's seen == 0: a
    # loop over nothing prints nothing and returns clean, which is indistinguishable from
    # every COG having checked out.
    if compared == 0:
        problems.append(
            f"no COG assets compared under {base} — the NGE_ tag contract was not "
            f"actually checked against anything")
    return problems


def check_cog_layout(base: Path) -> list[str]:
    """Verify every published COG actually has cloud-optimized layout.

    A COG's whole advantage is that a client reads a small header, then fetches only the
    tiles it needs. That depends on the main IFD sitting at the FRONT of the file — and
    an in-place metadata write moves it to the end, silently. Nothing else in this repo
    looks at layout: the bytes are a valid GeoTIFF, every `file:checksum` verifies against
    them, and the file opens correctly in QGIS. Only the range-request property is gone.

    Measured before this guard existed: the main IFD sat at byte 595,868 of a 602,582-byte
    classified COG and 1,330,104 of a 1,335,328-byte transition COG — 98.9% and 99.6% of
    each file had to be fetched to read a header.
    """
    problems: list[str] = []
    checked = 0
    for path in sorted(base.glob("*.json")):
        doc = json.loads(path.read_text())
        if doc.get("type") != "Feature":
            continue
        item_id = doc["id"]
        for asset in doc.get("assets", {}).values():
            if asset.get("type") != pystac.MediaType.COG:
                continue
            local = base / item_id / PurePosixPath(urlparse(asset["href"]).path).parts[-1]
            if not local.is_file():
                continue  # missing assets are already reported by check_checksums
            checked += 1
            valid, errors, _warnings = cog_validate(local)
            if not valid:
                problems.append(
                    f"{item_id}/{local.name}: not a valid COG — "
                    f"{'; '.join(errors or ['no detail'])}")
    # Zero comparisons is not a pass, same reasoning as the sibling checks: a loop over
    # nothing returns clean, which reads identically to every COG having checked out.
    if checked == 0:
        problems.append(
            f"no COG assets found under {base} — the layout contract was not actually "
            f"checked against anything")
    return problems


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

    # --- run provenance: does every item carry the declared nge: contract? ---
    missing_prov = check_provenance(args.base)
    if missing_prov:
        print(f"FAILED: {len(missing_prov)} provenance contract problem(s)",
              file=sys.stderr)
        for msg in missing_prov:
            print(f"  {msg}", file=sys.stderr)
        return 1
    bad_tags = check_cog_tags(args.base)
    if bad_tags:
        print(f"FAILED: {len(bad_tags)} COG provenance-tag problem(s)", file=sys.stderr)
        for msg in bad_tags:
            print(f"  {msg}", file=sys.stderr)
        return 1
    print(f"provenance: {len(REQUIRED_NGE_PROPERTIES)} nge: properties on every item, "
          f"COG tags agree")

    # --- COG layout: is the range-request property the format promises actually there? ---
    bad_layout = check_cog_layout(args.base)
    if bad_layout:
        print(f"FAILED: {len(bad_layout)} COG layout problem(s)", file=sys.stderr)
        for msg in bad_layout:
            print(f"  {msg}", file=sys.stderr)
        return 1
    print("cog layout: valid on every COG")

    return 0


if __name__ == "__main__":
    sys.exit(main())
