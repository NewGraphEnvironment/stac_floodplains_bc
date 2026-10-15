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
#                    and never passes the provenance floor to the validator (skipped out loud),
#                    but DOES pass --partial, without which the deprecation set compare (#26)
#                    refuses every group but the two marked ones
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
#  15  --only        a live item carrying provenance this build does not is refused before
#                    anything is written — per FIELD, so a partial loss (one section kept,
#                    another lost) is refused too (the floor's stand-in). Both sides are
#                    canonicalised to the staged field names, so the comparison survives #74
#  16  --only        a BUCKET copy publishing a different provenance key set is refused: the
#                    API drops nulls, so it cannot tell a pre-#74 item carrying twelve nulls
#                    from a post-#74 item that omits them, and the bucket copy is the document
#                    the release would overwrite
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
#  9k  verify      the API dropping a deprecation marker -> refused (#26)
#  9m  verify      retracting a marked item under --allow-retract does NOT fail the
#                  release — the one line covering the served-set intersection
#  9l  verify      the API marking an item this build does not -> refused. Both
#                  directions: a lost marker republishes a stale item looking current,
#                  an invented one stamps a permanent false claim on a correct item
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
SSHIN="$WORK/ssh_stdin.log"   # what the register/unregister scripts PIPE, which $LOG cannot hold
mkdir -p "$STAC" "$RAW" "$BIN"
: > "$SSHIN"   # so n_delete() has a file to read before the first run_release

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
    # REAL declared provenance names (#74), not synthetic ones: the preflight canonicalises
    # both sides through item_create.py's publish map, and a made-up key maps to nothing — so
    # a fixture of `nge:probe`/`nge:kept` would make cases 11 and 15 pass against an empty
    # comparison on both sides.
    # link:run_uid is null: the real API omits null-valued properties (measured on BULK,
    # 2026-09-02), and the curl shim mirrors that, so the read-back must accept it.
    # landcover:key is a value on both sides, so a PARTIAL loss is representable (case 15):
    # the shim can serve a live value for link:run_uid while the build still has
    # landcover:key.
    # properties.wsg, because the "no group is lost" arm reads the watershed group as a
    # published FACT on both sides — the live item's from a fielded search, the build's from
    # this document — rather than parsing it out of the id. Derived from the id HERE, in a
    # fixture builder, which is allowed to know that item_create.py writes
    # `paste0(wsg, "_", scenario)`; the release script is not.
    doc = {"type": "Feature", "stac_version": "1.0.0", "id": iid, "collection": coll,
           "geometry": None,
           "properties": {"datetime": "2023-01-01T00:00:00Z", "link:run_uid": None,
                          "landcover:key": "same", "wsg": iid.split("_")[0].upper()},
           "links": [], "assets": assets}
    json.dump(doc, open(os.path.join(stac, iid + ".json"), "w"))
item("aaaa_ch_ff04", {"classified_2017.tif": 3, "floodplain_landcover.gpkg": 40})
item("bbbb_ch_ff04", {"classified_2017.tif": 3, "floodplain_landcover.gpkg": 40})
# One fixture item carries the #26 marker, so step 5's read-back has something to compare.
# With every item unmarked the check is NONE == NONE and no negative case can reach it.
_b = json.load(open(os.path.join(stac, "bbbb_ch_ff04.json")))
_b["properties"]["deprecated"] = True
json.dump(_b, open(os.path.join(stac, "bbbb_ch_ff04.json"), "w"))
# The licence fields (#47) are part of the fixture because step 5 now reads all three back
# from the API and from the bucket, so a full release refuses a collection without them.
# They are the values catalogue_release.sh expects, not item_create.py's real ones: this
# fixture stands in for a released collection, and its citation only has to be non-empty.
json.dump({"type": "Collection", "stac_version": "1.0.0", "id": coll, "description": "fixture",
           "license": "CC-BY-4.0", "extent": {},
           "sci:citation": "fixture citation",
           # rel:item links, because that is what item_create.py writes and what step 5's
           # bucket read-back and rtj's reload-from-S3 both read. Without them the read-back
           # iterated an empty set and reported "all 0 linked item(s) present".
           "links": [{"rel": "item", "href": f"{s3}/aaaa_ch_ff04.json"},
                     {"rel": "item", "href": f"{s3}/bbbb_ch_ff04.json"},
                     {"rel": "license",
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
# Logs and exits 0, EXCEPT for `s3 ls --summarize`, which models the real exit status: aws
# exits 1 when a prefix matches no objects, while still printing "Total Objects: 0". With a
# blanket exit 0 that state was unreachable, so item_retract_s3.sh's guard against it could not
# be tested — a mutation removing the guard left case 22e green. Measured against the real
# bucket 2026-10-14: an absent prefix prints the two Total lines and exits 1.
cat > "$BIN/aws" <<'SHIM'
#!/bin/bash
. "$(dirname "$0")/_log" aws "$@"
if [ "${1:-}" = s3 ] && [ "${2:-}" = ls ]; then
  for a in "$@"; do case "$a" in --summarize) sum=1 ;; s3://*) u="$a" ;; esac; done
  [ -n "${sum:-}" ] || exit 0
  rel="${u#s3://}"; rel="${rel#*/}"
  n=0; bytes=0
  if [ -n "$rel" ] && [ -d "$STAC_DIR/$rel" ]; then
    for f in "$STAC_DIR/$rel"/*; do
      [ -f "$f" ] || continue
      n=$((n + 1)); bytes=$((bytes + $(wc -c < "$f")))
    done
  fi
  printf '\nTotal Objects: %s\n   Total Size: %s\n' "$n" "$bytes"
  [ "$n" -gt 0 ] || exit 1
fi
SHIM
# The payload, not just the argv. item_unregister.sh names its ids in the SQL it pipes in,
# never on the command line, so a `delete_item` is invisible in $LOG and n_delete() below
# would count zero however many items a run destroyed. Appended to its own file because the
# SQL is multi-line and $LOG is one line per invocation.
cat > "$BIN/ssh" <<'SHIM'
#!/bin/bash
. "$(dirname "$0")/_log" ssh "$@"
cat >> "$SSH_STDIN_LOG"
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
# FIXTURE_ROOT, not STAC_DIR: what the BUCKET serves is a property of the harness, while
# STAC_DIR is an input to the script under test, and case 22a2 has to empty the second
# without emptying the first — a release-only machine still has a populated bucket.
FIXTURE_ROOT="${FIXTURE_ROOT:-$STAC_DIR}"
url=""; w=""; head=""; body=""; takebody=""
for a in "$@"; do
  case "$a" in
    http*) url="$a" ;;
    -w) w=1 ;;
    -d) takebody=1 ;;
    -*I*) head=1 ;;
    *) [ -z "$takebody" ] || { body="$a"; takebody=""; } ;;
  esac
done
case "$url" in
  */search)
    # Three stages of the live catalogue: the preflight, the post-register membership compare,
    # and the post-delete re-read.
    #
    # Counted on the ID-ONLY search, not on every /search. A retirement release issues FIVE:
    # fetch_live_ids three times, fetch_live_wsgs once in the preflight, and the deprecation
    # read-back once in step 5 — each distinguishable by its `fields.include`. Counting all of
    # them put FAKE_LIVE_IDS_FINAL on step 5'"'"'s compare, which runs BEFORE the delete, so
    # case 21a modelled a catalogue that had lost the item already and its step-5 containment
    # arm was never exercised at all. Measured: with the old counter, replacing that arm with
    # equality left 21a — the positive control — fully green.
    #
    # The other two shapes read the CURRENT stage (one behind the id-only count) rather than
    # advancing it: within one phase of a release every read sees the same catalogue.
    _n=0; [ -e "$COUNTER" ] && _n=$(grep -c . "$COUNTER" || true)
    case "$body" in
      *properties.wsg*|*properties.deprecated*) _stage=$((_n > 0 ? _n - 1 : 0)) ;;
      *) _stage="$_n"; echo x >> "$COUNTER" ;;
    esac
    ids="$FAKE_LIVE_IDS"
    if [ "$_stage" -ge 1 ] && [ -n "${FAKE_LIVE_IDS_AFTER:-}" ]; then ids="$FAKE_LIVE_IDS_AFTER"; fi
    if [ "$_stage" -ge 2 ] && [ -n "${FAKE_LIVE_IDS_FINAL:-}" ]; then ids="$FAKE_LIVE_IDS_FINAL"; fi
    # Echo `properties.deprecated` back from the BUILT tree, so step 5's marker read-back has
    # a positive control at all (#26). Serving ids only made it a NONE == NONE tautology that
    # no fixture could break — the same trap this harness already documents for the version
    # and licence checks. FAKE_LIVE_DEPRECATED overrides the served set: `none` drops every
    # marker, any other value is the literal id list to serve.
    python3 -c 'import glob, json, os, sys
ids = sys.argv[1].split()
forced = os.environ.get("FAKE_LIVE_DEPRECATED", "")
if forced == "none":
    marked = set()
elif forced:
    marked = set(forced.split())
else:
    marked = set()
    for p in glob.glob(os.path.join(sys.argv[2], "*.json")):
        d = json.load(open(p))
        if d.get("type") == "Feature" and (d.get("properties") or {}).get("deprecated") is True:
            marked.add(d["id"])
# wsg beside the marker, from the build document where there is one and derived from the id
# otherwise — which is how the real API answers, since item_create.py writes the id FROM the
# wsg. Deriving it here is what lets a live-only id (no build file) model a LOST group.
def wsg_of(i):
    p = os.path.join(sys.argv[2], i + ".json")
    if os.path.exists(p):
        w = (json.load(open(p)).get("properties") or {}).get("wsg")
        if w:
            return w
    return i.split("_")[0].upper()
feats = [{"id": i, "properties": dict({"wsg": wsg_of(i)},
                                      **({"deprecated": True} if i in marked else {}))}
         for i in ids]
print(json.dumps({"features": feats}))' "$ids" "$FIXTURE_ROOT"
    exit 0 ;;
esac
# FAKE_GONE_IDS before the blanket 200, not after: every -w '%{http_code}' call took this
# branch, so the release's "is the retired id gone" probe could only ever read 200 and the
# assertion could not fail. The list is ids, matched against the url's last segment.
for _g in ${FAKE_GONE_IDS:-}; do
  case "$url" in
    */items/"$_g") if [ -n "$w" ]; then printf '404'; exit 0; fi
                   echo "curl shim: $_g is gone" >&2; exit 22 ;;
  esac
done
# A -w probe of a BUCKET key has to answer for THAT key. The blanket 200 below made the
# release's "was this id ever published" arm unreachable, and worse than unreachable: case 20c
# went on passing, because the could-not-read message it actually triggered happens to contain
# the phrase the case greps for. A fixture that cannot reach the state under test, and an
# assertion loose enough not to notice — found by sending the probe at the shim by hand.
#
# Only when -w is set and the key is absent. The asset probe uses -I WITHOUT -w and parses
# Content-Length from the head branch further down, which must keep working.
case "$url" in
  *.amazonaws.com/*)
    _rel="${url#*.amazonaws.com/}"; _hit=""
    [ -f "$FIXTURE_ROOT/$_rel" ] && _hit=1
    # An id the BUILD has and the BUCKET does not: a sync that never ran, or ran partway.
    # The read-back in step 5 is the only thing that looks for it.
    for _b in ${FAKE_BUCKET_MISSING:-}; do [ "$_rel" = "$_b.json" ] && _hit=""; done
    # An arbitrary status, so "the bucket has no document" and "the probe did not complete"
    # can be told apart — they have different remedies and this file refuses to conflate them.
    for _b in ${FAKE_BUCKET_HTTP:-}; do
      case "$_b" in
        "${_rel%.json}="*) if [ -n "$w" ]; then printf '%s' "${_b#*=}"; exit 0; fi ;;
      esac
    done
    for _b in ${FAKE_BUCKET_ONLY_IDS:-}; do [ "$_rel" = "$_b.json" ] && _hit=1; done
    for _b in ${FAKE_BUCKET_GARBLED:-}; do [ "$_rel" = "$_b.json" ] && _hit=1; done
    [ -n "$_hit" ] || { [ -z "$w" ] || { printf '404'; exit 0; }; }
    ;;
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
    force_fields "$FIXTURE_ROOT/collection.json" "${FAKE_LIVE_VERSION:-}" "${FAKE_LIVE_LICENCE:-}"
    exit 0 ;;
  */items/*)   # the live item read-back: the fixture's own JSON, or a stale one (case 6)
    f="$FIXTURE_ROOT/${url##*/}.json"
    # Stale ONE asset, the first (classified_2017.tif), and leave the largest correct: a
    # read-back that compares only the probe asset (the largest, a byte-stable gpkg) is
    # exactly the false pass this case exists to catch. No /g, deliberately.
    # Serve it as the API does: null-valued properties dropped (case 1 relies on the
    # read-back accepting that), then the requested staleness on top.
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["properties"]={k:v for k,v in d["properties"].items() if v is not None}; print(json.dumps(d))' "$f" \
    | case "${FAKE_LIVE_ITEM_STALE:-}" in
        asset) sed 's/"file:checksum": "1220/"file:checksum": "1220dead/' ;;
        property) sed 's/"datetime": "2023-01-01T00:00:00Z"/"datetime": "2022-01-01T00:00:00Z"/' ;;   # no byte changes
        provenance) sed 's/"properties": {/"properties": {"link:run_uid": "live-value", /' ;;   # live has a value the build does not
        *) cat ;;
      esac
    exit 0 ;;
esac
rel="${url#*.amazonaws.com/}"
f="$FIXTURE_ROOT/$rel"
# The bucket is NOT the build, and the retirement preflight turns on exactly that difference:
# an id absent from the API and still in the bucket was retired by an earlier run of this
# release, while an id in neither was never published at all. The fixture serves both surfaces
# out of one directory, so without this knob the second state is unrepresentable.
# A 200 carrying a body that is not JSON: an S3 SlowDown/error document, or a truncated
# transfer. The release's witness and item_retract_s3.sh's guard 4 must both treat that as
# "could not read" and refuse, NOT as "no such item" — they have different remedies, and one
# of them costs a new tag.
for _b in ${FAKE_BUCKET_GARBLED:-}; do
  if [ "$rel" = "$_b.json" ]; then
    printf '<?xml version="1.0"?><Error><Code>SlowDown</Code></Error>'
    exit 0
  fi
done
for _b in ${FAKE_BUCKET_ONLY_IDS:-}; do
  if [ "$rel" = "$_b.json" ]; then
    printf '{"type":"Feature","id":"%s","properties":{"wsg":"%s"},"assets":{}}' \
      "$_b" "$(printf '%s' "${_b%%_*}" | tr 'a-z' 'A-Z')"
    exit 0
  fi
done
[ -f "$f" ] || { echo "curl shim: no fixture for $url" >&2; exit 22; }
if [ -n "$head" ]; then
  printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$(wc -c < "$f" | tr -d ' ')"
elif [ "$rel" = collection.json ] && { [ -n "${FAKE_BUCKET_VERSION:-}" ] || [ -n "${FAKE_BUCKET_LICENCE:-}" ]; }; then
  force_fields "$f" "${FAKE_BUCKET_VERSION:-}" "${FAKE_BUCKET_LICENCE:-}"
elif [ -n "${FAKE_BUCKET_ITEM_SHAPE:-}" ] && [ "$rel" != collection.json ] && [ "${rel%.json}" != "$rel" ]; then
  # The bucket copy as some OTHER release left it. `nge` is a pre-#74 copy: the same values
  # under the retired names. `drop` removes one key, which is the shape an upstream re-run
  # produces — the build gains a field the published copy never had.
  # Only the item JSON, never an asset — step 5 probes asset bytes through this same branch
  # and a rewritten payload would fail the checksum instead of the shape arm.
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
if sys.argv[2] == "drop":
    d["properties"].pop("link:run_uid", None)
else:
    d["properties"] = {("nge:" + k.split(":", 1)[1] if ":" in k else k): v
                       for k, v in d["properties"].items()}
print(json.dumps(d))' "$f" "${FAKE_BUCKET_ITEM_SHAPE}"
else
  cat "$f"
fi
SHIM
chmod +x "$BIN"/aws "$BIN"/ssh "$BIN"/uv "$BIN"/curl

# --- runner ----------------------------------------------------------------------------
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
LIVE_AFTER=""
LIVE_FINAL=""
GONE=""
BUCKETONLY=""
BUCKETMISSING=""
BUCKETHTTP=""
GARBLED=""
STALE=""
LIVEV=""
BUCKETV=""
LIVELIC=""
BUCKETLIC=""
LIVEDEP=""
BUCKETSHAPE=""
RC=0
run_release() {
  : > "$LOG"; : > "$SSHIN"; rm -f "$WORK/search_count"
  set +e
  ( cd "$TREPO" && PATH="$BIN:$PATH" SHIM_LOG="$LOG" COUNTER="$WORK/search_count" \
      SSH_STDIN_LOG="$SSHIN" FIXTURE_ROOT="$STAC" \
      STAC_DIR="$STAC" RAW_DIR="$RAW" BUCKET="$BUCKET" COLLECTION="$COLL" \
      FAKE_LIVE_IDS="$LIVE" FAKE_LIVE_IDS_AFTER="$LIVE_AFTER" FAKE_LIVE_IDS_FINAL="$LIVE_FINAL" \
      FAKE_GONE_IDS="$GONE" FAKE_BUCKET_ONLY_IDS="$BUCKETONLY" FAKE_BUCKET_GARBLED="$GARBLED" \
      FAKE_BUCKET_MISSING="$BUCKETMISSING" FAKE_BUCKET_HTTP="$BUCKETHTTP" \
      FAKE_LIVE_ITEM_STALE="$STALE" \
      FAKE_LIVE_VERSION="$LIVEV" FAKE_BUCKET_VERSION="$BUCKETV" \
      FAKE_LIVE_LICENCE="$LIVELIC" FAKE_BUCKET_LICENCE="$BUCKETLIC" \
      FAKE_LIVE_DEPRECATED="$LIVEDEP" FAKE_BUCKET_ITEM_SHAPE="$BUCKETSHAPE" \
      bash "$RELEASE" "$@" ) > "$OUT" 2>&1 < /dev/null
  RC=$?
  set -e
}

# The fixture collection links its items, so a case that removes an item from the BUILD has to
# remove its link too — item_create.py would not have written one. Without this a case models a
# tree no build produces, and step 5's link/file equality arm refuses it on the fixture's own
# inconsistency rather than on whatever the case is about.
coll_unlink() { python3 -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["links"]=[l for l in d["links"] if not (l.get("rel")=="item" and sys.argv[2] in (l.get("href") or ""))]
json.dump(d,open(p,"w"))' "$STAC/collection.json" "$1"; }
coll_relink() { python3 -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p))
if not any(l.get("rel")=="item" and sys.argv[2] in (l.get("href") or "") for l in d["links"]):
    d["links"].insert(0,{"rel":"item","href":sys.argv[3]+"/"+sys.argv[2]+".json"})
json.dump(d,open(p,"w"))' "$STAC/collection.json" "$1" "$S3_BASE"; }

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
# The ORDER of the two JSON writes, as line numbers in the shim log. collection.json must be
# the last JSON object the bucket receives: a sync pass that put it up and then failed would
# leave it linking items that are not there, and rtj's reload-from-S3 DELETEs the collection
# before it discovers that. Nothing else in this harness asserts an ordering, so these two
# read line numbers rather than counts.
line_json_sweep() { awk -F'\t' '$1=="aws" && $3=="sync" { for (i=1;i<=NF;i++) if ($i=="--include" && $(i+1)=="*.json") print NR }' "$LOG" | tail -1; }
line_coll_cp()    { awk -F'\t' -v d="s3://$BUCKET/collection.json" '$1=="aws" && $3=="cp" && $5==d { print NR }' "$LOG" | tail -1; }
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
# --partial (#26) is the mirror of the floor: passed under --only, absent on a full release.
# Without it the deprecation check's whole-catalogue set compare refuses every group but the
# two marked ones, so #36's single-group path dies quietly. uv is shimmed, so this is proven
# from the argv log rather than from reading the script.
n_partial_flag() { awk -F'\t' '$1=="uv" { for (i=1;i<=NF;i++) if ($i=="--partial") n++ } END { print n+0 }' "$LOG"; }

# Every pgstac delete this run asked for, read from the SQL payload rather than the argv:
# item_unregister.sh interpolates the ids into `pgstac.delete_item('<id>', '<collection>')`
# and passes `psql -f -`, so the ids never appear on a command line at all.
# `|| n=0` on the assignment, not `|| true` inside the substitution: `grep -c` prints 0 and
# exits 1 when it matches nothing, and exits 2 printing nothing when the file is absent. A
# bare `|| true` leaves the absent case substituting the empty string, and `[ "" -eq 0 ]` is
# a syntax error inside refused() rather than a failing assertion.
n_delete()     { n=$(grep -c "pgstac.delete_item(" "$SSHIN" 2>/dev/null) || n=0; printf '%s\n' "$n"; }
deleted_ids()  { sed -n "s/.*pgstac\.delete_item('\([^']*\)'.*/\1/p" "$SSHIN" 2>/dev/null | sort -u; }
# The SECOND argument, which decides which collection the row is deleted from.
# item_unregister.sh defaults COLLECTION to the production collection and the release does not
# export it, so the whole scoping is one env assignment on the invocation line — and removing
# it left this suite fully green, because deleted_ids() throws the argument away. pgstac's
# one-arg delete_item is unscoped across every collection in that database.
deleted_colls() { sed -n "s/.*pgstac\.delete_item('[^']*', *'\([^']*\)'.*/\1/p" "$SSHIN" 2>/dev/null | sort -u; }

# "Touched nothing" has to mean the DESTRUCTIVE transport too, not only aws. The retirement
# step goes over ssh, so a refusal that fired after a delete had already landed would have
# satisfied the old two-term conjunction while 17 items were gone.
refused() { # desc — the last run must have exited non-zero having touched nothing
  if [ "$RC" -ne 0 ] && [ "$(n_aws)" -eq 0 ] && [ "$(n_delete)" -eq 0 ]; then pass "$1"
  else fail "$1 (rc=$RC, aws calls=$(n_aws), deletes=$(n_delete))"; fi
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
# The JSON sync writes the items first and collection.json last, as two calls. One sync over
# both parallelises them, so a partial failure can leave the bucket collection linking an
# object that was never uploaded.
expect_eq "the item sweep excludes collection.json" \
  "$(awk -F'\t' '$1=="aws" && $3=="sync" { for (i=1;i<=NF;i++) if ($i=="--exclude" && $(i+1)=="collection.json") print }' "$LOG" | grep -c . || true)" 1
expect_eq "one cp of collection.json on a FULL release" "$(n_cp "$STAC/collection.json" "s3://$BUCKET/collection.json")" 1
expect_eq "and it lands after the item sweep" \
  "$([ "$(line_coll_cp)" -gt "$(line_json_sweep)" ] && echo after)" after
expect_out "verify read the bucket copy back" "bucket collection.json version: $TVERSION — agrees"
expect_out "verify read the licence back from the API" "live collection licence: CC-BY-4.0, sci:citation and both links served as published"
expect_out "verify read the licence back from the bucket" "bucket collection.json licence: agrees"
expect_out "verify read the deprecation markers back" "deprecation markers served: bbbb_ch_ff04"
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
expect_eq "a full release does NOT pass --partial" "$(n_partial_flag)" 0
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

# 9k/9l are to the deprecation read-back what 8/9 are to the version gate. The shim echoes the
# built markers, so case 2's line above is tautological on its own — these are what prove the
# compare bites. Both directions, because losing a marker and inventing one are different
# failures: the first republishes a stale item looking current, the second stamps a permanent
# false "stale" claim on a correct one.
echo "case 9k: the API dropping a deprecation marker fails the release"
LIVEDEP=none
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "RELEASE INCOMPLETE" "RELEASE INCOMPLETE"
expect_out "names both sides" "the API serves deprecated on 'NONE' but this build marks 'bbbb_ch_ff04'"
LIVEDEP=""

echo "case 9l: the API marking an item this build does not fails the release"
LIVEDEP="aaaa_ch_ff04 bbbb_ch_ff04"
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the extra marker" "the API serves deprecated on 'aaaa_ch_ff04 bbbb_ch_ff04'"
LIVEDEP=""

# 9m covers the one line in the step-5 block that nothing else reaches: the intersection of
# the served marked-set with the build's ids. Deleting `served &= built_ids` leaves every other
# case green, because it only matters when an item is live-and-marked but absent from the
# build — which is exactly a retraction, and only --allow-retract permits one.
echo "case 9m: retracting a marked item does not falsely fail the release (--allow-retract)"
mv "$STAC/bbbb_ch_ff04.json" "$WORK/bbbb.json.bak"
coll_unlink bbbb_ch_ff04        # a build that dropped the item would not link it either
LIVEDEP="bbbb_ch_ff04"          # live still serves it marked; this build no longer has it
run_release --allow-retract
expect_eq "exit 0" "$RC" 0
expect_out "release completed" "RELEASE COMPLETE"
expect_out "the surviving marker set is the build's, not the API's" "deprecation markers served: NONE"
LIVEDEP=""
mv "$WORK/bbbb.json.bak" "$STAC/bbbb_ch_ff04.json"
coll_relink bbbb_ch_ff04

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
expect_eq "the validator WAS given --partial (#26: without it a one-group tree is refused)" "$(n_partial_flag)" 1
expect_out "preflight compared the item's live provenance (the control: nothing lost)" "provenance under --only: live item carries 1 value(s), this build carries 1."
# NOT a positive match on the preflight's own count line: `live: N | built: N` is printed by
# the release BEFORE the --only branch, so it appears in cases 15 and 16 too, where both arms
# refuse. The property this case is about is that NEITHER shape message was printed.
expect_eq "...and the bucket copy agreed on the key shape (neither shape message printed)" \
  "$(( $(grep -c 'FULL-release change' "$OUT" || true) + $(grep -c 'provenance gained since' "$OUT" || true) ))" 0
expect_out "verify probed the named item" "checksum probe (aaaa_ch_ff04)"
expect_out "verify read the live item back (a null property served as absent)" "pgstac serves the document just built — 2 assets, 4 properties"
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
# Live serves landcover:key AND link:run_uid; the build has landcover:key and a null
# link:run_uid. Counts are 2 vs 1 — a total-loss check (build == 0) would pass this; the
# per-field check must not.
STALE=provenance
run_release --only aaaa_ch_ff04;                    refused "a partial provenance loss is refused before any write"
expect_out "counts show the partial shape" "live item carries 2 value(s), this build carries 1."
expect_out "names the lost field" "carries provenance this build does not: link_run_uid"
STALE=""

# --- case 16: the shape arm, which is what the rename needed (#74) ----------------------
echo "case 16: a bucket copy on a different provenance contract refuses --only"
# The API cannot answer this: it drops null properties, so a pre-#74 item that carried twelve
# nulls serves none of them and looks identical to a post-#74 item that omits them. The bucket
# copy keeps its nulls, and it is the document this release would overwrite.
BUCKETSHAPE=nge
run_release --only aaaa_ch_ff04;                    refused "a renamed provenance contract is refused under --only"
expect_out "names it as a full-release change" "A renamed or re-shaped provenance contract is a FULL-release change"
expect_out "names the keys the bucket has and the build does not" "publishes provenance key(s) this build does not: nge:key,nge:run_uid"
BUCKETSHAPE=""

# --- case 17: the other direction is a GAIN, which --only exists to publish --------------
echo "case 17: a provenance key the bucket copy lacks is a gain, not a refusal"
# An area re-run upstream that now carries a field it did not before — the normal
# forward-only state, and the shape that will arrive when kotl/larl/sloc get a link run uid.
# Refusing it would break #36's single-group path for exactly the items it was built for.
BUCKETSHAPE=drop
run_release --only aaaa_ch_ff04
expect_eq "exit 0" "$RC" 0
expect_out "the gain is reported, not refused" "provenance gained since the bucket copy: link:run_uid"
expect_eq "and nothing is said about a renamed contract" "$(grep -c 'FULL-release change' "$OUT" || true)" 0
BUCKETSHAPE=""

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

# --- cases 20-22: retirement (#76) ------------------------------------------------------
# RETIRED_ITEMS is a literal inside the script, and the harness runs a COMMITTED, TAGGED copy
# of scripts/ — the release's own clean-tree and exact-tag gates refuse anything else. So a
# case that varies the literal has to rewrite it in that copy and re-tag, the way cases 11
# and 13 already do for NEWS.md and for a dirty tree.
set_retired() { # ids... -> rewrite the literal in the tagged copy, re-tag
  python3 - "$TREPO/scripts/catalogue_release.sh" "$*" <<'PY'
import re, sys
p, v = sys.argv[1], sys.argv[2]
s = open(p).read()
s2, n = re.subn(r'(?m)^RETIRED_ITEMS=.*$', 'RETIRED_ITEMS="%s"' % v, s, count=1)
assert n == 1, "no RETIRED_ITEMS literal to set"
open(p, "w").write(s2)
PY
  tgit commit -q --no-verify -am "retired: $*" >/dev/null && tgit tag -f "v$TVERSION" >/dev/null
}
# The NEWS arm reads the TAGGED copy, so a case naming ids must put them there too.
set_news() { # ids... -> a tagged NEWS.md whose top entry names them
  { printf '# fixture\n\n## v%s (2026-01-01)\n\n- fixture release\n' "$TVERSION"
    for i in "$@"; do printf -- '- retired `%s`\n' "$i"; done
  } > "$TREPO/NEWS.md"
  tgit commit -q --no-verify -am "news names the retired ids" >/dev/null && tgit tag -f "v$TVERSION" >/dev/null
}
reset_tree() { tgit tag -f "v$TVERSION" "$TSHA" >/dev/null; tgit reset -q --hard "$TSHA"; }

# Case 3f put the marker back and nothing took it off again. Every case below is a FULL
# release, and the interlock sits upstream of the whole preflight — so left in place it
# refuses each one before the arm under test is reached, and refused() would have passed on
# the strength of a message about partial staging. Exactly the "guard that fails toward pass"
# shape, arriving through the fixture rather than the code.
rm -f "$RAW/PARTIAL_STAGE"

echo "case 20: the literal is empty on main, and anchored so the harness can read it"
expect_eq "RETIRED_ITEMS is one bare empty literal in the real script" \
  "$(grep -c '^RETIRED_ITEMS=""$' "$REPO/scripts/catalogue_release.sh" || true)" 1

# Static, and an ENUMERATION rather than a case. Round 2 found the one `| sort` the LC_ALL=C
# sweep had missed — `build_wsgs`, feeding the `comm` in the arm that survives ALLOW_SKIPPED=1 —
# and no behavioural case can reach it: the fixture's group codes are ASCII and collate
# identically in every locale, and the measured direction is a spurious refusal rather than a
# bad publish. So the class is closed by walking it instead. Every pipe into `sort` in the
# release script must be collation-pinned, except the one that orders filenames for xargs,
# where the order is cosmetic and nothing compares the result.
echo "case 20-sorts: every id/group list compared in the release script is collation-pinned"
# PER OCCURRENCE, not per line. The first version of this guard was itself the mechanism it
# exists to close: `grep -n '| *sort'` missed `sort -u <<<"$x"` because there is no pipe, and
# the `grep -v 'LC_ALL=C sort'` filter dropped any whole LINE that also held a pinned sort —
# while being dead anyway, since `| *sort` cannot match `| LC_ALL=C sort`. Both holes measured.
unpinned=$(python3 - "$REPO/scripts/catalogue_release.sh" \
  "$REPO/scripts/item_retract_s3.sh" "$REPO/scripts/item_unregister.sh" <<'PYEOF'
import re, sys
# Comments stripped at " # ", which is this file's convention, and deliberately NOT at a bare
# "#": `${rel#*/}` and `${out##*$'\n'}` are parameter expansions, and cutting there would hide
# real code. A `sort` mentioned in prose is not an invocation.
bad = []
# Every script in the publish path, not just the release: a "no members" closure is only as
# wide as the files read, and item_unregister.sh is the one that performs the delete.
for path in sys.argv[1:]:
    for n, line in enumerate(open(path), 1):
        if line.lstrip().startswith("#"):
            continue
        code = line.split(" # ", 1)[0]
        if "xargs bash scripts/item_register.sh" in code:
            continue        # orders filenames for registration; nothing compares the result
        for m in re.finditer(r"\bsort\b", code):
            if code[max(0, m.start() - 10):m.start()].endswith("LC_ALL=C "):
                continue
            bad.append(f"{path.split('/')[-1]}:{n}: {code.strip()[:70]}")
print("\n".join(bad))
PYEOF
)
expect_eq "every sort invocation is collation-pinned" "$(printf '%s\n' "$unpinned" | grep -c . || true)" 0
[ -z "$unpinned" ] || printf '        | %s\n' "$unpinned"

echo "case 20-assertions: no expect_out pattern can be satisfied by another arm's message"
# The fourth mechanism, and the only one whose instances live in THIS file: an assertion loose
# enough that a different code path satisfies it. It has bitten three times — case 21a's
# "the retirement is reported" matched any of seventeen messages containing RETIRED_ITEMS; case
# 20c's "was never published" was printed by the could-not-read arm it was NOT testing; case
# 20d's phrase appeared in that same arm's prose. Each time the case went on passing.
#
# So it is self-policed: every expect_out pattern is matched against every message the two
# scripts emit, and a pattern reachable from more than one is a defect here rather than a
# judgement call. The allowlist carries a reason per entry; it is not a place to park a
# failure.
ambig=$(python3 - "$0" "$REPO/scripts/catalogue_release.sh" "$REPO/scripts/item_retract_s3.sh" \
  "$REPO/scripts/item_unregister.sh" <<'PYEOF'
import re, sys
check, scripts = sys.argv[1], sys.argv[2:]
# Shared on purpose, with the reason:
allow = {
    # the --only and full-release completion lines are two spellings of one outcome
    "RELEASE COMPLETE",
    # the two bucket witnesses are deliberately identical, and no case drives both scripts
    "not a STAC Item with that id",
    # "full release" appears in three remedies; the case asserting it drives --only, where
    # none of the other two can fire
    "full release",
    # two spellings of one outcome: the step-7 retirement failure and the general fail gate
    # both mean "the release did not complete". Six cases assert it, and each pairs it with
    # something specific to its own arm (a named message, n_delete, or the step-6 banner's
    # absence), so the shared phrase is never the only evidence
    "RELEASE INCOMPLETE",
}
pats = set(re.findall(r'expect_out\s+"[^"]*"\s+"([^"]*)"', open(check).read()))
msgs = []
for path in scripts:
    for n, line in enumerate(open(path), 1):
        ls = line.strip()
        if ls.startswith("#"):
            continue
        # ANYWHERE in the line, and printf too. Matching only lines that START with `echo `
        # left 72 of 227 emitting lines invisible — every `|| { echo … }` and `*) echo …;;`
        # site, which is where the refusals live. Measured: a pattern shared by five
        # `|| { echo }` sites went unflagged while the class was called closed.
        if re.search(r"\b(echo|printf)\b", ls):
            msgs.append((path.split("/")[-1], n, line))
bad = []
# LITERAL matching, and the limit is stated rather than papered over.
#
# This catches one thing precisely: two emitted messages that share a pattern VERBATIM. It
# found four of those and they were real. It cannot do more, and the attempt is instructive —
# most messages are assembled from a literal plus expansions, so a pattern reading
# "the bucket answers 404 for" appears in no source line at all, the line being
# "the bucket answers $code for". 40 of 77 patterns are invisible to it for that reason.
#
# A variable-aware version was measured and rejected. Templating the pattern still missed
# every case where the LITERAL is in the pattern and the VARIABLE in the code
# (`version is '8.8.8'` against `version is '$live_version'`), and longest-common-substring
# matching trades one error for the other: at thresholds 8 to 20 it reports 29 to 61 of 73
# patterns ambiguous — nearly all falsely, because sibling messages share long runs — while
# still leaving 6 to 13 blind. An allowlist of forty-five entries is not a guard.
#
# The reason it cannot work is worth keeping: this scanner reads source TEMPLATES while the
# suite asserts on RENDERED output. Those are two artefacts that must agree with nothing
# joining them — the first mechanism in findings.md — so the instrument built to close that
# mechanism is an instance of it, one level up.
#
# **Class D's terminator is the mutation table, not this case.** Disabling an arm and watching
# its case go red is exactly the question "can this assertion be satisfied by something else",
# answered on rendered output by running the thing. Every arm this branch adds has a row.
# This case stays because a verbatim duplicate is cheap to catch and did happen four times;
# BLIND_FLOOR records how much it does NOT cover, as a number a human sets, so the gap is
# auditable instead of implied.
blind = []
for p_ in sorted(pats):
    if p_ in allow:
        continue
    hits = sorted({f"{f}:{n}" for f, n, l in msgs if p_ in l})
    if len(hits) > 1:
        bad.append(f"{p_!r} reachable from {len(hits)}: {' '.join(hits[:4])}")
    elif not hits:
        blind.append(p_)
BLIND_FLOOR = 42     # re-taken 2026-10-15 after cases 20p/20q; may shrink, must not grow unnoticed
if len(blind) > BLIND_FLOOR:
    bad.append(f"{len(blind)} pattern(s) invisible to this scanner (floor {BLIND_FLOOR}) — "
               f"raise it deliberately or assert on something literal: "
               + " ".join(repr(b) for b in blind[:6]))
print("\n".join(bad))
PYEOF
)
expect_eq "every expect_out pattern is unique to the arm it tests" "$(printf '%s\n' "$ambig" | grep -c . || true)" 0
[ -z "$ambig" ] || printf '        | %s\n' "$ambig"

echo "case 20-pipes: no early-exiting consumer sits downstream of a pipe"
# The third mechanism, closed the same way as the collation one: by having no members, checked
# mechanically. `grep -q`, `grep -m` and `head -1` all stop reading at their answer, and under
# `set -o pipefail` the writer's SIGPIPE then becomes the pipeline's status — so the test
# reports the writer's death as its own verdict once the text passes the pipe buffer (64 KiB,
# measured on this machine). A here-string has no writer to kill. No fixture can reach this:
# the harness payloads are hundreds of bytes, and NEWS.md is 39,573 B against that 64 KiB.
piped=$(python3 - "$REPO/scripts/catalogue_release.sh" "$REPO/scripts/item_retract_s3.sh" \
  "$REPO/scripts/item_unregister.sh" <<'PYEOF'
import re, sys
bad = []
for path in sys.argv[1:]:
    for n, line in enumerate(open(path), 1):
        if line.lstrip().startswith("#"):
            continue
        code = line.split(" # ", 1)[0]
        # Widened: the first pattern caught `| grep -q` and `| head -1` and missed
        # `| grep -E -q`, `| grep --quiet`, `| grep -F -m 1`, `| grep --max-count=1`,
        # bare `| head`, `| head -2`, `| sed 1q` and `| awk 'NR==1{...exit}'` — eight of
        # fifteen shapes, all measured. Zero members today either way; the point is reach.
        if re.search(r"\|\s*grep\b[^|]*(\s-[a-zA-Z]*[qm]\b|--quiet|--max-count)", code) \
           or re.search(r"\|\s*head\b", code) \
           or re.search(r"\|\s*sed\b[^|]*\b[0-9]+q\b", code) \
           or re.search(r"\|\s*awk\b[^|]*\bexit\b", code):
            bad.append(f"{path.split('/')[-1]}:{n}: {code.strip()[:70]}")
print("\n".join(bad))
PYEOF
)
expect_eq "every early-exiting consumer reads a here-string" "$(printf '%s\n' "$piped" | grep -c . || true)" 0
[ -z "$piped" ] || printf '        | %s\n' "$piped"

echo "case 20a: an orphan with an empty literal is refused, and the message names the literal"
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
run_release;                                        refused "orphan, empty literal"
expect_out "names the literal" "not named in RETIRED_ITEMS"

echo "case 20b: an orphan OUTSIDE the literal is refused, naming the one not accounted for"
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04 aaaa_st_ff04"
set_retired aaaa_co_ff04; set_news aaaa_co_ff04
run_release;                                        refused "unaccounted orphan"
# The containment arm's OWN heading, not the id. Both it and the generic "these are LIVE but
# absent from this build" listing above print the id, so asserting the id passed even with the
# containment message deleted — proven by deleting it and watching 20a go red while 20b stayed
# green. The id is still asserted, but under the heading that identifies the arm.
expect_out "the containment arm is what refused" "not named in RETIRED_ITEMS:"
expect_eq "and it listed the unaccounted id under that heading" \
  "$(awk '/not named in RETIRED_ITEMS:/{f=1;next} f&&/aaaa_st_ff04/{print "yes";exit}' "$OUT")" yes
reset_tree

echo "case 20c: a literal id that was never published is refused"
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
set_retired zzzz_ch_ff04; set_news zzzz_ch_ff04
run_release;                                        refused "literal names a never-published id"
expect_out "says it was never published" "names an item that was never published"
expect_out "and names the status the bucket gave" "the bucket answers 404"
expect_eq "and it is NOT the could-not-read arm" \
  "$(grep -c 'Could not read' "$OUT" || true)" 0
reset_tree

echo "case 20d: a literal id gone from the API but still in the bucket is REPORTED, not refused"
# The re-run after a verify failure. The delete already landed, so the id is not live; the
# bucket copy is still there, because the S3 step is separate and later. Refusing here would
# make a single verify failure cost a new commit, a new NEWS entry and a new tag.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
BUCKETONLY="aaaa_co_ff04"
GONE="aaaa_co_ff04"        # it is gone from the API; step 7 confirms that rather than assuming it
set_retired aaaa_co_ff04; set_news aaaa_co_ff04
run_release
expect_eq "exit 0" "$RC" 0
expect_out "reports it as already retired" "already retired by an earlier run"
expect_eq "and deletes nothing a second time" "$(n_delete)" 0
expect_out "says there was nothing left to unregister" "already absent from the API"
BUCKETONLY=""; GONE=""
reset_tree

echo "case 20e: a literal id THIS BUILD also produces is refused"
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
set_retired bbbb_ch_ff04; set_news bbbb_ch_ff04
run_release;                                        refused "literal names a built id"
expect_out "says the build produces it" "THIS BUILD also produces"
reset_tree

echo "case 20f: a live watershed group no build item covers is refused"
# The arm that survives ALLOW_SKIPPED=1, which suppresses PARTIAL_STAGE entirely: a short
# build then looks full, and every other arm passes on a literal a human filled in honestly.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 cccc_ch_ff04"
set_retired cccc_ch_ff04; set_news cccc_ch_ff04
run_release;                                        refused "a group would be lost"
expect_out "names the group, not the id" "CCCC"
reset_tree

echo "case 20g: a literal id the tagged NEWS.md does not mention is refused"
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
set_retired aaaa_co_ff04            # NEWS left as the plain fixture entry
run_release;                                        refused "NEWS does not name the retired id"
expect_out "names the entry it is missing from" "does not mention"
reset_tree

echo "case 20w: a whitespace-only literal is empty in fact, so --only is not refused for it"
# The flag refusals tested `-n` on the RAW literal, which the normalisation's own rule forbids.
# `RETIRED_ITEMS="   "` retires nothing and was still enough to refuse --only, under a message
# about publishing a smaller collection. One-directional and safe; a false refusal all the same,
# pointing at a remedy that has nothing to do with the problem.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
set_retired "   "
run_release --only aaaa_ch_ff04
expect_eq "exit 0 — nothing is being retired" "$RC" 0
expect_eq "and it was not refused over the literal" \
  "$(grep -c 'RETIRED_ITEMS do not combine' "$OUT" || true)" 0
reset_tree

echo "case 20h: --only and a non-empty literal do not combine"
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
set_retired aaaa_co_ff04
run_release --only aaaa_ch_ff04;                    refused "--only with a non-empty literal"
expect_out "says they do not combine" "--only and a non-empty RETIRED_ITEMS"
reset_tree

echo "case 20i: a literal entry that is not an item id is refused"
# curl normalises dot segments, so `../collection.json` would HEAD the bucket's OWN
# collection.json, read 200, and be reported "already retired by an earlier run" — a release
# completing while announcing a retirement it never performed. Same shape guard $ONLY and
# item_unregister.sh already carry, applied before any id reaches a URL or a prefix.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
set_retired "../collection.json"
run_release;                                        refused "literal holds a path, not an id"
expect_out "says it is not an item id" "not an item id"
reset_tree

echo "case 20j: a literal naming a bucket object that is not a STAC Item is refused"
# The reachable form of the class case 20i's shape guard only half-closed. `collection` passes
# the charset guard, is absent from local_ids by construction (the build loop skips it), and
# `$S3_BASE/collection.json` of course answers — so a HEAD-based witness reported it "already
# retired by an earlier run" and the release completed announcing a retirement it never
# performed. The witness now reads the body and asks the document who it is.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
set_retired collection; set_news collection
run_release;                                        refused "literal names the collection document"
expect_out "says it is not an item of this collection" "not an item of this collection"
expect_out "and says what the bucket does hold there" "not a STAC Item with that id"
reset_tree

echo "case 20L: a bucket read that could not be completed is refused, not called 'never published'"
# The arm exists so a re-run after a verify failure stays possible, and its refusal costs a new
# commit, a new NEWS entry and a new tag. Conflating a timeout or an S3 error document with
# "this was never published" sends the operator to that price for a retry.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
GARBLED="aaaa_co_ff04"
set_retired aaaa_co_ff04; set_news aaaa_co_ff04
run_release;                                        refused "unreadable bucket copy"
# "Could not read" alone is printed by eight other arms of this script, several of them
# reachable in a preflight. The witness is the only one that prints its verdict.
expect_out "says it could not read it" "verdict '"
expect_eq "and does NOT claim it was never published" \
  "$(grep -c 'never published' "$OUT" || true)" 0
GARBLED=""
reset_tree

echo "case 20k: the NEWS arm matches the id delimited, not as a substring"
# `grep -qF "$id"` passed for any entry merely containing the text, so an entry naming only a
# LONGER id satisfied the requirement that this id be recorded. Deleting a public item id with
# no release note is the one direction a consumer has no way to discover.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
set_retired aaaa_co_ff04; set_news aaaa_co_ff04_v2    # a longer id, not this one
run_release;                                        refused "NEWS names only a longer id"
expect_out "names the entry it is missing from" "does not mention"
reset_tree

echo "case 20m: --skip-sync is refused on a build that ADDS an item"
# On a full release --skip-sync uploads collection.json and nothing else, so a build with a new
# item publishes a document linking objects that were never sent — and a reload-from-S3 deletes
# the collection's rows before discovering one 404s. It survives a FAILED release too, because
# the cp happens at step 2+3 and the nearest probe was at step 5.
LIVE="aaaa_ch_ff04"          # the build also holds bbbb_ch_ff04, so bbbb is being added
run_release --skip-sync;                            refused "--skip-sync with an added item"
expect_out "names the added id" "cannot publish a build that ADDS items"
expect_eq "and lists it under that heading" \
  "$(awk '/cannot publish a build that ADDS items/{f=1;next} f&&/bbbb_ch_ff04/{print "yes";exit}' "$OUT")" yes
expect_eq "and no collection.json was copied" \
  "$(n_cp "$STAC/collection.json" "s3://$BUCKET/collection.json")" 0

echo "case 20n: a collection linking a document the bucket does not hold fails the release"
# The read-back for the invariant the step-3 sync split rests on. Until it existed, that
# invariant was enforced by the ORDER of two statements and never checked: step 5 compared ids
# against the API and probed one asset of one item, and no bucket read touched a per-item key.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
BUCKETMISSING="bbbb_ch_ff04"
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the item with no document" "no document for item(s) this collection links"
expect_out "and the id is in that line" "bbbb_ch_ff04(404)"
expect_out "and says what a reload would do" "delete the collection"
BUCKETMISSING=""

echo "case 20p: a collection that links an item the build does not hold is refused"
# The link set and the file set must be the same set. They agree only because item_create.py
# writes both in one run, and nothing read that back — item_validate.py checks the item COUNT,
# never the links against the files. A link with no document behind it is what kills a
# reload-from-S3, so it is the pairing that has to be asserted, not either side alone.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
coll_relink dddd_ch_ff04        # linked, never built
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the disagreement" "links a different item set than this build holds"
expect_out "and names the id" "dddd_ch_ff04"
coll_unlink dddd_ch_ff04

echo "case 20q: a bucket probe that did not complete is not reported as a missing document"
# The same split the retirement witness makes, in the arm added in round 5. A 503 SlowDown is
# not "there is no document here", and saying so would print an alarming and false claim about
# a reload deleting the collection's rows.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
BUCKETHTTP="bbbb_ch_ff04=503"
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "says the read did not complete" "could not read the bucket document"
expect_eq "and does NOT claim the document is missing" \
  "$(grep -c 'has no document for item' "$OUT" || true)" 0
BUCKETHTTP=""

echo "case 21a: the positive control — the retirement runs, and deletes exactly its literal"
# Without this, every refusal above is a grep that has never been shown to match.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
LIVE_AFTER="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"   # post-register: the delete has not run yet
LIVE_FINAL="aaaa_ch_ff04 bbbb_ch_ff04"                # post-delete
GONE="aaaa_co_ff04"
set_retired aaaa_co_ff04; set_news aaaa_co_ff04
run_release
expect_eq "exit 0" "$RC" 0
expect_out "release completed" "RELEASE COMPLETE"
expect_eq "exactly one delete" "$(n_delete)" 1
expect_eq "and it is the retired id" "$(deleted_ids)" "aaaa_co_ff04"
expect_eq "scoped to THIS collection, not the production default" "$(deleted_colls)" "$COLL"
expect_out "step 6 actually ran" "=== 6: RETIRE ==="
expect_out "and so did step 7" "=== 7: VERIFY RETIREMENT ==="
LIVE_AFTER=""; LIVE_FINAL=""; GONE=""
reset_tree

echo "case 21b: a probe failing BEFORE the delete leaves nothing deleted"
# The delete sits after every arm that sets fail=1, so the bad day is a failed release with
# the catalogue untouched — not seventeen items gone and a release reporting INCOMPLETE.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
LIVE_AFTER="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
# A knob that bites a FULL release. The item read-back STALE drives runs only under --only,
# so using it here set fail=0, the delete went ahead, and the case passed its first two
# assertions while proving the opposite of what it is for. The licence read-back (case 9c)
# is a full-release arm and fires before step 6.
LIVELIC=license
set_retired aaaa_co_ff04; set_news aaaa_co_ff04
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "RELEASE INCOMPLETE" "RELEASE INCOMPLETE"
expect_eq "nothing was deleted" "$(n_delete)" 0
# The step 6 banner must be ABSENT. Re-grepping RELEASE INCOMPLETE here carried no information
# about step 6 at all — it restated the assertion two lines up.
expect_eq "step 6 was never reached" \
  "$(grep -c '=== 6: RETIRE ===' "$OUT" || true)" 0
LIVELIC=""; LIVE_AFTER=""
reset_tree

echo "case 21c: a delete that did not take fails the release"
# item_unregister.sh warns and exits 0 when it deletes nothing, and the release never parses
# its NOTICEs — so the post-delete read-back is the ONLY evidence the delete happened.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
LIVE_AFTER="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
LIVE_FINAL="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"   # still served after the delete
set_retired aaaa_co_ff04; set_news aaaa_co_ff04
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names what is still served" "STILL SERVED"
LIVE_AFTER=""; LIVE_FINAL=""
reset_tree

echo "case 21f: the per-id 404 probe catches what the membership arms cannot"
# Step 7 reads two different surfaces, and this is the one only the item endpoint can see.
# The search says the id is gone, so the still-served arm and the equality arm both PASS; the
# item endpoint still answers 200 for it. pgstac's search index and its item endpoint are not
# guaranteed to agree, and item_unregister.sh warns and exits 0 when it deletes nothing, so
# this probe is the only thing standing between that disagreement and RELEASE COMPLETE.
#
# It replaces an earlier shape that isolated the still-served arm by passing --allow-retract
# with a non-empty literal. That combination is now refused outright: the flag waives the
# containment, group-survival and equality arms, which is the opposite of what a retirement
# wants, so a test depending on it was testing a configuration the script must not accept.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
LIVE_AFTER="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
LIVE_FINAL="aaaa_ch_ff04 bbbb_ch_ff04"   # the search agrees the delete took...
GONE=""                                  # ...and the item endpoint does not
set_retired aaaa_co_ff04; set_news aaaa_co_ff04
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "the item endpoint still answers for it" "still answers 200 from the API"
expect_eq "the membership arms saw nothing wrong" \
  "$(grep -c 'RETIRED BUT STILL SERVED' "$OUT" || true)" 0
LIVE_AFTER=""; LIVE_FINAL=""
reset_tree

echo "case 21g: --allow-retract and a non-empty literal are refused"
# The most destructive configuration available here, reached by passing a flag that reads like
# extra caution: the literal performs the delete, and the flag turns off every arm that checks it.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 aaaa_co_ff04"
set_retired aaaa_co_ff04; set_news aaaa_co_ff04
run_release --allow-retract;                        refused "--allow-retract with a literal"
expect_out "says they do not combine" "--allow-retract and a non-empty RETIRED_ITEMS"
expect_out "says which arms the flag waives" "waives the containment"
reset_tree

echo "case 21d: an ordinary release with an empty literal deletes nothing"
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
run_release
expect_eq "exit 0" "$RC" 0
expect_out "release completed" "RELEASE COMPLETE"
expect_eq "no delete_item at all" "$(n_delete)" 0

echo "case 21e: --allow-retract still permits an orphan OUTSIDE the literal, and never deletes it"
# The other kind of retraction: a group leaving the catalogue with no replacement, which the
# group arm refuses by design. The flag is what distinguishes the two, and it grants no delete.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04 cccc_ch_ff04"
run_release --allow-retract
expect_eq "exit 0" "$RC" 0
expect_out "release completed" "RELEASE COMPLETE"
expect_eq "the remainder is not deleted" "$(n_delete)" 0

# --- case 22: the S3 half, which has no undo ---------------------------------------------
# Driven directly rather than through the release: it is deliberately NOT part of a release
# (a release that destroyed assets on a failure path would be the one direction with no
# rollback), so there is no release run that would reach it.
echo "case 22: item_retract_s3.sh refuses while anything still points at the item"
retract_s3() { # args... -> same shims, same log
  : > "$LOG"; : > "$SSHIN"; rm -f "$WORK/search_count"
  set +e
  ( cd "$TREPO" && PATH="$BIN:$PATH" SHIM_LOG="$LOG" COUNTER="$WORK/search_count" \
      SSH_STDIN_LOG="$SSHIN" FIXTURE_ROOT="$STAC" STAC_DIR="${RETRACT_STAC_DIR:-$STAC}" \
      BUCKET="$BUCKET" COLLECTION="$COLL" \
      FAKE_LIVE_IDS="$LIVE" FAKE_GONE_IDS="$GONE" FAKE_BUCKET_GARBLED="$GARBLED" \
      bash "$TREPO/scripts/item_retract_s3.sh" "$@" ) > "$OUT" 2>&1 < /dev/null
  RC=$?
  set -e
}
n_rm() { awk -F'\t' '$1=="aws" && $3=="rm"' "$LOG" | grep -c . || true; }
# The TARGET, read from the shim's argv log rather than from stdout: the aws shim logs and
# prints nothing, so a grep of the run's output could never see what was passed to it.
n_rm_of() { awk -F'\t' -v u="$1" '$1=="aws" && $3=="rm" && $4==u' "$LOG" | grep -c . || true; }

LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
GONE=""
retract_s3 --yes aaaa_ch_ff04
expect_eq "no --yes-less footgun: a live item is refused" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "says the API still serves it" "the API still answers"
expect_eq "and nothing was removed" "$(n_rm)" 0

echo "case 22a2: the irreversible script refuses to delete the collection document"
# `--yes collection` cleared all three original guards: the API 404s it, $linked holds item ids
# only, and the build cross-check caught it by accident AND is skipped when data/stac is absent
# — a release-only machine, which is the machine this script is for. The delete that followed
# was `aws s3 rm s3://<bucket>/collection.json`, on a bucket with no versioning.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
GONE="collection"
# NO data/stac, which is the condition that matters: the build cross-check is the only one of
# the original three that caught `collection`, and it is skipped exactly here. The bucket still
# serves collection.json, because the shim reads it from $STAC_DIR of the SHIM, not of the
# script under test.
mkdir -p "$WORK/nostac"
RETRACT_STAC_DIR="$WORK/nostac" retract_s3 --yes collection
expect_eq "refused with no local build to lean on" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "says it is not an Item with that id" "not a STAC Item with that id"
expect_eq "and nothing was removed" "$(n_rm)" 0
expect_eq "and it was guard 4, not the build cross-check" \
  "$(grep -c 'still produces it' "$OUT" || true)" 0
GONE=""

echo "case 22a3: a bucket read that did not complete refuses the delete too"
# The same three-outcome split the release's witness makes. On the irreversible script the
# stakes are the other way round: there is nothing to lose by refusing a retry, and no undo if
# a half-read body is taken for a match.
LIVE="aaaa_ch_ff04 bbbb_ch_ff04"
GONE="cccc_ch_ff04"
GARBLED="cccc_ch_ff04"
mkdir -p "$WORK/nostac"
RETRACT_STAC_DIR="$WORK/nostac" retract_s3 --yes cccc_ch_ff04
expect_eq "refused" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "says the read did not complete" "did not complete"
expect_eq "and nothing was removed" "$(n_rm)" 0
expect_eq "and it is not read as a wrong-identity document" \
  "$(grep -c 'not a STAC Item' "$OUT" || true)" 0
GARBLED=""; GONE=""

echo "case 22b: --yes is required at all"
GONE="cccc_ch_ff04"
retract_s3 cccc_ch_ff04
expect_eq "refused without --yes" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "says the delete is permanent" "Refusing without --yes"
expect_eq "nothing removed" "$(n_rm)" 0

echo "case 22c: an item the bucket collection.json still links is refused"
# The ordering hazard, and the reason this script exists as a separate step: rtj's
# reload-from-S3 DELETEs the collection before it discovers that a linked href 404s.
python3 -c 'import json,sys
p = sys.argv[1]; d = json.load(open(p))
d["links"].append({"rel": "item", "href": sys.argv[2] + "/cccc_ch_ff04.json"})   # removed again by 22e
json.dump(d, open(p, "w"))' "$STAC/collection.json" "$S3_BASE"
GONE="cccc_ch_ff04"
retract_s3 --yes cccc_ch_ff04
expect_eq "refused" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the collection link" "still links it"
expect_eq "nothing removed" "$(n_rm)" 0

echo "case 22d: an item this build still produces is refused"
# Guard 3 (the build cross-check) is only reachable while the bucket collection and the build
# DISAGREE — in any consistent state guard 2 fires first, because anything the build holds the
# collection links. That is worth knowing rather than working around: guard 3 exists for the
# half-published state an interrupted release leaves, and this is that state.
GONE="bbbb_ch_ff04"       # gone from the API, but $STAC still holds bbbb_ch_ff04.json
coll_unlink bbbb_ch_ff04  # ...and the published collection no longer links it, so guard 2 passes
retract_s3 --yes bbbb_ch_ff04
expect_eq "refused" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the build" "this build still produces it"
expect_eq "nothing removed" "$(n_rm)" 0
coll_relink bbbb_ch_ff04

echo "case 22e: the positive control — gone from the API, unlinked, unbuilt, so it goes"
python3 -c 'import json,sys
p = sys.argv[1]; d = json.load(open(p))
# Only the one 22c added. Stripping EVERY rel:item would leave the fixture collection
# linking nothing for any later full release, which is now a refusal.
d["links"] = [l for l in d["links"] if not (l.get("rel") == "item" and "cccc_ch_ff04" in (l.get("href") or ""))]
json.dump(d, open(p, "w"))' "$STAC/collection.json"
GONE="cccc_ch_ff04"
retract_s3 --yes cccc_ch_ff04
expect_eq "exit 0" "$RC" 0
expect_out "retracted" "retracted: cccc_ch_ff04"
expect_eq "both the prefix and the document" "$(n_rm)" 2
# The trailing slash matters: `aws s3 rm s3://b/cccc_ch_ff04 --recursive` would also sweep
# cccc_ch_ff04_something/ and every other key sharing the prefix, with no undo.
expect_eq "the prefix carries its trailing slash" "$(n_rm_of "s3://$BUCKET/cccc_ch_ff04/")" 1
expect_eq "and the document is removed by exact key" "$(n_rm_of "s3://$BUCKET/cccc_ch_ff04.json")" 1
GONE=""

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
