#!/bin/bash
# catalogue_release.sh — publish the built catalogue: validate -> sync -> register -> verify.
#
# Usage:
#   bash scripts/catalogue_release.sh
#   bash scripts/catalogue_release.sh --allow-retract     # deliberate item removal
#   GEOSERV_HOST=root@1.2.3.4 bash scripts/catalogue_release.sh
#
# Requires: data/stac (built by run_pipeline.sh), AWS credentials, SSH to geopro.
# Does NOT require $FLOODPLAINS_DATA — rebuild and publish are separate, so a
# release can be cut from any machine with creds and tailnet access, not only the
# one holding the 900 MB source tree.
#
# Idempotent: the sync skips unchanged objects and the register is an upsert.
set -euo pipefail

BUCKET="${BUCKET:-stac-floodplains-bc}"
COLLECTION="${COLLECTION:-stac-floodplains-bc}"
API_ROOT=https://images.a11s.one
API="$API_ROOT/collections/$COLLECTION"
STAC_DIR="${STAC_DIR:-data/stac}"
RAW_DIR="${RAW_DIR:-data/raw}"
HOST="${GEOSERV_HOST:-root@geopro}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

ALLOW_RETRACT=""
SKIP_SYNC=""
while [ $# -gt 0 ]; do
  case "$1" in
    # Publish a collection smaller than what is live. Required, because that is
    # otherwise refused — the refusal is the guard against an accidental partial.
    --allow-retract) ALLOW_RETRACT=1 ;;
    # Register without re-uploading. For re-running after a registration failure
    # (the assets are already up and every href still resolves), and for exercising
    # the orchestration against a throwaway collection id.
    #
    # Narrower than it used to be: items now publish file:checksum, so "the href
    # resolves" no longer implies "the bytes match". Skipping the sync after the
    # assets have changed locally would register a checksum for objects that are not
    # on S3. The step-5 checksum probe catches this for the sampled item.
    --skip-sync) SKIP_SYNC=1 ;;
    *) echo "unknown option: $1" >&2
       echo "usage: $(basename "$0") [--allow-retract] [--skip-sync]" >&2; exit 1 ;;
  esac
  shift
done

cd "$REPO"

# Fielded search, used by both the preflight and the verify. `fields.include` is
# mandatory, not an optimization: an unfielded GET /items returns the full
# unsimplified floodplain geometries — ~34 s and ~34 MB for 17 items, growing
# linearly as groups are added, so it would eventually just time out. Fielded it is
# 8 KB in 0.15 s.
fetch_live_ids() {
  curl -sf --max-time 120 -X POST "$API_ROOT/search" \
    -H 'Content-Type: application/json' \
    -d "{\"collections\":[\"$COLLECTION\"],\"limit\":1000,\"fields\":{\"include\":[\"id\"]}}" \
    | python3 -c "import sys,json; print('\n'.join(sorted(f['id'] for f in json.load(sys.stdin)['features'])))"
}

# --- Step 0: preflight, before anything is written ------------------------
echo "=== 0: PREFLIGHT ==="

[ -d "$STAC_DIR" ] || { echo "No $STAC_DIR — run scripts/run_pipeline.sh first." >&2; exit 1; }
[ -f "$STAC_DIR/collection.json" ] || { echo "No $STAC_DIR/collection.json." >&2; exit 1; }

# The staging interlock. 01_stage.R drops this marker for WSG_ONLY *and* for any
# silently-skipped target, so it is the signal that this tree is not a full build.
if [ -e "$RAW_DIR/PARTIAL_STAGE" ]; then
  echo "Refusing to publish: staging was partial ($(cat "$RAW_DIR/PARTIAL_STAGE"))." >&2
  echo "Re-run scripts/run_pipeline.sh for a full build." >&2
  exit 1
fi
# Releasing from a machine that holds only data/stac is supported, but say so out
# loud: with no data/raw the marker above cannot exist, so that interlock is simply
# absent rather than passing. The live-vs-build comparison below is what covers it.
[ -d "$RAW_DIR" ] || echo "note: no $RAW_DIR (release-only machine) — staging interlock not available"

local_ids=$(for f in "$STAC_DIR"/*.json; do
  b=$(basename "$f" .json); [ "$b" = collection ] || echo "$b"
done | sort)
n_local=$(printf '%s\n' "$local_ids" | grep -c . || true)
[ "$n_local" -ge 1 ] || { echo "No item JSON in $STAC_DIR." >&2; exit 1; }

# Fail before the sync if the host is unreachable, rather than after 700 MB is up.
ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null \
  || { echo "Cannot ssh to $HOST — see rtj#193 for key authorization." >&2; exit 1; }

# Registration is upsert-only, so an item dropped from the build is NOT removed
# from the API. Detect that here and make the operator act on it deliberately —
# auto-deleting from local state is how rtj's loader can empty the collection.
live_ids=$(fetch_live_ids) \
  || { echo "Could not read the live collection — refusing to publish blind." >&2; exit 1; }
n_live=$(printf '%s\n' "$live_ids" | grep -c . || true)
echo "live: $n_live | built: $n_local | host: $HOST"

orphans=$(comm -23 <(printf '%s\n' "$live_ids") <(printf '%s\n' "$local_ids") || true)
if [ -n "$orphans" ]; then
  echo "These items are LIVE but absent from this build:" >&2
  printf '  %s\n' $orphans >&2
  if [ -z "$ALLOW_RETRACT" ]; then
    echo "Fix upstream and rebuild, or re-run with --allow-retract if the removal" >&2
    echo "is deliberate. To also drop them from the API afterwards:" >&2
    echo "  scripts/item_unregister.sh $(printf '%s ' $orphans)" >&2
    exit 1
  fi
  echo "--allow-retract set — publishing a smaller collection." >&2
fi

# --- Step 1: validation gate ----------------------------------------------
echo ""
echo "=== 1: VALIDATE (gate) ==="
# Nothing below this line runs unless every document on disk validates.
#
# --expect is passed explicitly rather than left to its data/raw default: a
# release-only machine has data/stac but no data/raw, so the default would derive 0
# and refuse. Here the meaningful assertion is "every item JSON present validated" —
# catching a wrong --base or an unreadable file. Detecting a *short* build is the
# live-vs-build comparison's job in step 0, which works without data/raw.
uv run python scripts/item_validate.py --base "$STAC_DIR" --expect "$n_local"

# --- Step 2: sync assets ---------------------------------------------------
if [ -n "$SKIP_SYNC" ]; then
  echo ""
  echo "=== 2+3: SYNC SKIPPED (--skip-sync) ==="
  echo "Assets and JSON on S3 are assumed current; registering from local files."
else

echo ""
echo "=== 2: SYNC ASSETS ==="
# Exclude dotfiles at the root AND nested (macOS drops .DS_Store into item dirs);
# exclude *.json so the item/collection docs go in step 3, after their assets, and
# so the 68 terra .tif.aux.json sidecars never reach the bucket.
#
# No --size-only: a re-run after fixing an upstream number must re-upload even if
# the compressed size matches (LCHL's floodplain.gpkg is byte-identical in size to
# its S3 copy). No --delete: data/stac is wiped and rebuilt every run, so --delete
# would turn any short build into irreversible asset loss — versioning is Suspended.
aws s3 sync "$STAC_DIR" "s3://$BUCKET" \
  --exclude '.*' --exclude '*/.*' --exclude '*.json'

# --- Step 3: sync JSON -----------------------------------------------------
echo ""
echo "=== 3: SYNC JSON ==="
# After the assets, so a document never references an object that has not landed.
# Also keeps the bucket authoritative: rtj's stac_register-all.sh still reloads this
# collection from S3, and that must be a no-op rather than a silent revert.
aws s3 sync "$STAC_DIR" "s3://$BUCKET" \
  --exclude '*' --include '*.json' --exclude '*/*'

fi

# --- Step 4: register ------------------------------------------------------
echo ""
echo "=== 4: REGISTER ==="
# Collection first: pgstac items reference the collection row.
bash scripts/collection_register.sh "$STAC_DIR/collection.json"
# shellcheck disable=SC2046 — ids are validated basenames, no spaces
find "$STAC_DIR" -maxdepth 1 -name '*.json' ! -name collection.json \
  | sort | xargs bash scripts/item_register.sh

# --- Step 5: verify --------------------------------------------------------
echo ""
echo "=== 5: VERIFY ==="
code=$(curl -s -o /dev/null -w '%{http_code}' "$API")
[ "$code" = "200" ] || { echo "Collection endpoint returned $code" >&2; exit 1; }

after_ids=$(fetch_live_ids)

missing=$(comm -23 <(printf '%s\n' "$local_ids") <(printf '%s\n' "$after_ids") || true)
extra=$(comm -13 <(printf '%s\n' "$local_ids") <(printf '%s\n' "$after_ids") || true)
fail=0
if [ -n "$missing" ]; then echo "NOT REGISTERED:"; printf '  %s\n' $missing; fail=1; fi
if [ -n "$extra" ] && [ -z "$ALLOW_RETRACT" ]; then
  echo "LIVE BUT NOT IN THIS BUILD:"; printf '  %s\n' $extra
  echo "  drop with: scripts/item_unregister.sh $(printf '%s ' $extra)"
  fail=1
fi

# Asset probe: catches "the JSON is live but its COG never uploaded", which no amount
# of id comparison can see. Probing the LARGEST local asset and comparing
# Content-Length to the local byte count, not just asking for a 200 — a 200 alone is
# meaningless here, since the alphabetically-first asset exists from every prior
# release and would answer 200 even if step 2 uploaded nothing at all.
probe_item=$(printf '%s\n' "$local_ids" | head -1)
read -r probe_href probe_local <<EOF
$(python3 -c "
import json, pathlib
d = json.load(open('$STAC_DIR/$probe_item.json'))
best = None
for a in d['assets'].values():
    name = a['href'].rsplit('/', 1)[-1]
    p = pathlib.Path('$STAC_DIR/$probe_item') / name
    if p.exists() and (best is None or p.stat().st_size > best[1]):
        best = (a['href'], p.stat().st_size)
print(best[0], best[1])")
EOF
probe_remote=$(curl -sI --max-time 60 "$probe_href" \
  | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
echo "asset probe ($probe_item): local=$probe_local remote=${probe_remote:-none}"
if [ "$probe_remote" != "$probe_local" ]; then
  echo "  asset on S3 does not match the local build" >&2
  fail=1
fi

# Download that asset and verify its published file:checksum end to end. Size alone
# is no longer a sufficient probe now that we publish checksums: --skip-sync
# registers local JSON without re-uploading, so the catalogue could serve a checksum
# for bytes that are not on S3 — and a same-size object would pass the check above.
# This is also the only step that proves what the feature claims: that a consumer
# downloading an asset can verify it against the catalogue.
probe_expect=$(python3 -c "
import json
d = json.load(open('$STAC_DIR/$probe_item.json'))
print(next(a['file:checksum'] for a in d['assets'].values() if a['href'] == '$probe_href'))")
probe_actual=$(curl -s --max-time 300 "$probe_href" | shasum -a 256 | awk '{print "1220" $1}')
if [ "$probe_actual" = "$probe_expect" ]; then
  echo "checksum probe ($probe_item): verified against S3 — ${probe_expect:0:16}…"
else
  echo "  published file:checksum does not match the object on S3" >&2
  echo "    published ${probe_expect:0:24}…" >&2
  echo "    on S3     ${probe_actual:0:24}…" >&2
  fail=1
fi

[ "$fail" -eq 0 ] || { echo "RELEASE INCOMPLETE" >&2; exit 1; }
echo ""
echo "RELEASE COMPLETE — $(printf '%s\n' "$after_ids" | grep -c .) items live at $API"
