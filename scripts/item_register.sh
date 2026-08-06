#!/bin/bash
# Register STAC item JSONs into the pgstac database on the geoserv droplet.
#
# The public API at images.a11s.one is read-only (transactions extension off, POST
# returns 405 — deliberate), so items are loaded with pypgstac, which the server
# build installs on the droplet at /opt/geoserv/scripts for exactly this purpose.
# Credentials never leave the server: the DSN is assembled remotely from
# /opt/geoserv/.env.
#
# Usage:
#   scripts/item_register.sh item.json [item.json ...]
#   GEOSERV_HOST=root@1.2.3.4 scripts/item_register.sh item.json
#
# Upsert is idempotent: re-registering an existing item is harmless. It is also
# additive — an item dropped from the build is NOT removed here. Use
# item_unregister.sh for that; catalogue_release.sh reports the orphans.
#
# Raw-SQL fallback if pypgstac is ever unavailable:
#   SELECT pgstac.upsert_item('<item json>'::jsonb);
#   piped into: docker exec -i geoserv-db psql -U stac -d stac
set -euo pipefail

# Tailscale node name, not the public IP: the reserved IP changes on a droplet
# rebuild and public SSH is gated by the DO firewall's ssh_allowed_ips, whereas
# the node name works from anywhere on the tailnet. Override for off-tailnet use.
HOST="${GEOSERV_HOST:-root@geopro}"
DB=stac                  # stac-floodplains-bc lives in the default stac db
# Only used in the closing verify hint — the collection an item lands in comes from
# the item's own `collection` field, not from here.
COLLECTION="${COLLECTION:-stac-floodplains-bc}"

[ $# -ge 1 ] || { echo "usage: $(basename "$0") item.json [item.json ...]" >&2; exit 1; }

# Compact each item to one NDJSON line, single-threaded and to a local temp file.
# Two reasons this is not piped straight into ssh: a compaction failure on file 12
# of 17 then fails before any byte reaches the droplet, and we need the line count
# below. Items here are 3-9 MB each (~94 MB total) — big enough that correctness
# of the transfer is not something to assume.
TMP=$(mktemp -t stac_items.XXXXXX)
trap 'rm -f "$TMP"' EXIT
python3 - "$@" > "$TMP" <<'PYEOF'
import json, sys
for f in sys.argv[1:]:
    print(json.dumps(json.load(open(f)), separators=(",", ":")))
PYEOF

N=$(wc -l < "$TMP" | tr -d ' ')
[ "$N" -eq "$#" ] || { echo "ERROR: compacted $N line(s) from $# file(s)" >&2; exit 1; }
echo "registering $N item(s) ($(wc -c < "$TMP" | tr -d ' ') bytes) into $DB on $HOST"

# The remote asserts the line count before loading. Without it a dropped connection
# on a newline boundary is invisible: cat sees EOF and exits 0, pypgstac loads a
# valid-but-short NDJSON and exits 0, ssh exits 0 — fewer items registered, green
# output. \$ escapes expand remotely; $N and $DB expand locally.
# Per-run remote temp file: a fixed /tmp path means a second concurrent run can
# truncate this one's payload after its count guard passed but before pypgstac has
# finished reading — partial load, exit 0. Same shared-file class CLAUDE.md records
# from rtj's loader with these very items.
#
# Password goes in PGPASSWORD, not the DSN: a password inside --dsn sits in argv and
# is readable via `ps aux` on the droplet for the whole multi-minute load.
ssh "$HOST" "
  set -eu
  F=\$(mktemp /tmp/stac_items.XXXXXX)
  trap 'rm -f \"\$F\"' EXIT
  cat > \"\$F\"
  got=\$(wc -l < \"\$F\" | tr -d ' ')
  # String compare, not -ne: \`if [ ... -ne ... ]\` is an if-condition, which set -e
  # exempts, so a non-numeric \$got would print an error and FALL THROUGH to the load.
  [ \"\$got\" = \"$N\" ] || { echo \"FATAL: received \$got of $N items — refusing to load\" >&2; exit 1; }
  . /opt/geoserv/.env
  export PATH=/root/.local/bin:\$PATH
  export PGPASSWORD=\"\${POSTGRES_PASSWORD}\"
  cd /opt/geoserv/scripts
  uv run pypgstac load items \"\$F\" \
    --dsn \"postgresql://stac@localhost:5432/$DB\" \
    --method upsert
" < "$TMP"

echo "OK — verify: curl -s -o /dev/null -w '%{http_code}\n' \\"
echo "  https://images.a11s.one/collections/${COLLECTION}/items/<item-id>"
