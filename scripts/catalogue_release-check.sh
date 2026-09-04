#!/bin/bash
# catalogue_release-check.sh — prove catalogue_release.sh --only can never reach collection.json,
# and that a full release is a tag.
#
# Runs the REAL release script against a synthetic tree with every external replaced by a
# shim earlier on PATH (aws, ssh, uv, curl). No network, no credentials, no data/stac. The
# script runs from a COPY of scripts/ inside a throwaway git repo under $WORK, committed
# and tagged v9.9.9 with a NEWS.md to match: the release's version gate reads git and
# NEWS.md from its own checkout, and pointing it at the real one would tie every case to
# whatever HEAD the developer happens to be on. Nothing else in the release path depends on
# the real checkout (uv is shimmed, STAC_DIR/RAW_DIR are absolute), so the copy is the whole
# script, byte for byte. The shims log their argv, and the assertions read the log:
#
#   1  --only <id>   never syncs the tree root, never a JSON sweep, never `load collections`,
#                    and never passes the provenance floor to the validator (skipped out loud)
#   2  full release  DOES sync the tree root with --include *.json and DOES `load collections`
#                    — the positive control, found by the SAME greps case 1 uses. Without it
#                    case 1 is a search that has never been shown to match anything. Also
#                    passes `--expect-provenance <PROVENANCE_FLOOR>` to the validator (#32):
#                    uv is shimmed, so the flag is proven from the shim's argv log
#   3  refusals      exit non-zero with NO aws call: bad id, missing id, not-live id, bare
#                    --only, --only + --allow-retract; and the untouched PARTIAL_STAGE interlock
#   4  verify        a membership change after registration -> RELEASE INCOMPLETE
#   5  verify        a checksum mismatch under --only still fails the release
#   6  verify        a live item still serving an OLD asset checksum after registration fails it
#   7  verify        a live item whose PROPERTIES are stale, with no byte changed, fails it too
#   8  verify        the API serving a different version than the tag -> RELEASE INCOMPLETE
#   9  verify        the API serving NO version after a full release fails it; so does the
#                    bucket copy of collection.json disagreeing with the API
#  10  refusal       HEAD not exactly at a tag -> refused, no aws call
#  11  refusal       NEWS.md's top entry not the tag ("## Unreleased" above it) -> refused;
#                    and a NEWS.md on disk but NOT in the tagged commit -> refused (the gate
#                    reads the tag's copy, since the clean-tree gate hides untracked files)
#  12  --only        never stamps: collection.json is byte-identical across the run, and a
#                    live collection with NO version passes (MISSING -> MISSING is unchanged)
#  13  refusal       a modified tracked file -> refused, no aws call
#  14  gate          a second, non-release tag on the same commit does not confuse the gate
#  15  --only        a live item carrying a provenance value that this build would publish as
#                    null is refused before anything is written — per key, so a partial loss
#                    (network kept, landcover lost) is refused too (the floor's stand-in)
#
#  9c  verify      the API serving license 'proprietary' after a full release -> refused
#  9d  verify      the API dropping sci:citation -> refused
#  9e  verify      the API dropping the rel=license link -> refused; the one of the three
#                  that could plausibly vanish alone, since pgstac rebuilds a collection's
#                  links through get_links() rather than serving the stored array
#  9f  verify      the bucket copy losing the licence -> refused, as for the version
#  9g  verify      the API serving an ALTERED sci:citation -> refused
#  9h  verify      the rel=license link served at a REWRITTEN href -> refused. Deletion is not
#                  the only failure mode and not even the likely one: rewriting an href is
#                  what pgstac does to a link it keeps
#  9i  verify      the API dropping the rel=derived_from link -> refused
#  9j  verify      a BUILT collection.json missing the citation and the licence link is
#                  refused, naming the BUILD as the side at fault. Every knob above breaks
#                  only the served side, so without this the both-absent state — where a
#                  plain `served != built` compares equal — has no fixture
#
# Case 2's "live version 9.9.9 verified" is tautological on its own — the curl shim serves
# the stamped fixture back — which is why cases 8 and 9 exist: they are what prove the
# compare bites. Its "licence verified" lines are tautological for exactly the same reason,
# and 9c-9j are their 8-and-9.
#
# Usage: bash scripts/catalogue_release-check.sh        (exit = number of failed assertions)
#
# The one thing this cannot see: item_validate.py is shimmed away (uv exits 0), so a wrong
# --expect under --only is not covered here — nor are check_collection_metadata and
# check_citation_premise (#47), which never run in this harness for the same reason. Those
# are proven against the real build, by mutating item_create.py's constants and grepping
# for each guard's own message; what is proven HERE is only that the release refuses a
# collection the API or the bucket is not serving correctly.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

WORK=$(mktemp -d -t release_check.XXXXXX) || exit 1
[ -n "$WORK" ] || exit 1
trap 'rm -rf "$WORK"' EXIT

# --- the throwaway checkout the release runs from ---------------------------------------
# One tag on the commit, a NEWS.md whose top entry names it, nothing else. Identity given
# inline, signing off, hooks skipped, so the harness does not depend on the developer's git
# config (a global commit.gpgsign would otherwise block the fixture commit on a passphrase).
TREPO="$WORK/repo"
RELEASE="$TREPO/scripts/catalogue_release.sh"
TVERSION=9.9.9
mkdir -p "$TREPO" && cp -R "$REPO/scripts" "$TREPO/scripts" && rm -rf "$TREPO/scripts/__pycache__"
printf '# fixture\n\n## v%s (2026-01-01)\n\n- fixture release\n' "$TVERSION" > "$TREPO/NEWS.md"
tgit() { git -C "$TREPO" -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false -c tag.gpgSign=false "$@"; }
tgit init -q -b main && tgit add -A && tgit commit -q --no-verify -m fixture && tgit tag "v$TVERSION"
TSHA=$(tgit rev-parse HEAD)

BUCKET=check-bucket
COLL=check-collection
S3_BASE="https://$BUCKET.s3.us-west-2.amazonaws.com"   # the shape item_create.py emits
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
    # nge:kept is a value on both sides, so a PARTIAL loss is representable (case 15): the
    # shim can serve a live value for nge:probe while the build still has nge:kept.
    doc = {"type": "Feature", "stac_version": "1.0.0", "id": iid, "collection": coll,
           "geometry": None,
           "properties": {"datetime": "2023-01-01T00:00:00Z", "nge:probe": None, "nge:kept": "same"},
           "links": [], "assets": assets}
    json.dump(doc, open(os.path.join(stac, iid + ".json"), "w"))
item("aaaa_ch_ff04", {"classified_2017.tif": 3, "floodplain_landcover.gpkg": 40})
item("bbbb_ch_ff04", {"classified_2017.tif": 3, "floodplain_landcover.gpkg": 40})
# The licence fields (#47) are part of the fixture because step 5 now reads all three back
# from the API and from the bucket, so a full release refuses a collection without them.
# They are the values catalogue_release.sh expects, not item_create.py's real ones: this
# fixture stands in for a released collection, and its citation only has to be non-empty.
json.dump({"type": "Collection", "stac_version": "1.0.0", "id": coll, "description": "fixture",
           "license": "CC-BY-4.0", "extent": {},
           "sci:citation": "fixture citation",
           "links": [{"rel": "license",
                      "href": "https://creativecommons.org/licenses/by/4.0/"},
                     {"rel": "derived_from",
                      "href": "https://example.invalid/collections/src"}]},
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
#   /collections/<id> -> the fixture collection.json as on disk (stamped, once case 2 has
#                        run), with its version forced by FAKE_LIVE_VERSION (`none` drops
#                        the key entirely — the state before any versioned release)
#   otherwise         -> the fixture file's bytes (the checksum probe); for the bucket's
#                        collection.json, FAKE_BUCKET_VERSION forces the version the same way
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
# Serve the fixture collection with one field broken on request. The licence knobs break
# exactly ONE field each, deliberately: a case that broke all three could pass on the
# strength of any one of them, and would not show that the compare bites per field.
force_fields() { # file version_forced licence_forced -> JSON on stdout
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); v = sys.argv[2]; lic = sys.argv[3]
if v == "none": d.pop("version", None)
elif v: d["version"] = v
def drop(rel): d["links"] = [l for l in d.get("links", []) if l.get("rel") != rel]
def rewrite(rel, href):
    for l in d.get("links", []):
        if l.get("rel") == rel: l["href"] = href
if lic == "license": d["license"] = "proprietary"
elif lic == "citation": d.pop("sci:citation", None)
# The ALTERED modes, not just the absent ones. A presence check answers OK for a citation
# reading "all rights reserved" and for a licence link pointing anywhere at all, and href
# rewriting is precisely what pgstac does to a link it keeps (urljoin against the API root).
elif lic == "citation-altered": d["sci:citation"] = "Copyright. All rights reserved."
elif lic == "link": drop("license")
elif lic == "link-href": rewrite("license", "https://images.a11s.one/collections/creativecommons.org/licenses/by/4.0/")
elif lic == "derived-link": drop("derived_from")
elif lic: raise SystemExit("unknown licence knob: " + lic)
print(json.dumps(d))' "$1" "$2" "$3"
}
case "$url" in
  */collections/$COLLECTION)   # the live collection read (the version gate + step 5)
    force_fields "$STAC_DIR/collection.json" "${FAKE_LIVE_VERSION:-}" "${FAKE_LIVE_LICENCE:-}"
    exit 0 ;;
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
        provenance) sed 's/"properties": {/"properties": {"nge:probe": "live-value", /' ;;   # live has a value the build does not
        *) cat ;;
      esac
    exit 0 ;;
esac
rel="${url#*.amazonaws.com/}"
f="$STAC_DIR/$rel"
[ -f "$f" ] || { echo "curl shim: no fixture for $url" >&2; exit 22; }
if [ -n "$head" ]; then
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$(wc -c < "$f" | tr -d ' ')"
elif [ "$rel" = collection.json ] && { [ -n "${FAKE_BUCKET_VERSION:-}" ] || [ -n "${FAKE_BUCKET_LICENCE:-}" ]; }; then
  force_fields "$f" "${FAKE_BUCKET_VERSION:-}" "${FAKE_BUCKET_LICENCE:-}"
else
  cat "$f"
fi
SHIM
chmod +x "$BIN"/aws "$BIN"/ssh "$BIN"/uv "$BIN"/curl

# --- runner ----------------------------------------------------------------------------
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
LIVE_AFTER=""
STALE=""
LIVEV=""
BUCKETV=""
LIVELIC=""
BUCKETLIC=""
RC=0
run_release() {
  : > "$LOG"; rm -f "$WORK/search_count"
  set +e
  ( cd "$TREPO" && PATH="$BIN:$PATH" SHIM_LOG="$LOG" COUNTER="$WORK/search_count" \
      STAC_DIR="$STAC" RAW_DIR="$RAW" BUCKET="$BUCKET" COLLECTION="$COLL" \
      FAKE_LIVE_IDS="$LIVE" FAKE_LIVE_IDS_AFTER="$LIVE_AFTER" FAKE_LIVE_ITEM_STALE="$STALE" \
      FAKE_LIVE_VERSION="$LIVEV" FAKE_BUCKET_VERSION="$BUCKETV" \
      FAKE_LIVE_LICENCE="$LIVELIC" FAKE_BUCKET_LICENCE="$BUCKETLIC" \
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
# The validator's argv: the flag and its value are adjacent fields on the uv line. n_uv is
# the premise beside every floor_passed compare — an empty result from a run that never
# invoked the validator at all would otherwise read as "no floor passed".
n_uv()         { awk -F'\t' '$1=="uv"' "$LOG" | grep -c . || true; }
floor_passed() { awk -F'\t' '$1=="uv" { for (i=1;i<=NF;i++) if ($i=="--expect-provenance") print $(i+1) }' "$LOG"; }
# ...and the flag's own count, because floor_passed prints "" both for an absent flag and for
# a flag with an empty value — which argparse would reject, but the log would not show.
n_floor_flag() { awk -F'\t' '$1=="uv" { for (i=1;i<=NF;i++) if ($i=="--expect-provenance") n++ } END { print n+0 }' "$LOG"; }

refused() { # desc — the last run must have exited non-zero having touched nothing
  if [ "$RC" -ne 0 ] && [ "$(n_aws)" -eq 0 ]; then pass "$1"
  else fail "$1 (rc=$RC, aws calls=$(n_aws))"; fi
}
coll_version() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version", "MISSING"))' "$STAC/collection.json"; }
coll_hash()    { shasum -a 256 "$STAC/collection.json" | awk '{print $1}'; }

# --- case 2 first: the positive control ----------------------------------------------
# A full release on this fixture must reach collection.json by both routes. If these
# greps cannot find it here, case 1's zeros mean nothing.
echo "case 2: full release reaches collection.json (positive control)"
rm "$RAW/PARTIAL_STAGE"
expect_eq "fixture collection starts unversioned" "$(coll_version)" MISSING
run_release
expect_eq "exit 0" "$RC" 0
expect_eq "two root-source syncs (assets, then JSON)" "$(n_root_sync)" 2
expect_eq "one --include *.json sweep" "$(n_json_sweep)" 1
expect_eq "one load collections" "$(n_load_coll)" 1
expect_eq "one load items" "$(n_load_items)" 1
expect_out "version gate passed on the tagged checkout" "release v$TVERSION: HEAD at v$TVERSION, tree clean, NEWS.md agrees"
expect_eq "collection.json on disk is stamped" "$(coll_version)" "$TVERSION"
expect_out "verify read the live version back" "live collection version: $TVERSION — matches the tag just released"
expect_out "verify read the bucket copy back" "bucket collection.json version: $TVERSION — agrees"
expect_out "verify read the licence back from the API" "live collection licence: CC-BY-4.0, sci:citation and both links served as published"
expect_out "verify read the licence back from the bucket" "bucket collection.json licence: agrees"
expect_out "completion line names the version" "RELEASE COMPLETE — v$TVERSION"
# Read the literal out of the script with an anchored sed, so a renamed variable, a quoted
# value or a `${PROVENANCE_FLOOR:-0}` rewrite of the literal reads as an empty premise rather
# than a passing compare. (An override ADDED after the literal is not caught here — the
# harness sets no such variable — only the literal's own shape is.)
FLOOR_LITERAL=$(sed -n 's/^PROVENANCE_FLOOR=\([0-9][0-9]*\)$/\1/p' "$RELEASE")
# Same premise for the licence (#47). Step 5's only comparison against a constant is
# `license`, so an env fallback added later — EXPECT_LICENSE="${EXPECT_LICENSE:-CC-BY-4.0}" —
# would hand the one field a consumer's rights turn on an override, and every case here would
# stay green because the harness never sets it. The floor is pinned as a bare literal for
# exactly this reason; so is this. Same limitation as the floor's, said out loud: this reads
# the ASSIGNMENT, so it catches an inline default but not a separate later reassignment.
LICENCE_LITERAL=$(sed -n 's/^EXPECT_LICENSE="\([^"$]*\)"$/\1/p' "$RELEASE")
expect_eq "premise: EXPECT_LICENSE is one bare literal with no env fallback" "$LICENCE_LITERAL" "CC-BY-4.0"
expect_eq "premise: PROVENANCE_FLOOR is one bare integer literal in the script" "$(printf '%s' "$FLOOR_LITERAL" | grep -c '^[0-9][0-9]*$')" 1
expect_eq "premise: the validator was invoked once" "$(n_uv)" 1
expect_eq "the flag appears once on the validator's argv" "$(n_floor_flag)" 1
expect_eq "validator was given exactly that literal as --expect-provenance" "$(floor_passed)" "$FLOOR_LITERAL"
echo aaaa > "$RAW/PARTIAL_STAGE"

# --- cases 8-13: the version gate and the version verify ---------------------------------
# All full releases, so the PARTIAL_STAGE marker stays off until the --only cases below.
rm "$RAW/PARTIAL_STAGE"
echo "case 8: the API serving a different version than the tag fails the release"
LIVEV=8.8.8
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "RELEASE INCOMPLETE" "RELEASE INCOMPLETE"
expect_out "names both versions" "live collection version is '8.8.8', but this release is v$TVERSION"
LIVEV=""

echo "case 9: the API serving NO version after a full release fails it"
LIVEV=none
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the absence" "live collection version is 'MISSING', but this release is v$TVERSION"
LIVEV=""
echo "case 9b: the bucket copy of collection.json disagreeing with the API fails it"
BUCKETV=7.7.7
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the bucket version" "bucket collection.json version is '7.7.7', but this release is v$TVERSION"
BUCKETV=""

# Cases 9c-9e are to the licence read-back what 8 and 9 are to the version gate. Case 2's
# "licence verified" line is tautological on its own — the curl shim serves the fixture
# straight back from disk — so without these the new step-5 check is a search that has
# never been shown to match anything. One field broken per case, because the three are
# lost by different mechanisms: `license` and `sci:citation` ride in the stored document,
# while the LINK is rebuilt by pgstac's get_links() and is the one that could plausibly
# vanish on its own.
echo "case 9c: the API serving license 'proprietary' after a full release fails it"
LIVELIC=license
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "RELEASE INCOMPLETE" "RELEASE INCOMPLETE"
expect_out "names the served licence" "the API is not serving the licence this build published: license='proprietary'"
LIVELIC=""

echo "case 9d: the API dropping sci:citation fails the release"
LIVELIC=citation
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the dropped citation" "the API is not serving the licence this build published: sci:citation-absent"
LIVELIC=""

echo "case 9e: the API dropping the rel=license link fails the release"
LIVELIC=link
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the absent link" "the API is not serving the licence this build published: rel=license-link-absent"
LIVELIC=""

echo "case 9f: the bucket copy losing the licence fails it too"
BUCKETLIC=license
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the bucket licence" "the bucket copy does not carry the licence this build published: license='proprietary'"
BUCKETLIC=""

# 9g-9i are the ALTERED modes. 9c-9f only DELETE a field, and a check written as "is it
# present" passes every one of them while still answering OK for a citation reading
# "all rights reserved" and a licence link pointing anywhere at all — both measured against
# the real collection before this was fixed. Href rewriting is not hypothetical either: it
# is the one thing pgstac does to a link it keeps.
echo "case 9g: the API serving an ALTERED sci:citation fails the release"
LIVELIC=citation-altered
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the differing citation" "the API is not serving the licence this build published: sci:citation-differs"
LIVELIC=""

echo "case 9h: the API serving the rel=license link at a REWRITTEN href fails the release"
LIVELIC=link-href
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the rewritten href" "rel=license-href="
LIVELIC=""

echo "case 9i: the API dropping the rel=derived_from link fails the release"
LIVELIC=derived-link
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the absent derived_from link" "rel=derived_from-link-absent"
LIVELIC=""

# 9j mutates the BUILT side, which every knob above leaves alone. Without it the both-absent
# state — the one round 2's fix is actually about — has no fixture at all, and a rewrite back
# to a plain `served != built` would stay green here because None == None. Proved to
# discriminate: on the pre-fix form this case reports RELEASE COMPLETE while publishing a
# collection carrying no attribution whatsoever.
echo "case 9j: a BUILT collection missing the citation and the licence link is refused"
cp "$STAC/collection.json" "$WORK/coll_built.bak"
python3 -c 'import json, sys
p = sys.argv[1]; d = json.load(open(p))
d.pop("sci:citation", None)
d["links"] = [l for l in d.get("links", []) if l.get("rel") != "license"]
json.dump(d, open(p, "w"))' "$STAC/collection.json"
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the build as the side at fault (citation)" "built-has-no-citation"
expect_out "names the build as the side at fault (link)" "built-has-no-license-link"
cp "$WORK/coll_built.bak" "$STAC/collection.json"

echo "case 10: HEAD not exactly at a tag is refused"
tgit commit -q --no-verify --allow-empty -m "past the tag"
run_release;                                        refused "untagged HEAD"
expect_out "says to tag first" "HEAD is not at a vX.Y.Z tag"
tgit reset -q --hard "$TSHA"

echo "case 11: NEWS.md whose top entry is not the tag is refused"
printf '# fixture\n\n## Unreleased\n\n- pending\n\n## v%s (2026-01-01)\n\n- fixture release\n' "$TVERSION" > "$TREPO/NEWS.md"
tgit commit -q --no-verify -am "unreleased section on top" && tgit tag -f "v$TVERSION" >/dev/null
run_release;                                        refused "NEWS top entry is '## Unreleased'"
expect_out "names the top entry" "NEWS.md's top entry is '## Unreleased'"
tgit tag -f "v$TVERSION" "$TSHA" >/dev/null && tgit reset -q --hard "$TSHA"

echo "case 11b: NEWS.md on disk but absent from the tagged commit is refused"
# The first-release shape: NEWS.md written, never added, commit + tag made beside it. The
# working copy still names the tag, and --untracked-files=no cannot see it.
tgit rm -q --cached NEWS.md && tgit commit -q --no-verify -m "news left untracked" && tgit tag -f "v$TVERSION" >/dev/null
expect_eq "premise: NEWS.md is on disk" "$([ -f "$TREPO/NEWS.md" ] && echo yes)" yes
expect_eq "premise: NEWS.md is not in the tag" "$(tgit show "v$TVERSION:NEWS.md" >/dev/null 2>&1 || echo absent)" absent
run_release;                                        refused "untracked NEWS.md"
expect_out "names the tagged commit" "No NEWS.md in v$TVERSION"
tgit tag -f "v$TVERSION" "$TSHA" >/dev/null && tgit reset -q --hard "$TSHA"

echo "case 13: a modified tracked file is refused"
printf '\n# scribble\n' >> "$TREPO/scripts/item_register.sh"
run_release;                                        refused "dirty tracked tree"
expect_out "names the file" "Tracked files differ from v$TVERSION"
tgit checkout -q -- . && expect_eq "throwaway checkout restored" "$(tgit status --porcelain | wc -l | tr -d ' ')" 0

echo "case 14: a second, annotated, non-release tag on the commit does not confuse the gate"
# An annotated tag wins over a lightweight one in a bare `describe --exact-match`, so
# without --match the gate would read 'zz-note' as the version and refuse against NEWS.md.
tgit tag -a zz-note -m "not a release" >/dev/null
run_release
expect_eq "exit 0" "$RC" 0
expect_out "the release tag was the one read" "release v$TVERSION: HEAD at v$TVERSION"
tgit tag -d zz-note >/dev/null
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
expect_eq "all four skips said out loud (interlock, comparison, version gate, provenance floor)" "$(grep -c 'skipped under --only' "$OUT" || true)" 4
expect_out "the provenance floor skip is the one named" "provenance floor: skipped under --only"
expect_eq "premise: the validator was invoked once" "$(n_uv)" 1
expect_eq "the validator was NOT given a provenance floor (flag absent, not merely empty)" "$(n_floor_flag)" 0
expect_out "preflight compared the item's live provenance (the control: nothing lost)" "provenance under --only: live item carries 1 nge: value(s), this build carries 1."
expect_out "verify probed the named item" "checksum probe (aaaa_ch_ff04)"
expect_out "verify read the live item back (a null property served as absent)" "pgstac serves the document just built — 2 assets, 3 properties"
expect_out "the version gate was skipped out loud" "version gate: skipped under --only"
expect_out "the live version was read and unchanged" "live collection version: $TVERSION (unchanged by --only"

# --- case 12: --only never stamps, and an unversioned live collection is fine ------------
echo "case 12: --only leaves collection.json untouched and accepts a live collection with no version"
h0=$(coll_hash)
LIVEV=none
run_release --only aaaa_ch_ff04
expect_eq "exit 0" "$RC" 0
expect_eq "collection.json byte-identical across the run" "$(coll_hash)" "$h0"
expect_out "MISSING -> MISSING read as unchanged" "live collection version: MISSING (unchanged by --only"
LIVEV=""

# --- case 15: the floor's stand-in under --only (after case 12: it replaces $OUT) ------------------------------------------
echo "case 15: a live provenance value this build would publish as null is refused (partial loss)"
# Live serves nge:kept AND nge:probe; the build has nge:kept and a null nge:probe. Counts are
# 2 vs 1 — a total-loss check (build == 0) would pass this; the per-key check must not.
STALE=provenance
run_release --only aaaa_ch_ff04;                    refused "a partial provenance loss is refused before any write"
expect_out "counts show the partial shape" "live item carries 2 nge: value(s), this build carries 1."
expect_out "names the lost key" "would publish as null: nge:probe"
STALE=""

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
