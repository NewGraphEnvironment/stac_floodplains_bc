#!/bin/bash
# run_pipeline.sh — end-to-end publish: stage -> COG -> tag -> validate -> S3 -> STAC register.
#
# Usage: bash scripts/run_pipeline.sh
#
# Requires: R with sf/terra/yaml/jsonlite, uv (Python env from pyproject.toml/uv.lock —
#           `uv run` auto-syncs it), AWS credentials for the S3 sync + register upload.
# Source data: $FLOODPLAINS_DATA (default ../floodplains/data).

set -euo pipefail

S3_BASE="https://stac-floodplains-bc.s3.us-west-2.amazonaws.com"

# This script is the FULL publish. A single-group run belongs in test_pipeline.R.
# Fail before 01 wipes data/ and burns ~20 min of COG conversion on a build that
# 05b would refuse to upload anyway.
if [ -n "${WSG_ONLY:-}" ]; then
  echo "WSG_ONLY='${WSG_ONLY}' is set — run_pipeline.sh publishes ALL rostered groups." >&2
  echo "For a single group use: WSG=${WSG_ONLY} Rscript scripts/test_pipeline.R" >&2
  exit 1
fi

echo "=== 01: STAGE ==="
Rscript scripts/01_stage.R

echo ""
echo "=== 02: COG ==="
Rscript scripts/02_cog.R

echo ""
echo "=== 03: TAG ==="
uv run python scripts/03_cog_tag.py

echo ""
echo "=== 05a: BUILD + VALIDATE (gate, no upload) ==="
# Validation gate. 05 builds every item + the collection and hard-exits on any
# pystac failure; SKIP_S3_UPLOAD keeps it local. This runs BEFORE 04 so a bad
# build cannot put ~700 MB of COGs/gpkgs into a bucket whose versioning is
# Suspended (no rollback). Costs one extra local JSON build; worth it.
SKIP_S3_UPLOAD=1 uv run python scripts/05_stac_register.py

# 05's upload block is `if SKIP_S3_UPLOAD ... elif PARTIAL_STAGE ...`, so the gate
# above ALWAYS takes the skip branch and never evaluates the partial-stage refusal.
# Re-assert it here, or a partial build would pass the gate and push its assets.
# (Do not reorder those branches in 05 — test_pipeline.R relies on skip winning.)
if [ -e data/raw/PARTIAL_STAGE ]; then
  echo "Refusing to sync: staging was partial ($(cat data/raw/PARTIAL_STAGE))." >&2
  exit 1
fi

if [ -n "${ALLOW_SKIPPED:-}" ]; then
  echo "!!! ALLOW_SKIPPED='${ALLOW_SKIPPED}' — the partial-stage interlock is DISABLED." >&2
  echo "!!! If that was not deliberate for THIS run, ctrl-c now (it persists in an" >&2
  echo "!!! exported shell). Publishing fewer items overwrites the live collection." >&2
fi

# Last interlock, and the only one that catches the case PARTIAL_STAGE structurally
# cannot: `skipped` only counts groups the stage loop reached and rejected. A region
# roster yml missing from $FLOODPLAINS_DATA drops its groups before they are ever
# counted, so the marker is never written and a short-but-valid collection sails
# through the gate. Compare the build against what is actually live instead.
echo ""
echo "=== PRE-SYNC: build vs live collection ==="
live_ids=$(curl -sf --max-time 60 \
  "https://images.a11s.one/collections/stac-floodplains-bc/items?limit=1000" \
  | python3 -c "import sys,json; print('\n'.join(sorted(f['id'] for f in json.load(sys.stdin)['features'])))") || {
  echo "Could not read the live collection — refusing to sync blind." >&2
  exit 1
}
local_ids=$(for f in data/stac/*.json; do
  b=$(basename "$f" .json); [ "$b" = collection ] || echo "$b"
done | sort)
missing=$(comm -23 <(printf '%s\n' "$live_ids") <(printf '%s\n' "$local_ids") || true)
echo "live: $(printf '%s\n' "$live_ids" | grep -c .) | built: $(printf '%s\n' "$local_ids" | grep -c .)"
if [ -n "$missing" ]; then
  echo "Refusing to sync — these items are LIVE but absent from this build:" >&2
  printf '  %s\n' $missing >&2
  if [ -z "${ALLOW_RETRACT:-}" ]; then
    echo "Fix upstream, or set ALLOW_RETRACT=1 if the removal is deliberate." >&2
    exit 1
  fi
  echo "ALLOW_RETRACT set — proceeding with a smaller collection." >&2
fi

echo ""
echo "=== 04: S3 UPLOAD ==="
Rscript scripts/04_s3_upload.R

echo ""
echo "=== 05b: STAC REGISTER (upload JSON) ==="
# Assets are up; rebuild identically and upload the item/collection JSON, so the
# JSON never references an asset that has not landed yet. `env -u` because an
# inherited SKIP_S3_UPLOAD would silently make this a no-op — assets refreshed,
# JSON stale, pipeline still printing DONE.
env -u SKIP_S3_UPLOAD uv run python scripts/05_stac_register.py

echo ""
echo "=== DONE ==="
echo "Load into the catalog from the rtj repo:"
echo "  scripts/geoserv/stac_register-pypgstac.sh stac-floodplains-bc ${S3_BASE}"
