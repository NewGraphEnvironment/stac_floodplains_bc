#!/bin/bash
# run_pipeline.sh — end-to-end publish: stage -> COG -> tag -> S3 -> STAC register.
#
# Usage: bash scripts/run_pipeline.sh
#
# Requires: R with sf/terra/yaml/jsonlite, uv (Python env from pyproject.toml/uv.lock —
#           `uv run` auto-syncs it), AWS credentials for the S3 sync + register upload.
# Source data: $FLOODPLAINS_DATA (default ../floodplains/data).

set -euo pipefail

S3_BASE="https://stac-floodplains-bc.s3.us-west-2.amazonaws.com"

echo "=== 01: STAGE ==="
Rscript scripts/01_stage.R

echo ""
echo "=== 02: COG ==="
Rscript scripts/02_cog.R

echo ""
echo "=== 03: TAG ==="
uv run python scripts/03_cog_tag.py

echo ""
echo "=== 04: S3 UPLOAD ==="
Rscript scripts/04_s3_upload.R

echo ""
echo "=== 05: STAC REGISTER ==="
uv run python scripts/05_stac_register.py

echo ""
echo "=== DONE ==="
echo "Load into the catalog from the rtj repo:"
echo "  scripts/geoserv/stac_register-pypgstac.sh stac-floodplains-bc ${S3_BASE}"
