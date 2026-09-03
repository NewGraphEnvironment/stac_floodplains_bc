#!/usr/bin/env python3
"""Generate QGIS layer styles (.qml) for the published GeoPackages.

Both styles derive from data/raw/classes.json -- the same table that feeds the
COG raster attribute table and the STAC `classification:classes` field -- so a
style can never disagree with the labels shipped inside the rasters, and both
move together when drift's class table changes.

Transition patches are coloured by DESTINATION class, which is how the published
transition COG is coloured. Colouring by anything else makes the vector and the
raster render the same data differently.

All vector symbols ship at 50% opacity (ALPHA), since these layers are read
over a basemap. Raster opacity is deliberately NOT handled here -- the COGs
already self-style from their RAT, and an opacity-only raster QML silently
wipes that palette. Tracked separately.

Outputs (into styles/):
  floodplain.qml
      Single blue fill for every layer of floodplain.gpkg, which carry no class
      attribute. A single-species group has three (`<sp>_ff02/04/06`); MORR has nine,
      including `<sp>_ff04_by_gnis_name` and `<sp>_ff0N_by_blue_line_key`.
  classified.qml
      Categorized on `class_name`. For the classified_<sp>_<scen>_<year> layers of
      floodplain_landcover.gpkg, and their `_patches` variants, which carry the same
      column. A multi-target group holds both species' layers in one file.
  transition.qml
      Categorized on `transition` ("Trees -> Rangeland"). Every Trees -> X
      category is switched on; every other origin ships switched off, so the
      full picture is a checkbox rather than a re-classify. For the `transition`
      layer of transition_vector.gpkg and for
      transition_<sp>_<scen>_<y1>_<y2> in floodplain_landcover.gpkg.

Usage:  uv run scripts/style_qml-write.py
"""

import json
import pathlib
import uuid
import xml.etree.ElementTree as ET

REPO = pathlib.Path(__file__).resolve().parent.parent
CLASSES = REPO / "data" / "raw" / "classes.json"
OUT = REPO / "styles"

# Written into the qml header. Matches the rfp style store so the two families
# load without a version-upgrade prompt.
QGIS_VERSION = "4.2.1-Belém do Pará"

# The origin class the transition style isolates on load. Every other pair,
# including the `<other> -> Trees` gain patches, ships present but switched off.
ORIGIN = "Trees"

# Symbol opacity on every generated vector style. These layers are read over a
# basemap, so they ship half-transparent rather than needing a per-user tweak.
ALPHA = "0.5"

# Single-symbol fill for the floodplain delineations, matching the hand-tuned
# reference (airvine, 2026-09-03): ColorBrewer Paired blue, no outline.
FLOODPLAIN_COLOR = "#1f78b4"

# QGIS wants a uuid on every symbol layer and category. `uuid4()` would make the
# generator non-deterministic — every run emits different bytes at identical length,
# so the committed styles could never be byte-compared and the embedded copy would
# churn `transition_vector.gpkg`'s published `file:checksum` on every rebuild. Caught
# by style_drift-check.py on its first run. Derive them instead: uuid5 over a fixed
# namespace and a stable key, so the same style always carries the same ids.
UUID_NS = uuid.UUID("6f3d1c8a-9b2e-5a47-8c31-2d5e7f0a4b69")


def sid(key):
    """A stable brace-wrapped uuid for `key`. Never uuid4 — see UUID_NS."""
    return "{" + str(uuid.uuid5(UUID_NS, key)) + "}"

# The separator the producer writes into the `transition` column. Verified
# against transition_vector.gpkg rather than assumed: "Trees -> Bare Ground".
SEP = " -> "


def rgba(hex_color, alpha=255):
    """'#419bdf' -> '65,155,223,255'."""
    h = hex_color.lstrip("#")
    return f"{int(h[0:2],16)},{int(h[2:4],16)},{int(h[4:6],16)},{alpha}"


def _ddp(parent, tag):
    d = ET.SubElement(parent, tag)
    o = ET.SubElement(d, "Option", type="Map")
    ET.SubElement(o, "Option", name="name", type="QString", value="")
    ET.SubElement(o, "Option", name="properties")
    ET.SubElement(o, "Option", name="type", type="QString", value="collection")


def fill_symbol(parent, name, color, outline_style="no",
                outline_width="0.26", outline_color="35,35,35,255",
                alpha=None, key=None):
    sym = ET.SubElement(parent, "symbol", alpha=(alpha or ALPHA),
                        clip_to_extent="1",
                        force_rhr="0", frame_rate="10", is_animated="0",
                        name=name, type="fill")
    _ddp(sym, "data_defined_properties")
    layer = ET.SubElement(sym, "layer")
    # `class` and `pass` are reserved words, so set them on attrib directly.
    layer.attrib.update({
        "class": "SimpleFill", "enabled": "1",
        "id": sid(key or f"layer/{name}/{color}"), "locked": "0", "pass": "0",
    })
    opt = ET.SubElement(layer, "Option", type="Map")
    for k, v in [
        ("border_width_map_unit_scale", "3x:0,0,0,0,0,0"),
        ("color", color),
        ("joinstyle", "bevel"),
        ("offset", "0,0"),
        ("offset_map_unit_scale", "3x:0,0,0,0,0,0"),
        ("offset_unit", "MM"),
        ("outline_color", outline_color),
        ("outline_style", outline_style),
        ("outline_width", outline_width),
        ("outline_width_unit", "MM"),
        ("style", "solid"),
    ]:
        ET.SubElement(opt, "Option", name=k, type="QString", value=v)
    _ddp(layer, "data_defined_properties")


def qgis_root():
    root = ET.Element("qgis", {
        "autoRefreshEnabled": "0", "autoRefreshMode": "Disabled",
        "autoRefreshTime": "0", "hasScaleBasedVisibilityFlag": "0",
        "labelsEnabled": "0", "layerType": "Vector", "maxScale": "0",
        "minScale": "100000000", "readOnly": "0", "simplifyAlgorithm": "0",
        "simplifyDrawingHints": "1", "simplifyDrawingTol": "1",
        "simplifyLocal": "1", "simplifyMaxScale": "1",
        "styleCategories": "AllStyleCategories",
        "symbologyReferenceScale": "-1", "version": QGIS_VERSION,
    })
    flags = ET.SubElement(root, "flags")
    for f, v in [("Identifiable", "1"), ("Removable", "1"),
                 ("Searchable", "1"), ("Private", "0")]:
        ET.SubElement(flags, f).text = v
    return root


def write(root, path, announce=True):
    """Serialise one style. `announce=False` for callers writing outside the repo
    (the drift check writes to a temp dir, where a repo-relative path cannot form)."""
    ET.indent(root, space="  ")
    # QGIS expects the XML declaration in a .qml. (Opposite of a GDAL PAM
    # .aux.xml sidecar, which GDAL silently ignores when one is present.)
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
    if announce:
        print(f"  wrote {path.relative_to(REPO)}")


def build_classified(classes):
    root = qgis_root()
    r = ET.SubElement(root, "renderer-v2", attr="class_name", enableorderby="0",
                      forceraster="0", referencescale="-1", symbollevels="0",
                      type="categorizedSymbol")
    cats = ET.SubElement(r, "categories")
    syms = ET.SubElement(r, "symbols")
    for i, c in enumerate(classes):
        ET.SubElement(cats, "category", label=c["class_name"], render="true",
                      symbol=str(i), type="string", value=c["class_name"])
        fill_symbol(syms, str(i), rgba(c["color"]), outline_style="no",
                    key=f"classified/sym/{c['class_name']}")
    return root, len(classes)


def build_transition(classes):
    names = [c["class_name"] for c in classes]
    if ORIGIN not in names:
        raise SystemExit(f"origin class {ORIGIN!r} absent from {CLASSES}")
    colour = {c["class_name"]: c["color"] for c in classes}

    # Every ordered pair except the no-change diagonal, which the producer
    # already excludes from the vector (verified: 0 rows where from = to).
    # Trees -> X first so the on-by-default entries head the legend.
    pairs = ([(ORIGIN, d) for d in names if d != ORIGIN]
             + [(o, d) for o in names if o != ORIGIN for d in names if d != o])

    root = qgis_root()
    r = ET.SubElement(root, "renderer-v2", attr="transition", enableorderby="0",
                      forceraster="0", referencescale="-1", symbollevels="0",
                      type="categorizedSymbol")
    cats = ET.SubElement(r, "categories")
    syms = ET.SubElement(r, "symbols")

    on = 0
    for i, (origin, dest) in enumerate(pairs):
        value = f"{origin}{SEP}{dest}"
        render = "true" if origin == ORIGIN else "false"
        on += render == "true"
        ET.SubElement(cats, "category", label=value, render=render,
                      symbol=str(i), type="string", value=value,
                      uuid=sid(f"transition/cat/{value}"))
        fill_symbol(syms, str(i), rgba(colour[dest]), outline_style="solid",
                    outline_width="0.16", outline_color="35,35,35,190",
                    key=f"transition/sym/{value}")

    # The bucket QGIS drops unmatched and NULL values into, shipped off.
    other = str(len(pairs))
    ET.SubElement(cats, "category", label="", render="false", symbol=other,
                  type="NULL", value="NULL",
                  uuid=sid("transition/cat/NULL"))
    fill_symbol(syms, other, "180,180,180,110", outline_style="solid",
                outline_width="0.16", outline_color="90,90,90,190",
                key="transition/sym/NULL")
    return root, on, len(pairs)


def build_floodplain():
    """One blue fill for the ff02 / ff04 / ff06 delineation layers.

    Single-symbol, so the same style serves all three scenario layers of
    floodplain.gpkg. No class attribute exists on them to categorize by.
    """
    root = qgis_root()
    r = ET.SubElement(root, "renderer-v2", enableorderby="0", forceraster="0",
                      referencescale="-1", symbollevels="0", type="singleSymbol")
    syms = ET.SubElement(r, "symbols")
    fill_symbol(syms, "0", rgba(FLOODPLAIN_COLOR), outline_style="no",
                key="floodplain/sym")
    return root


def build_all(classes):
    """Every style this repo ships, as {filename: ElementTree root}.

    The single entry point. `main()` writes these to `styles/`; the drift check
    re-runs it into a temp dir and byte-compares, so a `classes.json` that moved
    without `styles/` moving cannot reach a release.
    """
    root_t, on, total = build_transition(classes)
    root_c, n = build_classified(classes)
    return {"floodplain.qml": build_floodplain(),
            "classified.qml": root_c,
            "transition.qml": root_t}, dict(classes=n, on=on, total=total)


def main():
    classes = json.loads(CLASSES.read_text())["classes"]
    OUT.mkdir(exist_ok=True)

    write(build_floodplain(), OUT / "floodplain.qml")
    print(f"    single symbol {FLOODPLAIN_COLOR}, alpha {ALPHA}")

    root, n = build_classified(classes)
    write(root, OUT / "classified.qml")
    print(f"    {n} land-cover categories, io-lulc colours, alpha {ALPHA}")

    root, on, total = build_transition(classes)
    write(root, OUT / "transition.qml")
    print(f"    {total} transition categories, {on} on ({ORIGIN} -> *), "
          f"{total - on} off (gain included); destination-coloured, alpha {ALPHA}")

    print(f"  source: {CLASSES.relative_to(REPO)} ({len(classes)} classes)")


if __name__ == "__main__":
    main()
