#!/bin/bash
# run_pipeline.sh — REBUILD the catalogue locally: stage -> tag -> COG -> build -> validate.
#
# Makes NO network writes. Nothing here can touch S3 or the live catalog, which is
# an architectural property now rather than something an env var has to protect.
# Publishing is scripts/catalogue_release.sh.
#
# Usage: bash scripts/run_pipeline.sh
#
# Requires: R with sf/yaml/jsonlite/drift, uv (Python env from pyproject.toml/uv.lock —
#           `uv run` auto-syncs it). No AWS credentials, no SSH.
# Source data: $FLOODPLAINS_DATA (default ../floodplains/data).

set -euo pipefail

# This script is the FULL rebuild. A single-group run belongs in test_pipeline.R.
# Fail before 01 wipes data/ and burns ~20 min of COG conversion on a build that
# catalogue_release.sh would refuse to publish anyway.
if [ -n "${WSG_ONLY:-}" ]; then
  echo "WSG_ONLY='${WSG_ONLY}' is set — run_pipeline.sh rebuilds ALL rostered groups." >&2
  echo "For a single group use: WSG=${WSG_ONLY} Rscript scripts/test_pipeline.R" >&2
  exit 1
fi

if [ -n "${ALLOW_DRIFT_SKEW:-}" ]; then
  echo "!!! ALLOW_DRIFT_SKEW='${ALLOW_DRIFT_SKEW}' — the class-table interlock is DISABLED." >&2
  echo "!!! Rasters classified by a DIFFERENT drift than the one writing classes.json will" >&2
  echo "!!! publish labels that may not describe their pixels, and every downstream check" >&2
  echo "!!! compares the labels to each other rather than to the model. It persists in an" >&2
  echo "!!! exported shell, exactly like ALLOW_SKIPPED below." >&2
fi

if [ -n "${ALLOW_SKIPPED:-}" ]; then
  echo "!!! ALLOW_SKIPPED='${ALLOW_SKIPPED}' — the partial-stage interlock is DISABLED." >&2
  echo "!!! A rostered group with missing upstream data will be dropped silently and" >&2
  echo "!!! this build will be publishable. It persists in an exported shell." >&2
fi

echo "=== 01: STAGE ==="
Rscript scripts/01_stage.R

echo ""
echo "=== 02: TAG ==="
uv run python scripts/02_raster_tag.py

echo ""
echo "=== 03: COG ==="
uv run python scripts/03_cog.py

echo ""
echo "=== STYLE DRIFT ==="
# Before embedding, not after: `01_stage.R` rewrites data/raw/classes.json from drift on
# every run, and styles/ is committed, so the two can part company with nothing noticing.
# Temp-dir only, milliseconds, and it turns a downstream RAT-row failure into the actual
# instruction ("regenerate and commit the styles").
uv run python scripts/style_drift-check.py

echo ""
echo "=== 04: STYLE ==="
# Before the STAC build, not after: item_create.py hashes every asset into
# file:checksum, and a style embedded afterwards would publish a checksum over
# bytes that no longer match the file. Same ordering reason as 02 before 03 (#33).
uv run python scripts/04_gpkg_style.py

echo ""
echo "=== BUILD STAC JSON ==="
uv run python scripts/item_create.py

echo ""
echo "=== VALIDATE ==="
# Runs here too, so a broken build is caught at rebuild time rather than at the
# start of a release. catalogue_release.sh re-runs it as its gate — it must not
# trust that whoever built the tree also validated it.
uv run python scripts/item_validate.py

echo ""
echo "=== DONE (nothing published) ==="
echo "Publish with:"
echo "  bash scripts/catalogue_release.sh"
