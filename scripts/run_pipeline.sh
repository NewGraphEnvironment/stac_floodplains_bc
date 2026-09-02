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
