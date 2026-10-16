#!/usr/bin/env python3
"""04_gpkg_style.py — embed the layer styles in each staged GeoPackage (#46).

QGIS reads a default style from a `layer_styles` table inside the GeoPackage, so
writing one row per feature layer makes the published vectors open already coloured,
with the same palette the COGs carry in their RAT. The styles themselves come from
`styles/*.qml`, generated from `data/raw/classes.json` by `style_qml-write.py`.

Runs after `03_cog.py` and BEFORE `item_create.py`, which is where `file:checksum`
is computed — a style embedded afterwards would publish a checksum over bytes that no
longer match the file.

Stdlib `sqlite3` only. A GeoPackage is a SQLite database and a style row is a plain
INSERT, so this needs no GDAL, no `sf`, and no new dependency in either language.

Three things here are deliberate and each was measured:

  * `f_table_schema` is `''`, NEVER NULL. QGIS matches the row with `= ''`, and NULL
    never equals anything, so a NULL row is written successfully, logs nothing, and
    the layer opens with a single symbol. (rfp#17, reproduced on this repo's data.)

  * `layer_styles` IS registered in `gpkg_contents`, with `last_change` pinned. Until #95
    it was not, on a measurement that "GDAL lists `layer_styles` as a layer either way, so
    the registration buys nothing" — which was the premise that shipped #95 and is false.
    The GPKG driver's `LIST_ALL_TABLES=AUTO` default surfaces an unregistered table only
    while the file declares no aspatial content; once a `data_type='attributes'` row is
    present GDAL stops LISTING `layer_styles`, and QGIS's style lookup goes through GDAL's
    layer list. So every `floodplain_landcover.gpkg` — which carries the producer's
    `patch_watercourse_*` and `composition_*` — published a correct, complete and
    unreachable style on all 23 items. Measured 2026-10-16 on GDAL 3.8.5, 3.12.4 and
    3.13.0: hidden in that bundle, listed in the other two, and `-oo LIST_ALL_TABLES=YES`
    brings it back. A decade-old heuristic, not a QGIS regression, and `LIST_ALL_TABLES`
    is consumer-side — unreachable from the published bytes — so registering is the only
    in-file fix.

    Registered in ALL THREE bundles, not only the one that needs it today: `01_stage.R`
    anticipates an aspatial family appearing in `floodplain.gpkg` and would stage it, and
    on that day that bundle's styles would die exactly as the landcover bundle's did,
    silently. Uniform registration makes reachability a property of the file rather than
    of a heuristic.

    What killed the registration at #46 was that it adds a second wall-clock timestamp
    (`gpkg_contents.last_change`) beside `layer_styles.update_time`, churning every
    published `file:checksum`. Pinned to the same `GPKG_EPOCH`, it does not — and it is
    the value every other `gpkg_contents` row in these files already carries.

    Still NO triggers and no `gpkg_ogr_contents` row, which is less than GDAL writes for
    its own tables. Measured rather than assumed: `ogrinfo -so` on the registered table
    reports `Feature Count: 4`, `FID Column = id` and every column typed, with no warning.

  * `update_time` is pinned, and the column's own DEFAULT is not used. The QGIS schema
    defaults it to `strftime(...,'now')`; the pin is the same `GPKG_EPOCH` that
    `fp_gpkg.R` gives GDAL, read from that file so the two cannot drift.

`id` is assigned explicitly and the table has no AUTOINCREMENT, so nothing walks a
sequence across runs. Re-running is a true no-op: the rows are compared first and the
write is skipped when they already match, because SQLite bumps its header change
counter on ANY write transaction — so even rewriting identical rows would move the
file's bytes, and with them the published `file:checksum`. Measured: one pass over a
virgin file is byte-reproducible, three passes now give one digest.

    uv run python scripts/04_gpkg_style.py
"""

import pathlib
import re
import sqlite3
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
STAC_DIR = REPO / "data" / "stac"
STYLE_DIR = REPO / "styles"
FP_GPKG_R = REPO / "scripts" / "fp_gpkg.R"

# Which style each layer gets. Keyed by GeoPackage first, because the file is the
# reliable discriminator: `floodplain.gpkg`'s layers are named `<sp>_ff0N`, which no
# prefix rule could tell from an arbitrary name. Within `floodplain_landcover.gpkg`
# the layer name decides, since it holds both kinds.
#
# Note what the `floodplain.gpkg` catch-all means since #80. It was sound while every layer
# in the file was inherited from upstream; now staging SELECTS them by item key, so a new
# upstream family in that file is styled rather than refused here. 01_stage.R reports any
# staged layer whose name matches no known family, which is the only cover this file has.
FILE_STYLES = {
    "floodplain.gpkg": lambda layer: "floodplain.qml",
    "transition_vector.gpkg": lambda layer: "transition.qml",
    "floodplain_landcover.gpkg": lambda layer: (
        "classified.qml" if layer.startswith("classified") else
        "transition.qml" if layer.startswith("transition") else None),
}

STYLE_TABLE = "layer_styles"

# The `gpkg_contents` row that makes the style table reachable (#95), shaped to match what
# GDAL itself wrote for the sibling `attributes` rows in these same files: `identifier`
# equal to the table name, an empty description, a NULL bounding box, and `srs_id` 0 —
# which GeoPackage 1.2 requires `gpkg_spatial_ref_sys` to carry and which is present in all
# three bundles (measured). `data_type` must be `attributes`: `features` wants a
# `gpkg_geometry_columns` row and breaks the layer, and `aspatial` is the retired GDAL
# extension and wants a `gpkg_extensions` row.
_GC_COLS = '"table_name","data_type","identifier","description","last_change","srs_id"'


def intended_registration(epoch: str) -> tuple:
    return (STYLE_TABLE, "attributes", STYLE_TABLE, "", epoch, 0)


LAYER_STYLES_DDL = """
CREATE TABLE IF NOT EXISTS "layer_styles" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "f_table_catalog" TEXT(256),
  "f_table_schema" TEXT(256),
  "f_table_name" TEXT(256),
  "f_geometry_column" TEXT(256),
  "styleName" TEXT(30),
  "styleQML" TEXT,
  "styleSLD" TEXT,
  "useAsDefault" BOOLEAN,
  "description" TEXT,
  "owner" TEXT(30),
  "ui" TEXT(30),
  "update_time" DATETIME)
"""


def gpkg_epoch() -> str:
    """The timestamp pin, read from `fp_gpkg.R` rather than restated here.

    That file is the one place this repo decides what a pinned GeoPackage timestamp
    is; a second copy would be one fact derived twice, and the two would drift the
    first time anyone changed it.
    """
    m = re.search(r'^GPKG_EPOCH\s*<-\s*"([^"]+)"',
                  FP_GPKG_R.read_text(encoding="utf-8"), re.M)
    if not m:
        raise SystemExit(
            f"could not read GPKG_EPOCH from {FP_GPKG_R} — the timestamp pin moved or "
            f"was renamed, and embedding a style without it would churn every "
            f"GeoPackage's published file:checksum on the next rebuild")
    return m.group(1)


def load_styles() -> dict[str, str]:
    wanted = {"floodplain.qml", "classified.qml", "transition.qml"}
    missing = sorted(w for w in wanted if not (STYLE_DIR / w).exists())
    if missing:
        raise SystemExit(
            f"missing style(s) in {STYLE_DIR}: {', '.join(missing)} — run "
            f"`uv run python scripts/style_qml-write.py`")
    # Explicit encoding: every QML carries non-ASCII in its version header, and the
    # generator writes UTF-8. A locale default would mojibake or raise, and the
    # mangled bytes would then be embedded and published under a checksum over them.
    return {w: (STYLE_DIR / w).read_text(encoding="utf-8") for w in wanted}


def feature_layers(con: sqlite3.Connection) -> list[tuple[str, str]]:
    """(layer, geometry column) for every feature table, in a fixed order.

    Ordered so a rebuild inserts the same rows in the same sequence and the file
    stays byte-reproducible.
    """
    rows = con.execute(
        "SELECT c.table_name, g.column_name FROM gpkg_contents c "
        "LEFT JOIN gpkg_geometry_columns g ON g.table_name = c.table_name "
        "WHERE c.data_type = 'features' ORDER BY c.table_name").fetchall()
    return [(r[0], r[1] or "geom") for r in rows]


def intended_rows(path: pathlib.Path, layers, styles: dict[str, str], epoch: str):
    """The exact rows this file should carry, in insert order."""
    pick = FILE_STYLES[path.name]
    rows = []
    for i, (layer, geom) in enumerate(layers, start=1):
        name = pick(layer)
        if name is None:
            # Fail rather than skip. A layer nobody mapped is a new or renamed upstream
            # layer, and shipping it unstyled while every neighbour looks correct is
            # exactly the silent failure this issue exists to prevent.
            raise SystemExit(
                f"{path.name} layer '{layer}' matches no style rule — add it to "
                f"FILE_STYLES in {pathlib.Path(__file__).name}, or the layer ships "
                f"unstyled while every other layer looks correct")
        rows.append((i, "", "", layer, geom, pathlib.Path(name).stem, styles[name],
                     None, 1, f"stac-floodplains-bc: {name}", "", "", epoch))
    return rows


_COLS = ('"id","f_table_catalog","f_table_schema","f_table_name","f_geometry_column",'
         '"styleName","styleQML","styleSLD","useAsDefault","description","owner","ui",'
         '"update_time"')


def style_gpkg(path: pathlib.Path, styles: dict[str, str],
               epoch: str) -> tuple[int, bool]:
    """(feature layers styled, registration present and pinned) for one GeoPackage."""
    con = sqlite3.connect(path)
    try:
        layers = feature_layers(con)
        if not layers:
            raise SystemExit(
                f"{path} declares no feature layers in gpkg_contents — refusing to "
                f"write a style table to a file this script cannot describe")
        want = intended_rows(path, layers, styles, epoch)

        # Skip each write when that part of the file is already correct. Not cosmetic:
        # SQLite bumps the header change counter on any write transaction and a
        # DELETE leaves freelist pages, so a re-run that rewrote identical rows would
        # still change the file's bytes — and with them the published `file:checksum`.
        # Measured: one pass over a virgin file is byte-reproducible; a second pass
        # was not, until this check.
        #
        # The style rows and the registration are compared SEPARATELY, so a re-run is a
        # true no-op in every combination of the two — including the one #95 creates, a
        # file whose style rows are already right and whose registration is missing. A
        # single combined comparison would have rewritten both to fix either.
        have = None
        if con.execute("SELECT 1 FROM sqlite_master WHERE type='table' "
                       f"AND name='{STYLE_TABLE}'").fetchone():
            have = con.execute(
                f"SELECT {_COLS} FROM {STYLE_TABLE} ORDER BY id").fetchall()
        want_gc = intended_registration(epoch)
        have_gc = con.execute(
            f"SELECT {_GC_COLS} FROM gpkg_contents WHERE table_name = ?",
            (STYLE_TABLE,)).fetchone()

        if have != want:
            con.executescript(LAYER_STYLES_DDL)
            con.execute(f"DELETE FROM {STYLE_TABLE}")
            con.executemany(
                f"INSERT INTO {STYLE_TABLE} ({_COLS}) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", want)

        if have_gc != want_gc:
            # UPDATE when a row is already there, never INSERT and never REPLACE.
            #
            # A bare INSERT raises `UNIQUE constraint failed: gpkg_contents.identifier`
            # on any file that arrives carrying its own registration — which QGIS's own
            # writer leaves behind whenever someone saves a style into the file, and which
            # a change to `GPKG_EPOCH` would produce too. Measured by restoring it.
            #
            # REPLACE does not raise, and is still wrong: measured on a repair, it moves
            # the row's rowid (7 -> 8) and the file's sha256 with it, because REPLACE
            # deletes and re-inserts. It is not a published-bytes hazard — a repaired file
            # is never published, since a release is cut from a full rebuild — and
            # `style_determinism-check.py` does NOT pin it, because that check byte-compares
            # the fresh-build path, where both spellings behave as INSERT and give
            # identical bytes.
            if have_gc is None:
                con.execute(
                    f"INSERT INTO gpkg_contents ({_GC_COLS}) VALUES (?,?,?,?,?,?)",
                    want_gc)
            else:
                con.execute(
                    "UPDATE gpkg_contents SET data_type = ?, identifier = ?, "
                    "description = ?, last_change = ?, srs_id = ? WHERE table_name = ?",
                    (*want_gc[1:], want_gc[0]))

        if have != want or have_gc != want_gc:
            con.commit()

        # Read the registration BACK rather than reporting the intent. The summary line
        # below is the only thing an operator reads for this step, and while it merely
        # restated what the code meant to do it printed "registered in gpkg_contents" on a
        # run with the registration disabled — measured, by restoring that bug.
        return len(layers), bool(con.execute(
            "SELECT 1 FROM gpkg_contents WHERE table_name = ? AND last_change = ?",
            (STYLE_TABLE, epoch)).fetchone())
    finally:
        con.close()


def main() -> int:
    if not STAC_DIR.is_dir():
        raise SystemExit(f"{STAC_DIR} does not exist — run scripts/01_stage.R first")
    styles = load_styles()
    epoch = gpkg_epoch()

    items = sorted(p for p in STAC_DIR.iterdir() if p.is_dir())
    if not items:
        raise SystemExit(
            f"no item directories under {STAC_DIR} — nothing was staged, and a run "
            f"that styled nothing must not report success")

    total_rows, total_reg, total_files = 0, 0, 0
    for item in items:
        rows = 0
        for name in sorted(FILE_STYLES):
            gpkg = item / name
            if not gpkg.exists():
                raise SystemExit(f"{gpkg} is absent — staging did not complete")
            n, registered = style_gpkg(gpkg, styles, epoch)
            rows += n
            total_files += 1
            total_reg += registered

        # Also place the styles beside the assets, so `item_create.py` can publish them
        # as STAC assets. Per-item copies rather than one shared object at the bucket
        # root: `item_validate.py`'s checksum check resolves an asset's local path from
        # its href and asserts the second-to-last segment is the item id, so a
        # root-level style would have no item directory to live in. About 160 KB each.
        #
        # Written only when the bytes differ, for the same reason the style rows are:
        # an unchanged rewrite would move the mtime for no change in content.
        for name, text in sorted(styles.items()):
            dst = item / name
            if not dst.exists() or dst.read_text(encoding="utf-8") != text:
                dst.write_text(text, encoding="utf-8")

        total_rows += rows
        print(f"  {item.name}: {rows} style row(s) across {len(FILE_STYLES)} GeoPackages, "
              f"{len(styles)} .qml copied")

    print(f"styles embedded: {total_rows} row(s) over {len(items)} item(s), "
          f"{STYLE_TABLE} registered and pinned in {total_reg} of {total_files} "
          f"GeoPackage(s), both timestamps pinned to {epoch}")
    if total_reg != total_files:
        raise SystemExit(
            f"{total_files - total_reg} GeoPackage(s) ended without a pinned "
            f"{STYLE_TABLE} registration — GDAL would stop listing the table the moment "
            f"the file declares any aspatial content, and the style would be unreachable "
            f"with every row still in place (#95)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
