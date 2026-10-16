#!/usr/bin/env python3
"""style_reach-check.py — ask QGIS what it actually DRAWS for each published layer (#95).

Every other style check in this repo reads the row it wrote. `style_drift-check.py`
compares the committed QML against `classes.json` with the same reader on both sides;
`item_validate.py` parses the `styleQML` blob it embedded. Both passed on all 23 items
while every `floodplain_landcover.gpkg` shipped a style QGIS could not reach — the
"verification that reads its own output" shape, and the reason this file exists.

WHY IT IS NOT REDUNDANT WITH `test_pipeline.R`

`test_pipeline.R` asserts that GDAL LISTS `layer_styles` (`sf::st_layers()`), which is the
predicate #95 turns on: the GPKG driver's `LIST_ALL_TABLES=AUTO` default surfaces an
unregistered table only while the file declares no aspatial content. That arm is necessary
and **not sufficient** — the NULL `f_table_schema` trap that `04_gpkg_style.py`'s first
bullet documents is the standing proof that a listed, well-formed style row still opens
unstyled, because QGIS matches that column with `= ''` and NULL never equals anything. Only the real consumer answers "what is on screen".

So the three layers are, deliberately, three different questions:

    item_validate.py       is the row there, `attributes`, pinned          every build
    test_pipeline.R        does GDAL list the table                        the smoke test
    style_reach-check.py   what renderer does QGIS build from it           by hand

NOT RUN BY `run_pipeline.sh`

PyQGIS is not in this repo's `uv` env and cannot be (`osgeo` has no usable wheel under uv),
so this joins `fp_provenance-check.R`, `stage_years-check.R`, `year_sets-check.py` and
`prov_fields-check.py` — the checks a normal build never runs. It needs the QGIS bundle's
own interpreter:

    R=/Applications/QGIS-final-4_2_1.app/Contents/Resources
    PROJ_DATA="$R/qgis/proj" PROJ_LIB="$R/qgis/proj" GDAL_DATA="$R/qgis/gdal" \\
    PYTHONPATH="$R/python3.12:$R/python3.12/site-packages:$R/python3.12/lib-dynload" \\
    QT_QPA_PLATFORM=offscreen \\
      /Applications/QGIS-final-4_2_1.app/Contents/MacOS/python3.12 \\
      scripts/style_reach-check.py

    ITEM=bulk_all_ff04 ... scripts/style_reach-check.py    # any staged item

The three data paths are not optional: without `PROJ_DATA`/`PROJ_LIB` every call floods
`Cannot find proj.db` and CRS handling degrades without failing. `PYTHONHOME` does not
work — the bundle's stdlib is at `Resources/python3.12`, not the `Resources/lib/python3.12`
that PYTHONHOME implies. `QT_QPA_PLATFORM=offscreen` keeps it off a display.

THE COLD ARM IS LANDCOVER-ONLY, AND THAT IS NOT LAZINESS

De-registering `layer_styles` in `floodplain.gpkg` or `transition_vector.gpkg` returns them
to a state where AUTO still lists the table and QGIS still finds the style, because neither
carries an aspatial table. A per-bundle cold arm would report two false failures. The
discriminator is the producer's `patch_watercourse_*` / `composition_*`, which only
`floodplain_landcover.gpkg` holds.

Reads a staged tree; writes only to a temp directory. Never touches `data/`.
"""

import ast
import importlib.util
import os
import pathlib
import re
import shutil
import sqlite3
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_PREFIX = "/Applications/QGIS-final-4_2_1.app"

# The writer's own style map, imported rather than restated: it is the file that decides
# which layer gets which style, and it is stdlib-only, so QGIS's python can load it. The
# filename starts with a digit, so a plain import will not reach it.
_spec = importlib.util.spec_from_file_location(
    "gpkg_style", REPO / "scripts" / "04_gpkg_style.py")
_gs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_gs)

# What QGIS must build, keyed by the style's own name. A FOURTH copy of a fact
# `item_validate.py` already holds — unavoidable, because that module imports pystac and
# rasterio and QGIS's interpreter has neither — so the two are tied together statically
# below instead, the shape `prov_fields-check.py` uses over the four publish-side copies.
EXPECT_RENDERER = {"floodplain": "singleSymbol",
                   "classified": "categorizedSymbol",
                   "transition": "categorizedSymbol"}
EXPECTED_STYLE_CATEGORIES = {"classified": 10, "transition": 91}

ITEM_VALIDATE = REPO / "scripts" / "item_validate.py"
STYLE_DIR = REPO / "styles"


def expected_opacity() -> float:
    """The symbol opacity the committed QMLs carry, read rather than restated.

    THE RENDERER TYPE ALONE CANNOT FAIL FOR `floodplain.gpkg`, which is why this exists.
    `EXPECT_RENDERER["floodplain"]` is `singleSymbol`, and `singleSymbol` is also what QGIS
    builds for a layer with no style at all — so four of this script's nine assertions passed
    identically whether that bundle's style was reachable, unreachable or absent. Measured
    2026-10-16 on `all_ff04`: styled gives `#1f78b4` at opacity 0.5, the same file with
    `layer_styles` dropped and de-registered gives a random colour at opacity 1.0. The
    "fixture that cannot reach the failure mode" shape, in the one probe whose whole job is
    to reach it — and on the bundle the "register all three" argument is pre-emptive for, so
    nothing else would have caught it either.

    Opacity is the discriminator rather than colour because it is uniform across all three
    styles and all 102 symbols, so one assertion covers all nine layers. Read from
    `styles/*.qml` and not hardcoded: those are the reviewed artifact, `item_validate.py`
    already proves the embedded blob equals them byte for byte, and a number restated here
    would be a third copy. Refuses on more than one distinct value, since then "the style
    QGIS applied" has no single expected opacity and this arm would be asserting a coincidence.
    """
    vals: set[str] = set()
    for qml in sorted(STYLE_DIR.glob("*.qml")):
        vals |= set(re.findall(r'alpha="([0-9.]+)"', qml.read_text(encoding="utf-8")))
    if len(vals) != 1:
        raise SystemExit(
            f"the committed styles carry {len(vals)} distinct symbol opacities "
            f"({sorted(vals)}) — this check compares QGIS's symbols against one expected "
            f"value, and cannot tell a styled layer from an unstyled one without it")
    opacity = float(vals.pop())
    # The arm's discriminating power is a property of this VALUE, not of the comparison:
    # 1.0 is what QGIS gives an unstyled layer, so a style shipped at full opacity would
    # silently return the four `singleSymbol` assertions to the no-op they were before #95,
    # with the renderer-type arm already unable to tell the difference and nothing saying so.
    # Refused rather than tolerated, for the same reason as the multi-value case above.
    if opacity == 1.0:
        raise SystemExit(
            "the committed styles ship at opacity 1.0, which is also QGIS's default for an "
            "UNSTYLED layer — so this check could no longer tell a reachable style from no "
            "style on the single-symbol bundle. Give the opacity arm a different "
            "discriminator (symbol colour) before shipping a full-opacity style")
    return opacity


def literal(path: pathlib.Path, name: str):
    """A literal read statically, from anywhere in the module.

    `ast.walk` rather than a scan of `module.body`: `EXPECT_RENDERER` is defined INSIDE
    `check_layer_styles`, so a module-level scan finds nothing and the arm that compares
    the two copies would pass by never running.
    """
    for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
        if isinstance(node, ast.Assign) and any(
                getattr(t, "id", None) == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise SystemExit(f"{path.name}: no literal {name} — the copies cannot be compared, and "
                     f"a comparison that finds nothing is not a match")


def feature_layers(path: pathlib.Path) -> list[str]:
    """The file's feature layers, with the style table excluded by name as well.

    The second copy of a shape found in `04_gpkg_style.py`: a registration arriving with
    `data_type='features'` — a hand edit, or another writer — would otherwise put the style
    table into this list, and `style_kind()` then raises `SystemExit` from inside the warm
    loop, discarding every failure already collected. Fixing one copy and not the other is
    how the first instance got here.
    """
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return [r[0] for r in con.execute(
            "SELECT table_name FROM gpkg_contents WHERE data_type = 'features' "
            "AND table_name <> ? ORDER BY table_name", (_gs.STYLE_TABLE,))]
    finally:
        con.close()


def style_kind(gpkg: pathlib.Path, layer: str) -> str:
    """Which style the writer gave this layer, as a bare kind (`classified`, ...)."""
    qml = _gs.FILE_STYLES[gpkg.name](layer)
    if qml is None:
        raise SystemExit(
            f"{gpkg.name} layer '{layer}' matches no style rule in 04_gpkg_style.py — this "
            f"check cannot say what QGIS should draw for a layer the writer refuses")
    return pathlib.Path(qml).stem


def renderer_of(gpkg: pathlib.Path, layer: str):
    """(renderer type, category count or None, symbol opacities) for a PLAIN open.

    No `.qml` handed over: `QgsVectorLayer` loads the provider's default style by default,
    which for a GeoPackage is the `layer_styles` row — reached through GDAL's layer list,
    which is the whole point.

    The opacities are what make the `singleSymbol` arms able to fail; see
    `expected_opacity()`. `symbols()` takes a `QgsRenderContext()` and not `None`.
    """
    from qgis.core import QgsRenderContext, QgsVectorLayer
    vl = QgsVectorLayer(f"{gpkg}|layername={layer}", layer, "ogr")
    if not vl.isValid():
        return None, None, set()
    r = vl.renderer()
    if r is None:
        return None, None, set()
    rtype = r.type()
    n = len(r.categories()) if rtype == "categorizedSymbol" else None
    opacities = {round(s.opacity(), 4) for s in r.symbols(QgsRenderContext())}
    return rtype, n, opacities


def main() -> int:
    prefix = pathlib.Path(os.environ.get("QGIS_PREFIX", DEFAULT_PREFIX))
    if not prefix.is_dir():
        raise SystemExit(
            f"no QGIS bundle at {prefix} — set QGIS_PREFIX. Refusing rather than running "
            f"half of this check, because a skipped consumer probe is exactly what let #95 "
            f"ship")
    try:
        from qgis.core import QgsApplication
    except ImportError as exc:
        raise SystemExit(
            f"PyQGIS is not importable ({exc}) — run this with the QGIS bundle's own "
            f"python3.12 and the PROJ_DATA/PROJ_LIB/GDAL_DATA/PYTHONPATH recipe in this "
            f"file's docstring, not with `uv run`") from exc

    # Same default as the two determinism checks, so all three exercise one tree unless
    # told otherwise.
    item = os.environ.get("ITEM", "sloc_all_ff04")
    src_dir = REPO / "data" / "stac" / item
    missing = [g for g in sorted(_gs.FILE_STYLES) if not (src_dir / g).exists()]
    if missing:
        raise SystemExit(
            f"no staged bundle at {src_dir} (missing {', '.join(missing)}) — run "
            f"scripts/run_pipeline.sh first, or set ITEM=")

    failures: list[str] = []

    # The two copies of the renderer expectation, joined by nothing else. Full equality,
    # not containment: token overlap would let them drift while still sharing enough to
    # pass.
    for name, mine in (("EXPECT_RENDERER", EXPECT_RENDERER),
                       ("EXPECTED_STYLE_CATEGORIES", EXPECTED_STYLE_CATEGORIES)):
        theirs = literal(ITEM_VALIDATE, name)
        if theirs != mine:
            failures.append(
                f"{name} here is {mine!r} but {ITEM_VALIDATE.name} holds {theirs!r} — the "
                f"two copies have drifted and one of the two checks is asserting the wrong "
                f"thing")

    QgsApplication.setPrefixPath(str(prefix / "Contents" / "MacOS"), True)
    app = QgsApplication([], False)
    app.initQgis()
    try:
        checked = 0
        want_opacity = expected_opacity()
        print(f"item: {item}   QGIS prefix: {prefix}   expected symbol opacity: "
              f"{want_opacity}")

        # --- warm: every styled layer, opened plain -------------------------------
        for gname in sorted(_gs.FILE_STYLES):
            gpkg = src_dir / gname
            layers = feature_layers(gpkg)
            if not layers:
                failures.append(
                    f"{gname} declares no feature layers — a bundle with nothing to style "
                    f"makes every assertion below it vacuous")
                continue
            for layer in layers:
                kind = style_kind(gpkg, layer)
                rtype, n, opac = renderer_of(gpkg, layer)
                checked += 1
                want = EXPECT_RENDERER[kind]
                ok = (rtype == want and opac == {want_opacity}
                      and (n == EXPECTED_STYLE_CATEGORIES[kind]
                           if kind in EXPECTED_STYLE_CATEGORIES else True))
                print(f"  {gname:26} {layer:40} {kind:11} "
                      f"{rtype or 'NO RENDERER'}{'' if n is None else f' ({n})'} "
                      f"opacity={sorted(opac) or '-'} {'ok' if ok else 'WRONG'}")
                if rtype is None:
                    failures.append(
                        f"{gname}/{layer}: QGIS built no renderer — the layer did not open")
                    continue
                if rtype != want:
                    failures.append(
                        f"{gname}/{layer}: QGIS draws it with {rtype!r}, expected {want!r} "
                        f"— the embedded style is not what the consumer gets")
                    continue
                if kind in EXPECTED_STYLE_CATEGORIES and \
                        n != EXPECTED_STYLE_CATEGORIES[kind]:
                    failures.append(
                        f"{gname}/{layer}: QGIS built {n} categories, expected "
                        f"{EXPECTED_STYLE_CATEGORIES[kind]}")
                # The arm that makes the `singleSymbol` cases able to fail at all: an
                # unstyled layer is `singleSymbol` too, at QGIS's default opacity of 1.0.
                if opac != {want_opacity}:
                    failures.append(
                        f"{gname}/{layer}: QGIS drew symbol opacit(ies) {sorted(opac)}, "
                        f"expected {{{want_opacity}}} — the renderer type matches but the "
                        f"symbols are not the committed style's, which for a singleSymbol "
                        f"layer is the ONLY thing separating a reachable style from none")

        # --- cold: de-register the style table and the style must become unreachable ---
        # A guard nobody has seen fail is decoration. If this arm passes, the warm arm above
        # would read the same for an unregistered file and proves nothing.
        cold = "floodplain_landcover.gpkg"
        with tempfile.TemporaryDirectory() as td:
            dereg = pathlib.Path(td) / cold
            shutil.copy(src_dir / cold, dereg)
            con = sqlite3.connect(dereg)
            n_del = con.execute(
                "DELETE FROM gpkg_contents WHERE table_name = 'layer_styles'").rowcount
            con.commit()
            con.close()
            if n_del != 1:
                failures.append(
                    f"cold arm removed {n_del} registration row(s) from {cold}, expected 1 "
                    f"— the arm did not set up the state it claims to test")
            else:
                # Indexed only after checking: the warm arm RECORDS an empty bundle and
                # continues rather than aborting, so an IndexError here would escape
                # `main()` as a traceback and throw away every finding collected above it.
                cold_layers = feature_layers(dereg)
                if not cold_layers:
                    failures.append(
                        f"cold arm: {cold} declares no feature layers, so the arm that "
                        f"makes the warm pass mean something did not run")
                else:
                    layer = cold_layers[0]
                    kind = style_kind(dereg, layer)
                    rtype, _, opac = renderer_of(dereg, layer)
                    print(f"\n  cold arm: {cold} de-registered, {layer} -> "
                          f"{rtype or 'NO RENDERER'} opacity={sorted(opac) or '-'} "
                          f"(must NOT be {EXPECT_RENDERER[kind]!r} at {want_opacity})")
                    if rtype == EXPECT_RENDERER[kind] and opac == {want_opacity}:
                        failures.append(
                            f"cold arm: QGIS still draws {layer} with {rtype!r} at the "
                            f"committed opacity after the registration was removed — the "
                            f"registration is not what makes the style reachable, so the "
                            f"warm arm above is measuring something else and this check is "
                            f"decoration")
    finally:
        app.exitQgis()

    if not checked:
        failures.append("no layers were opened — a check that asked QGIS nothing is not a "
                        "pass")

    if failures:
        print(f"\nFAILED: {len(failures)} problem(s)", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print(f"\nPASS: QGIS builds the expected renderer for all {checked} styled layer(s) of "
          f"{item} on a plain open, and loses it when the registration is removed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
