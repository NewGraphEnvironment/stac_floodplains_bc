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

  * No `gpkg_contents` row and no triggers, unlike what QGIS's own writer produces.
    Measured: QGIS auto-styles perfectly without them, and registering the table adds
    a second wall-clock timestamp (`gpkg_contents.last_change`) that would churn the
    published `file:checksum` on every rebuild. GDAL lists `layer_styles` as a layer
    either way, so the registration buys nothing.

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
FILE_STYLES = {
    "floodplain.gpkg": lambda layer: "floodplain.qml",
    "transition_vector.gpkg": lambda layer: "transition.qml",
    "floodplain_landcover.gpkg": lambda layer: (
        "classified.qml" if layer.startswith("classified") else
        "transition.qml" if layer.startswith("transition") else None),
}

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
    m = re.search(r'^GPKG_EPOCH\s*<-\s*"([^"]+)"', FP_GPKG_R.read_text(), re.M)
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
    return {w: (STYLE_DIR / w).read_text() for w in wanted}


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


def style_gpkg(path: pathlib.Path, styles: dict[str, str], epoch: str) -> int:
    con = sqlite3.connect(path)
    try:
        layers = feature_layers(con)
        if not layers:
            raise SystemExit(
                f"{path} declares no feature layers in gpkg_contents — refusing to "
                f"write a style table to a file this script cannot describe")
        want = intended_rows(path, layers, styles, epoch)

        # Skip the write entirely when the file is already correct. Not cosmetic:
        # SQLite bumps the header change counter on any write transaction and a
        # DELETE leaves freelist pages, so a re-run that rewrote identical rows would
        # still change the file's bytes — and with them the published `file:checksum`.
        # Measured: one pass over a virgin file is byte-reproducible; a second pass
        # was not, until this check.
        have = None
        if con.execute("SELECT 1 FROM sqlite_master WHERE type='table' "
                       "AND name='layer_styles'").fetchone():
            have = con.execute(f"SELECT {_COLS} FROM layer_styles ORDER BY id").fetchall()
        if have == want:
            return len(layers)

        con.executescript(LAYER_STYLES_DDL)
        con.execute("DELETE FROM layer_styles")
        con.executemany(
            f"INSERT INTO layer_styles ({_COLS}) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", want)
        con.commit()
        return len(layers)
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

    total_rows = 0
    for item in items:
        rows = 0
        for name in sorted(FILE_STYLES):
            gpkg = item / name
            if not gpkg.exists():
                raise SystemExit(f"{gpkg} is absent — staging did not complete")
            rows += style_gpkg(gpkg, styles, epoch)

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
            if not dst.exists() or dst.read_text() != text:
                dst.write_text(text)

        total_rows += rows
        print(f"  {item.name}: {rows} style row(s) across {len(FILE_STYLES)} GeoPackages, "
              f"{len(styles)} .qml copied")

    print(f"styles embedded: {total_rows} row(s) over {len(items)} item(s), "
          f"update_time pinned to {epoch}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
