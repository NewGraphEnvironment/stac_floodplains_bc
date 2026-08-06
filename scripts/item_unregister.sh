#!/bin/bash
# Unregister (delete) STAC items from pgstac on the geoserv droplet. Sibling to
# item_register.sh — same SSH transport, but deletion has no pypgstac verb so it
# goes through pgstac SQL (delete_item) inside the db container.
#
# Usage:
#   scripts/item_unregister.sh <item-id> [<item-id>...]
#   GEOSERV_HOST=root@1.2.3.4 scripts/item_unregister.sh <item-id>
#
# Idempotent: an id that is not registered warns and continues (exit 0).
#
# This removes items from the API only. S3 objects are separate — see the
# retraction recipe in scripts/README.md.
set -euo pipefail

HOST="${GEOSERV_HOST:-root@geopro}"   # see item_register.sh for why not the IP
DB=stac
COLLECTION=stac-floodplains-bc

[ $# -ge 1 ] || { echo "usage: $(basename "$0") item-id [item-id ...]" >&2; exit 1; }

TMP=$(mktemp -t stac_unregister.XXXXXX)
trap 'rm -f "$TMP"' EXIT
for id in "$@"; do
  # Ids are interpolated into SQL, so constrain them to the shape 05 actually
  # emits (<wsg>_<species>_<scenario>) before they get anywhere near psql.
  case "$id" in
    *[!A-Za-z0-9_-]*) echo "ERROR: suspicious item id: $id" >&2; exit 1 ;;
  esac
  # delete_item(_id, _collection): the one-arg form leaves _collection NULL, and
  # pgstac's body is `WHERE id = _id AND (_collection IS NULL OR collection=_collection)`
  # — i.e. UNSCOPED across every collection in this db, which also hosts
  # imagery-uav-bc-prod and stac-dem-bc. Always pass the collection.
  #
  # NO_DATA_FOUND only, not OTHERS: delete_item uses `RETURNING * INTO STRICT`, so a
  # genuinely-absent id raises exactly NO_DATA_FOUND. Catching OTHERS would swallow
  # permission denials and a missing search_path too — every id would report
  # "not deleted (missing?)", psql would exit 0, and the script would print OK
  # having deleted nothing.
  cat >> "$TMP" << SQL
DO \$\$
BEGIN
  PERFORM pgstac.delete_item('$id', '$COLLECTION');
  RAISE NOTICE 'deleted: $id';
EXCEPTION WHEN NO_DATA_FOUND THEN
  RAISE WARNING 'not registered, nothing to delete: $id';
END
\$\$;
SQL
done

echo "unregistering $# item(s) from $DB on $HOST"
ssh "$HOST" "docker exec -i geoserv-db psql -U stac -d $DB -v ON_ERROR_STOP=1" < "$TMP"

echo "OK — verify 404: curl -s -o /dev/null -w '%{http_code}\n' \\"
echo "  https://images.a11s.one/collections/${COLLECTION}/items/<item-id>"
