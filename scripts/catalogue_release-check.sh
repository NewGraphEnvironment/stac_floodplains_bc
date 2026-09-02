#!/bin/bash
# catalogue_release-check.sh — prove catalogue_release.sh --only can never reach collection.json.
#
# Runs the REAL release script against a synthetic tree with every external replaced by a
# shim earlier on PATH (aws, ssh, uv, curl). No network, no credentials, no data/stac. The
# shims log their argv, and the assertions read the log:
#
#   1  --only <id>   never syncs the tree root, never a JSON sweep, never `load collections`
#   2  full release  DOES sync the tree root with --include *.json and DOES `load collections`
#                    — the positive control, found by the SAME greps case 1 uses. Without it
#                    case 1 is a search that has never been shown to match anything.
#   3  refusals      exit non-zero with NO aws call: bad id, missing id, not-live id, bare
#                    --only, --only + --allow-retract; and the untouched PARTIAL_STAGE interlock
#   4  verify        a membership change after registration -> RELEASE INCOMPLETE
#   5  verify        a checksum mismatch under --only still fails the release
#   6  verify        a live item still serving an OLD asset checksum after registration fails it
#   7  verify        a live item whose PROPERTIES are stale, with no byte changed, fails it too
#
# Usage: bash scripts/catalogue_release-check.sh        (exit = number of failed assertions)
#
# The one thing this cannot see: item_validate.py is shimmed away (uv exits 0), so a wrong
# --expect under --only is not covered here. Its own guards are proven in the validator.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="$REPO/scripts/catalogue_release.sh"

WORK=$(mktemp -d -t release_check.XXXXXX) || exit 1
[ -n "$WORK" ] || exit 1
trap 'rm -rf "$WORK"' EXIT

BUCKET=check-bucket
COLL=check-collection
S3_BASE="https://$BUCKET.s3.us-west-2.amazonaws.com"   # the shape 05_stac_register.py emits
STAC="$WORK/stac"; RAW="$WORK/raw"; BIN="$WORK/bin"; LOG="$WORK/shim.log"; OUT="$WORK/out.txt"
mkdir -p "$STAC" "$RAW" "$BIN"

# --- fixture ---------------------------------------------------------------------------
# Two items; every asset exists on disk under <id>/ named as its href basename, one strictly
# largest so the release's probe pick is deterministic, each carrying a correct multihash.
python3 - "$STAC" "$S3_BASE" "$COLL" <<'PY'
import hashlib, json, os, sys
stac, s3, coll = sys.argv[1:4]
def item(iid, sizes):
    d = os.path.join(stac, iid); os.makedirs(d)
    assets = {}
    for name, n in sizes.items():
        data = (iid + name).encode() * n
        open(os.path.join(d, name), "wb").write(data)
        assets[name.split(".")[0]] = {
            "href": f"{s3}/{iid}/{name}", "type": "application/octet-stream",
            "file:size": len(data), "file:checksum": "1220" + hashlib.sha256(data).hexdigest()}
    # nge:probe is null: the real API omits null-valued properties (measured on BULK,
    # 2026-09-02), and the curl shim mirrors that, so the read-back must accept it.
    doc = {"type": "Feature", "stac_version": "1.0.0", "id": iid, "collection": coll,
           "geometry": None, "properties": {"datetime": "2023-01-01T00:00:00Z", "nge:probe": None},
           "links": [], "assets": assets}
    json.dump(doc, open(os.path.join(stac, iid + ".json"), "w"))
item("aaaa_ch_ff04", {"classified_2017.tif": 3, "floodplain_landcover.gpkg": 40})
item("bbbb_ch_ff04", {"classified_2017.tif": 3, "floodplain_landcover.gpkg": 40})
json.dump({"type": "Collection", "stac_version": "1.0.0", "id": coll, "description": "fixture",
           "license": "proprietary", "extent": {}, "links": []},
          open(os.path.join(stac, "collection.json"), "w"))
PY
echo aaaa > "$RAW/PARTIAL_STAGE"

# --- shims -----------------------------------------------------------------------------
# One line per invocation: name, then each argv element, TAB-separated, newlines flattened.
# %s and not %q: %q would escape the spaces and asterisks every grep below relies on.
cat > "$BIN/_log" <<'SHIM'
nl=$'\n'
{ printf '%s' "$1"; shift; for a in "$@"; do printf '\t%s' "${a//$nl/ }"; done; printf '\n'; } >> "$SHIM_LOG"
SHIM
cat > "$BIN/aws" <<'SHIM'
#!/bin/bash
. "$(dirname "$0")/_log" aws "$@"
SHIM
cat > "$BIN/ssh" <<'SHIM'
#!/bin/bash
. "$(dirname "$0")/_log" ssh "$@"
cat > /dev/null      # the register scripts pipe their payload in; consume it
SHIM
cat > "$BIN/uv" <<'SHIM'
#!/bin/bash
. "$(dirname "$0")/_log" uv "$@"
SHIM
# curl: the release makes four shapes of call, with combined flags (-sI, -sf -X POST).
#   /search           -> feature list from FAKE_LIVE_IDS, or FAKE_LIVE_IDS_AFTER once a
#                        search has already happened (case 4)
#   -w '%{http_code}' -> 200
#   -I (any -*I*)     -> Content-Length of the fixture file the href maps to
#   otherwise         -> the fixture file's bytes (the checksum probe)
# The href map takes the last two path segments, the rule item_validate.py uses.
cat > "$BIN/curl" <<'SHIM'
#!/bin/bash
. "$(dirname "$0")/_log" curl "$@"
url=""; w=""; head=""
for a in "$@"; do
  case "$a" in
    http*) url="$a" ;;
    -w) w=1 ;;
    -*I*) head=1 ;;
  esac
done
case "$url" in
  */search)
    ids="$FAKE_LIVE_IDS"
    if [ -e "$COUNTER" ] && [ -n "${FAKE_LIVE_IDS_AFTER:-}" ]; then ids="$FAKE_LIVE_IDS_AFTER"; fi
    touch "$COUNTER"
    python3 -c 'import json,sys; print(json.dumps({"features":[{"id":i} for i in sys.argv[1].split()]}))' "$ids"
    exit 0 ;;
esac
if [ -n "$w" ]; then printf '200'; exit 0; fi
case "$url" in
  */items/*)   # the live item read-back: the fixture's own JSON, or a stale one (case 6)
    f="$STAC_DIR/${url##*/}.json"
    # Stale ONE asset, the first (classified_2017.tif), and leave the largest correct: a
    # read-back that compares only the probe asset (the largest, a byte-stable gpkg) is
    # exactly the false pass this case exists to catch. No /g, deliberately.
    # Serve it as the API does: null-valued properties dropped (case 1 relies on the
    # read-back accepting that), then the requested staleness on top.
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["properties"]={k:v for k,v in d["properties"].items() if v is not None}; print(json.dumps(d))' "$f" \
    | case "${FAKE_LIVE_ITEM_STALE:-}" in
        asset) sed 's/"file:checksum": "1220/"file:checksum": "1220dead/' ;;
        property) sed 's/"datetime": "2023-01-01T00:00:00Z"/"datetime": "2022-01-01T00:00:00Z"/' ;;   # no byte changes
        *) cat ;;
      esac
    exit 0 ;;
esac
rel="${url#*.amazonaws.com/}"
f="$STAC_DIR/$rel"
[ -f "$f" ] || { echo "curl shim: no fixture for $url" >&2; exit 22; }
if [ -n "$head" ]; then
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$(wc -c < "$f" | tr -d ' ')"
else
  cat "$f"
fi
SHIM
chmod +x "$BIN"/aws "$BIN"/ssh "$BIN"/uv "$BIN"/curl

# --- runner ----------------------------------------------------------------------------
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
LIVE_AFTER=""
STALE=""
RC=0
run_release() {
  : > "$LOG"; rm -f "$WORK/search_count"
  set +e
  ( cd "$REPO" && PATH="$BIN:$PATH" SHIM_LOG="$LOG" COUNTER="$WORK/search_count" \
      STAC_DIR="$STAC" RAW_DIR="$RAW" BUCKET="$BUCKET" COLLECTION="$COLL" \
      FAKE_LIVE_IDS="$LIVE" FAKE_LIVE_IDS_AFTER="$LIVE_AFTER" FAKE_LIVE_ITEM_STALE="$STALE" \
      bash "$RELEASE" "$@" ) > "$OUT" 2>&1 < /dev/null
  RC=$?
  set -e
}

FAILS=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); sed 's/^/        | /' "$OUT" | tail -12; }
expect_eq() { # desc got want
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}
expect_out() { # desc pattern -> stdout+stderr of the run contains it
  if grep -q -- "$2" "$OUT"; then pass "$1"; else fail "$1 (no '$2' in output)"; fi
}

# Log queries. Exact field compares in awk, so paths and globs need no escaping.
n_aws()        { awk -F'\t' '$1=="aws"' "$LOG" | grep -c . || true; }
n_root_sync()  { awk -F'\t' -v r="$STAC" '$1=="aws" && $3=="sync" && $4==r' "$LOG" | grep -c . || true; }
n_json_sweep() { awk -F'\t' '$1=="aws" && $3=="sync" { for (i=1;i<=NF;i++) if ($i=="--include" && $(i+1)=="*.json") print }' "$LOG" | grep -c . || true; }
n_sync_to()    { awk -F'\t' -v d="$1" '$1=="aws" && $3=="sync" && $5==d' "$LOG" | grep -c . || true; }
n_cp()         { awk -F'\t' -v s="$1" -v d="$2" '$1=="aws" && $3=="cp" && $4==s && $5==d' "$LOG" | grep -c . || true; }
n_aws_naming() { awk -F'\t' -v x="$1" '$1=="aws" && index($0, x)' "$LOG" | grep -c . || true; }
n_load_coll()  { awk -F'\t' '$1=="ssh" && index($0, "load collections")' "$LOG" | grep -c . || true; }
n_load_items() { awk -F'\t' '$1=="ssh" && index($0, "load items")' "$LOG" | grep -c . || true; }

refused() { # desc — the last run must have exited non-zero having touched nothing
  if [ "$RC" -ne 0 ] && [ "$(n_aws)" -eq 0 ]; then pass "$1"
  else fail "$1 (rc=$RC, aws calls=$(n_aws))"; fi
}

# --- case 2 first: the positive control ----------------------------------------------
# A full release on this fixture must reach collection.json by both routes. If these
# greps cannot find it here, case 1's zeros mean nothing.
echo "case 2: full release reaches collection.json (positive control)"
rm "$RAW/PARTIAL_STAGE"
run_release
expect_eq "exit 0" "$RC" 0
expect_eq "two root-source syncs (assets, then JSON)" "$(n_root_sync)" 2
expect_eq "one --include *.json sweep" "$(n_json_sweep)" 1
expect_eq "one load collections" "$(n_load_coll)" 1
expect_eq "one load items" "$(n_load_items)" 1
echo aaaa > "$RAW/PARTIAL_STAGE"

echo "case 3f: the PARTIAL_STAGE interlock still refuses a full release"
run_release
refused "refused with marker present"
expect_out "names the marker" "staging was partial"

# --- case 1: the invariant -------------------------------------------------------------
echo "case 1: --only never touches collection.json"
run_release --only aaaa_ch_ff04
expect_eq "exit 0" "$RC" 0
expect_eq "no root-source sync" "$(n_root_sync)" 0
expect_eq "no --include *.json sweep" "$(n_json_sweep)" 0
expect_eq "no aws call names collection.json" "$(n_aws_naming collection.json)" 0
expect_eq "one asset sync into the item prefix" "$(n_sync_to "s3://$BUCKET/aaaa_ch_ff04")" 1
expect_eq "one cp of the item JSON" "$(n_cp "$STAC/aaaa_ch_ff04.json" "s3://$BUCKET/aaaa_ch_ff04.json")" 1
expect_eq "exactly two aws calls in total" "$(n_aws)" 2
expect_eq "no load collections" "$(n_load_coll)" 0
expect_eq "one load items" "$(n_load_items)" 1
expect_eq "the other item is untouched" "$(n_aws_naming bbbb)" 0
expect_eq "both skips said out loud" "$(grep -c 'skipped under --only' "$OUT" || true)" 2
expect_out "verify probed the named item" "checksum probe (aaaa_ch_ff04)"
expect_out "verify read the live item back (a null property served as absent)" "pgstac serves the document just built — 2 assets, 2 properties"

# --- case 3: refusals ------------------------------------------------------------------
echo "case 3: refusals touch nothing"
run_release --only cccc_ch_ff04;                    refused "id not in the tree"
LIVE="bbbb_ch_ff04"
run_release --only aaaa_ch_ff04;                    refused "id not live"
expect_out "says a full release is needed" "full release"
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
run_release --only ../x;                            refused "malformed id"
run_release --only;                                 refused "bare --only"
run_release --only "";                              refused "empty --only"
run_release --only aaaa_ch_ff04 --allow-retract;    refused "--only with --allow-retract"

# --- case 4: verify sees a membership change -------------------------------------------
echo "case 4: membership change after registration fails the release"
LIVE_AFTER="aaaa_ch_ff04"
run_release --only aaaa_ch_ff04
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "RELEASE INCOMPLETE" "RELEASE INCOMPLETE"
expect_out "names the membership change" "membership"
LIVE_AFTER=""

# --- case 6: the live item read-back sees a stale row ------------------------------------
# The endpoint answers 200 either way; only the served document can tell a republished
# item from the one that was live before — and only if ALL of it is compared (case 7).
echo "case 6: a stale live item after registration fails the release"
STALE=asset
run_release --only aaaa_ch_ff04
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "RELEASE INCOMPLETE" "RELEASE INCOMPLETE"
expect_out "names the stale asset" "not the document just built: STALE asset:classified_2017"
STALE=""

# --- case 7: a stale PROPERTY, with every asset byte and checksum unchanged --------------
# Labels, provenance and the loss/gain figures ship in the item document, not in any asset,
# so a checksum-only read-back would pass this. It is the realistic next pilot.
echo "case 7: a stale property in the live item fails the release"
STALE=property
run_release --only aaaa_ch_ff04
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the stale property" "STALE property:datetime"
STALE=""

# --- case 5: the checksum probe still bites under --only --------------------------------
# Append to the largest asset AFTER the JSON was built: size on S3 (the shim serves the same
# file) still equals local size, so only the checksum can catch it. Last, since it corrupts.
echo "case 5: checksum mismatch under --only fails the release"
printf 'corrupt' >> "$STAC/aaaa_ch_ff04/floodplain_landcover.gpkg"
run_release --only aaaa_ch_ff04
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the checksum" "file:checksum does not match"

echo ""
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILED"; fi
exit "$FAILS"
