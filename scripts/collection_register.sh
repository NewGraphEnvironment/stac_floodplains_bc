#!/bin/bash
# Register the STAC collection document into pgstac on the geoserv droplet.
# Sibling to item_register.sh — same SSH transport, `load collections` instead.
#
# Usage:
#   scripts/collection_register.sh data/stac/collection.json
#   GEOSERV_HOST=root@1.2.3.4 scripts/collection_register.sh data/stac/collection.json
#
# Idempotent: re-registering an existing collection updates it in place.
#
# Run this BEFORE item_register.sh on a collection that does not exist yet —
# pgstac items reference the collection row. (stac_uav_bc registers items first
# and gets away with it only because its collection already exists.)
set -euo pipefail

HOST="${GEOSERV_HOST:-root@geopro}"   # see item_register.sh for why not the IP
DB=stac

[ $# -eq 1 ] || { echo "usage: $(basename "$0") collection.json" >&2; exit 1; }
[ -f "$1" ] || { echo "ERROR: no such file: $1" >&2; exit 1; }

TMP=$(mktemp -t stac_collection.XXXXXX)
trap 'rm -f "$TMP"' EXIT
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",", ":")))' "$1" > "$TMP"

CID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$1")
echo "registering collection '$CID' into $DB on $HOST"

# Per-run remote temp + PGPASSWORD rather than a password in argv — see the same
# comments in item_register.sh.
ssh "$HOST" "
  set -eu
  F=\$(mktemp /tmp/stac_collection.XXXXXX)
  trap 'rm -f \"\$F\"' EXIT
  cat > \"\$F\"
  [ -s \"\$F\" ] || { echo 'FATAL: empty collection payload' >&2; exit 1; }
  . /opt/geoserv/.env
  export PATH=/root/.local/bin:\$PATH
  export PGPASSWORD=\"\${POSTGRES_PASSWORD}\"
  cd /opt/geoserv/scripts
  uv run pypgstac load collections \"\$F\" \
    --dsn \"postgresql://stac@localhost:5432/$DB\" \
    --method upsert
" < "$TMP"

echo "OK — verify: curl -s https://images.a11s.one/collections/${CID}"
