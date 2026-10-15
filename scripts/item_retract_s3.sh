#!/bin/bash
# item_retract_s3.sh — delete a retired item's S3 objects (#76). Sibling to
# item_unregister.sh, which drops the API row; this drops the bytes.
#
# Usage:
#   scripts/item_retract_s3.sh --yes <item-id> [<item-id>...]
#   BUCKET=throwaway scripts/item_retract_s3.sh --yes <item-id>
#
# Run this AFTER catalogue_release.sh has printed RELEASE COMPLETE for the release that
# retired the item. Deliberately NOT part of that release:
#
#   * Bucket versioning is Suspended, so every delete here is permanent. A release that
#     destroyed assets on a failure path would be the one direction with no rollback, and
#     catalogue_release.sh refuses `--delete` on its own syncs for exactly that reason.
#   * While these objects exist, the pgstac delete the release performed is REVERSIBLE: the
#     item's document is still at s3://<bucket>/<id>.json, which the build no longer holds, so
#     it can be fetched and registered again. Not passed straight to the register script —
#     item_register.sh reads LOCAL files (json.load(open(f)) over its argv), so a bucket URL
#     dies with FileNotFoundError:
#         aws s3 cp "s3://<bucket>/<id>.json" "${TMPDIR:-/tmp}/"
#         scripts/item_register.sh "${TMPDIR:-/tmp}/<id>.json"
#     and then RE-RUN THE RELEASE, because the collection.json it published no longer links
#     that item: restoring the API row alone leaves the bucket and the API disagreeing, which
#     is the state the reload below turns into an empty collection. That is the rollback for
#     step 6, and running this script is what gives it up.
#
# Three refusals per id, each of which has to pass before anything is deleted:
#
#   1. the API must not serve it. Deleting the assets of a LIVE item publishes a catalogue
#      of dead links.
#   2. the bucket's collection.json must not link it. This is the ordering hazard, not a
#      formality: rtj's stac_register-all.sh reloads this collection FROM S3 by reading
#      collection.json's rel=item hrefs, and it DELETEs every row of the collection before
#      it discovers that one href 404s — leaving the collection serving nothing. Its own
#      script records that happening to stac-dem-bc. So the release (which republishes
#      collection.json) must come first, and this check is what enforces it.
#   3. this build must not produce it, where a build is present to ask. A release-only
#      machine holds no data/stac, which is not an error — guards 1 and 2 are the load-bearing
#      ones; this is the cheap local cross-check for an operator running it beside a build.
set -euo pipefail

BUCKET="${BUCKET:-stac-floodplains-bc}"
COLLECTION="${COLLECTION:-stac-floodplains-bc}"
API_ROOT="${API_ROOT:-https://images.a11s.one}"
API="$API_ROOT/collections/$COLLECTION"
S3_BASE="https://$BUCKET.s3.us-west-2.amazonaws.com"
REGION="${AWS_REGION:-us-west-2}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
STAC_DIR="${STAC_DIR:-$REPO/data/stac}"

usage() {
  echo "usage: $(basename "$0") --yes <item-id> [<item-id>...]" >&2
  echo "  --yes is required: every delete here is permanent (bucket versioning is Suspended)." >&2
}

YES=""
n=0
set -- "$@"
ITEMS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown flag: $1" >&2; usage; exit 1 ;;
    # The same shape guard as item_unregister.sh, and for a stronger reason: these ids are
    # interpolated into an `aws s3 rm --recursive` prefix. A `..` or a bare `/` would widen
    # the delete past the item, and there is no undo.
    *[!A-Za-z0-9_-]*) echo "ERROR: suspicious item id: $1" >&2; exit 1 ;;
    *) ITEMS="$ITEMS $1"; n=$((n + 1)) ;;
  esac
  shift
done

[ "$n" -ge 1 ] || { usage; exit 1; }
[ -n "$YES" ] || { echo "Refusing without --yes: $n item(s) named, and the delete is permanent." >&2; usage; exit 1; }

# The bucket's own collection.json, read ONCE: it is the document that decides what a
# reload-from-S3 will try to fetch, and guard 2 is a membership test against it.
coll=$(curl -sf --max-time 60 "$S3_BASE/collection.json") \
  || { echo "Could not read s3://$BUCKET/collection.json — refusing to delete blind." >&2; exit 1; }
linked=$(printf '%s' "$coll" | python3 -c "
import sys, json, posixpath
d = json.load(sys.stdin)
for l in d.get('links') or []:
    if l.get('rel') == 'item':
        h = l.get('href') or ''
        print(posixpath.basename(h)[:-5] if h.endswith('.json') else posixpath.basename(h))
" | LC_ALL=C sort -u) \
  || { echo "Could not parse the bucket collection.json." >&2; exit 1; }

refusals=0
for id in $ITEMS; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$API/items/$id" || true)
  case "$code" in
    404|410) ;;
    *) echo "REFUSED $id: the API still answers $code for it. Unregister it first:" >&2
       echo "  scripts/item_unregister.sh $id" >&2
       refusals=$((refusals + 1)); continue ;;
  esac
  # A here-string, not a pipe into `grep -q`. grep exits at its first match, and under
  # `set -o pipefail` the writer's SIGPIPE becomes the test's answer once the text passes the
  # pipe buffer (64 KiB, measured). `$linked` is ~1 KB today so it is far off, but this is the
  # one site in the family that fails toward PASS: the "still links it" refusal simply would
  # not fire, and the hazard it guards is the one that empties the collection.
  if grep -qxF -- "$id" <<<"$linked"; then
    echo "REFUSED $id: the bucket collection.json still links it as a rel=item." >&2
    echo "  Deleting it now would leave that document naming an object that 404s, and a" >&2
    echo "  reload-from-S3 DELETEs the collection before it finds out. Publish the release" >&2
    echo "  that drops it from collection.json first." >&2
    refusals=$((refusals + 1)); continue
  fi
  if [ -d "$STAC_DIR" ] && [ -f "$STAC_DIR/$id.json" ]; then
    echo "REFUSED $id: $STAC_DIR/$id.json exists, so this build still produces it." >&2
    refusals=$((refusals + 1)); continue
  fi
  # Guard 4, and it is the one that stops this script deleting the catalogue itself.
  #
  # `--yes collection` passed all three guards above: the API has no item called `collection`
  # so it 404s, `$linked` holds item ids only, and guard 3 catches it ONLY by accident — and
  # guard 3 is skipped whenever `data/stac` is absent, which is a release-only machine, the
  # machine this script exists for. The delete that followed was
  # `aws s3 rm s3://<bucket>/collection.json` on a bucket with versioning Suspended.
  #
  # The charset guard at the top cannot help: `collection` is a perfectly well-formed id-shaped
  # token. The property wanted is "this names a STAC Item of this collection", so that is what
  # is asked, the same way the release's preflight asks it. ABSENT is allowed — that is the
  # re-run, and the asset prefix may still need clearing — but anything present must say it is
  # the Item being retracted.
  code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 60 "$S3_BASE/$id.json" || echo 000)
  case "$code" in
    404|403) ;;        # nothing there: a re-run, or assets only. Fall through to the delete.
    200)
      ident=$(curl -sf --max-time 60 "$S3_BASE/$id.json" 2>/dev/null \
        | python3 -c "import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('UNREADABLE'); raise SystemExit(0)
print('MATCH' if d.get('type') == 'Feature' and d.get('id') == sys.argv[1] else 'OTHER')" "$id" \
        || true)
      # Three outcomes, the same three the release's preflight witness distinguishes, and
      # structurally the same `case` on purpose: these two are the pair that has to agree
      # about what the bucket says, and nothing but their shape joins them.
      case "$ident" in
        MATCH) ;;
        OTHER)
          echo "REFUSED $id: s3://$BUCKET/$id.json is not a STAC Item with that id." >&2
          echo "  This script deletes that key and this bucket has no undo, so it only ever" >&2
          echo "  deletes a document that identifies itself as the item being retracted." >&2
          echo "  'collection' reaches this arm." >&2
          refusals=$((refusals + 1)); continue ;;
        *)
          echo "REFUSED $id: could not read s3://$BUCKET/$id.json (HTTP 200, body" >&2
          echo "  unreadable). Refusing to delete on a probe that did not complete. Retry." >&2
          refusals=$((refusals + 1)); continue ;;
      esac ;;
    *)
      echo "REFUSED $id: could not read s3://$BUCKET/$id.json (HTTP '$code')." >&2
      echo "  Refusing to delete on an unread probe. Retry." >&2
      refusals=$((refusals + 1)); continue ;;
  esac
  OK_IDS="${OK_IDS:-}$id "
done

[ "$refusals" -eq 0 ] || { echo "" >&2; echo "$refusals of $n refused — nothing deleted." >&2; exit 1; }

# What is about to go, counted before it goes. An operator who is about to lose the rollback
# for a pgstac delete should see the byte total first.
echo "deleting from s3://$BUCKET (region $REGION) — permanent, versioning is Suspended:"
for id in ${OK_IDS:-}; do
  # `|| summary=...` on the assignment. `aws s3 ls` exits 1 when a prefix matches NOTHING, and
  # under `set -o pipefail` that status propagates through the pipe even though awk succeeded —
  # so the assignment fails and `set -e` kills the script HERE, silently, because stderr is
  # discarded. It would die after printing the "permanent" banner and before the
  # `aws s3 rm .../$id.json` below, orphaning the root document in the bucket with no message.
  # An empty prefix is not an error: it is the re-run this script is written to tolerate.
  summary=$(aws s3 ls "s3://$BUCKET/$id/" --recursive --region "$REGION" --summarize 2>/dev/null \
    | awk '/Total Objects:/ {o=$3} /Total Size:/ {s=$3} END {printf "%s object(s), %s bytes", o+0, s+0}') \
    || summary="no objects under this prefix (already removed, or never had any)"
  echo "  $id/        $summary"
  # :-absent covers a head-object that SUCCEEDS printing nothing as well as one that fails;
  # a bare `|| echo absent` leaves the first case rendering as "  $id.json     bytes".
  bytes=$(aws s3api head-object --bucket "$BUCKET" --key "$id.json" \
    --region "$REGION" --query ContentLength --output text 2>/dev/null || true)
  echo "  $id.json    ${bytes:-absent} bytes"
done

for id in ${OK_IDS:-}; do
  # The prefix with its trailing slash, never the bare id: `s3://b/aaaa` --recursive would
  # also sweep `aaaa_co_ff04/` and every other key sharing the prefix.
  aws s3 rm "s3://$BUCKET/$id/" --recursive --region "$REGION"
  # A missing key is not an error here: the release may have been run twice, or an earlier
  # attempt may have got this far. `|| true` on the object delete only — the prefix sweep
  # above is the one that must succeed.
  aws s3 rm "s3://$BUCKET/$id.json" --region "$REGION" || true
  echo "retracted: $id"
done

echo ""
echo "OK — $n item(s) retracted from s3://$BUCKET."
echo "The pgstac rows were already gone; these assets cannot be restored."
