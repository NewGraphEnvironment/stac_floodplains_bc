#!/bin/bash
# catalogue_release.sh — publish the built catalogue: validate -> sync -> register -> verify.
#
# Usage:
#   bash scripts/catalogue_release.sh
#   bash scripts/catalogue_release.sh --allow-retract     # deliberate item removal
#   bash scripts/catalogue_release.sh --only bulk_co_ff04  # republish ONE item (pilot)
#   GEOSERV_HOST=root@1.2.3.4 bash scripts/catalogue_release.sh
#
# --only <item_id> republishes one existing item: its assets, its JSON, its pgstac row.
# It NEVER publishes collection.json — a partial build's collection describes only the
# groups in that build, and registering it would replace the live 20-group collection
# with a one-group one, with no rollback (bucket versioning is Suspended). The
# PARTIAL_STAGE interlock and the live-vs-build comparison guard exactly that document,
# so both are skipped under --only, out loud. The item must already be live: a new item
# needs the collection's extent/summaries/links updated, which only a full release does.
# Validation still covers the whole tree on disk, so with a full 20-item build present
# --only re-hashes ~670 MB of assets; correct, just slow. Proven by
# scripts/catalogue_release-check.sh, which runs this script against shims.
#
# Requires: data/stac (built by run_pipeline.sh), AWS credentials, SSH to geopro.
# Does NOT require $FLOODPLAINS_DATA — rebuild and publish are separate, so a
# release can be cut from any machine with creds and tailnet access, not only the
# one holding the 900 MB source tree.
#
# Idempotent: the sync skips unchanged objects and the register is an upsert.
#
# A full release IS a tag. Preflight refuses unless HEAD sits exactly on a vX.Y.Z tag,
# the tracked tree is clean, and NEWS.md's top entry names that version; it then stamps
# collection.json with the STAC Version Extension (scripts/collection_version.py) ahead
# of the validation gate, and step 5 fails the release unless the API serves that
# version back. --only never publishes the collection, so it never stamps, and verifies
# instead that the live version did not move.
set -euo pipefail

BUCKET="${BUCKET:-stac-floodplains-bc}"
COLLECTION="${COLLECTION:-stac-floodplains-bc}"
API_ROOT=https://images.a11s.one
API="$API_ROOT/collections/$COLLECTION"
STAC_DIR="${STAC_DIR:-data/stac}"
RAW_DIR="${RAW_DIR:-data/raw}"
HOST="${GEOSERV_HOST:-root@geopro}"
S3_BASE="https://$BUCKET.s3.us-west-2.amazonaws.com"   # the shape item_create.py emits

# The provenance floor (#32): EXACTLY how many items carry a non-null nge: value in the
# build a full release publishes. A LITERAL set by a human, on purpose. Deriving it from
# the build would reproduce #23 — an expectation that comes from the data cannot be
# contradicted by it — and an env override would be the escape hatch this exists not to
# have (the check harness reads this line with an anchored sed, so a `${...:-0}` fails it).
#
# Exact in both directions: below the literal is a reader that silently found nothing,
# which looks exactly like the forward-only state every presence check waves through;
# above it is a floor nobody updated. So every release records the count here, beside its
# NEWS entry, and the number to set is the one 01_stage.R prints as "N of M staged item(s)
# carry run provenance" and item_create.py as "provenance block: N/M". 0 was true of
# v1.0.0; any full rebuild from today's producer tree carries bulk_co_ff04, so the next
# full release sets 1 (or whatever its build prints) in the same commit as its NEWS entry.
PROVENANCE_FLOOR=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"

ALLOW_RETRACT=""
SKIP_SYNC=""
ONLY=""
usage() {
  echo "usage: $(basename "$0") [--allow-retract] [--skip-sync] [--only <item_id>]" >&2
  exit 1
}
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
    # Republish one item — see the header. The value is mandatory and must be non-empty:
    # an empty ONLY passes the shape check below, and every `[ -n "$ONLY" ]` branch then
    # selects the FULL release — the one damaging direction a typo could reach.
    --only)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || { echo "--only needs an item id" >&2; usage; }
      ONLY="$2"; shift ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
  shift
done
# The id reaches S3 keys and a pgstac upsert. Constrain it to the shape item_create.py emits, as
# item_unregister.sh does; a leading '-' is a flag that swallowed the id, not an id.
case "$ONLY" in
  -*|*[!A-Za-z0-9_-]*) echo "ERROR: suspicious item id: $ONLY" >&2; exit 1 ;;
esac
if [ -n "$ONLY" ] && [ -n "$ALLOW_RETRACT" ]; then
  echo "--only and --allow-retract do not combine: retraction publishes a smaller" >&2
  echo "COLLECTION, and --only never publishes the collection." >&2
  exit 1
fi

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

# The live collection's version, or the literal MISSING when it carries none. MISSING is
# a real state (the catalogue before its first versioned release), and a failed read must
# not look like it: curl -f and a parse that raises on a non-JSON body both fail the
# pipeline, and every caller tests the exit status before using the value.
version_of() { python3 -c "import sys,json; print(json.load(sys.stdin).get('version', 'MISSING'))"; }
fetch_live_version() { curl -sf --max-time 60 "$API" | version_of; }

# --- Step 0: preflight, before anything is written ------------------------
echo "=== 0: PREFLIGHT ==="

[ -d "$STAC_DIR" ] || { echo "No $STAC_DIR — run scripts/run_pipeline.sh first." >&2; exit 1; }
# Required under --only too, even though it is never published then: item_validate.py
# insists on exactly one collection document in the tree.
[ -f "$STAC_DIR/collection.json" ] || { echo "No $STAC_DIR/collection.json." >&2; exit 1; }

if [ -n "$ONLY" ]; then
  [ -f "$STAC_DIR/$ONLY.json" ] || { echo "No $STAC_DIR/$ONLY.json — $ONLY is not in this build." >&2; exit 1; }
  [ -d "$STAC_DIR/$ONLY" ] || { echo "No $STAC_DIR/$ONLY/ — $ONLY has no asset directory." >&2; exit 1; }
  echo "--only $ONLY: republishing ONE item. collection.json is not published."
fi

# The staging interlock. 01_stage.R drops this marker for WSG_ONLY *and* for any
# silently-skipped target, so it is the signal that this tree is not a full build.
if [ -e "$RAW_DIR/PARTIAL_STAGE" ]; then
  if [ -n "$ONLY" ]; then
    # What the marker protects is collection.json, which --only never publishes. A
    # one-group tree is the normal input here, so say so rather than silently pass.
    echo "PARTIAL_STAGE interlock: skipped under --only (marker: $(cat "$RAW_DIR/PARTIAL_STAGE"))."
  else
    echo "Refusing to publish: staging was partial ($(cat "$RAW_DIR/PARTIAL_STAGE"))." >&2
    echo "Re-run scripts/run_pipeline.sh for a full build." >&2
    exit 1
  fi
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

if [ -n "$ONLY" ]; then
  # Anchored, fixed-string, `--`: an id can never be read as a pattern or an option. A
  # never-published item needs the collection's extent/summaries/links updated, which only
  # a full release does. Passing this also makes live_ids provably non-empty, which is
  # what lets step 5 compare membership by plain string equality.
  if ! printf '%s\n' "$live_ids" | grep -qxF -- "$ONLY"; then
    echo "$ONLY is not live. --only republishes an EXISTING item; a new item needs a" >&2
    echo "full release, which updates the collection's extent, summaries and links." >&2
    exit 1
  fi
  echo "live-vs-build comparison: skipped under --only (this build may hold one group; nothing is retracted)."
  # The provenance floor cannot apply to a one-group tree, and --only is the release path
  # in use — so the guard here is the live item itself (#32 review): the API drops null
  # properties, so an nge: key PRESENT on the live item is a value. Any live value that
  # this build's copy publishes as null is provenance LOST between the record and the
  # build — a reader that found nothing, or one that found only some sections — and the
  # step-5 read-back accepts build-null / served-absent as "the same document", so it
  # would go through. Per key, not a total count: network found and landcover lost is the
  # realistic shape, and a count would pass it. Refuse before anything is written.
  only_prov=$(curl -sf --max-time 60 "$API/items/$ONLY" | python3 -c "
import json, sys
live = json.load(sys.stdin)
built = json.load(open('$STAC_DIR/$ONLY.json'))
lp, bp = live.get('properties', {}), built['properties']
n_live = sum(1 for k, v in lp.items() if k.startswith('nge:') and v is not None)
n_built = sum(1 for k, v in bp.items() if k.startswith('nge:') and v is not None)
# A live key ABSENT from the build is a contract rename (#40's kind of change), not a
# reader loss: still refused — a one-item republish under a renamed key would leave the
# other live items on the old one — but diagnosed as what it is.
lost = sorted(k for k, v in lp.items() if k.startswith('nge:') and v is not None and k in bp and bp[k] is None)
gone = sorted(k for k, v in lp.items() if k.startswith('nge:') and v is not None and k not in bp)
print(n_live, n_built, ','.join(lost), ','.join(gone))") || { echo "Could not read the live item's provenance — refusing to publish blind." >&2; exit 1; }
  read -r only_live_prov only_built_prov only_lost_prov only_gone_prov <<EOF
$only_prov
EOF
  echo "provenance under --only: live item carries $only_live_prov nge: value(s), this build carries $only_built_prov."
  if [ -n "$only_lost_prov" ]; then
    echo "The live $ONLY carries provenance that this build would publish as null: $only_lost_prov." >&2
    echo "A reader that found nothing, or only some sections, or a stage from a tree without the" >&2
    echo "producer's provenance.json. Refusing before anything is written." >&2
    exit 1
  fi
  if [ -n "$only_gone_prov" ]; then
    echo "The live $ONLY carries nge: key(s) this build does not declare at all: $only_gone_prov." >&2
    echo "A renamed provenance contract is a full-release change — republishing one item would leave" >&2
    echo "every other live item on the old key. Refusing." >&2
    exit 1
  fi
else
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
fi

# --- version: a full release is a tag --------------------------------------
# A version means "the published catalogue is in this state" (the NEWS.md convention),
# so it is written HERE, by the release, from the tag HEAD sits on — never by the build,
# which runs before the tag exists in every real flow and would stamp the previous one.
# Three gates, each refusing rather than guessing, and each branching on its command's
# exit status so a failing command cannot read as "nothing wrong": HEAD exactly at a
# tag; no tracked modification (the tag has to describe the scripts about to run); and
# NEWS.md's top entry naming the same version. Then collection.json is stamped — ahead
# of step 1, so the validator gates the stamped document, and after every refusal above,
# so a refused release leaves the build untouched.
VERSION=""
live_version_before=""
if [ -n "$ONLY" ]; then
  # Nothing to stamp: --only never publishes collection.json. Read the live version now;
  # step 5 asserts the release did not move it. MISSING before the first versioned
  # release is a legitimate value, and MISSING -> MISSING is "unchanged".
  live_version_before=$(fetch_live_version) \
    || { echo "Could not read the live collection version — refusing to publish blind." >&2; exit 1; }
  echo "version gate: skipped under --only (collection.json is not published; live version: $live_version_before)."
else
  # --match: without it, describe prefers ANY other tag on the commit (an annotated note
  # always wins over a lightweight release tag), and the gate would then refuse against
  # NEWS.md with a message blaming the wrong thing.
  if ! tag=$(git -C "$REPO" describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null); then
    echo "HEAD is not at a vX.Y.Z tag, and a full release IS a tag. Add the NEWS.md entry, then:" >&2
    echo "  git tag vX.Y.Z && bash scripts/catalogue_release.sh" >&2
    exit 1
  fi
  VERSION="${tag#v}"
  if ! dirty=$(git -C "$REPO" status --porcelain --untracked-files=no); then
    echo "Could not read git status in $REPO." >&2
    exit 1
  fi
  if [ -n "$dirty" ]; then
    echo "Tracked files differ from $tag — the tag must describe the scripts that run:" >&2
    printf '%s\n' "$dirty" | sed 's/^/  /' >&2
    exit 1
  fi
  # NEWS.md as the TAG holds it, not as the working tree does. The clean-tree gate above
  # hides untracked files by design, so a NEWS.md written and never added would pass a
  # read from disk while the tagged commit carries no entry at all — the ordinary
  # first-release mistake, and the pairing this gate exists to enforce. Captured whole
  # rather than piped into `grep -m1`: an early-exiting grep can SIGPIPE git show under
  # pipefail and turn a valid file into a false refusal.
  if ! news=$(git -C "$REPO" show "$tag:NEWS.md" 2>/dev/null); then
    echo "No NEWS.md in $tag — every release is described there first, in the tagged commit." >&2
    exit 1
  fi
  # The FIRST section heading, whatever it is: an "## Unreleased" above the version entry
  # is exactly the state this gate exists to refuse, and a grep for '^## v' would skip it.
  if ! news_top=$(printf '%s\n' "$news" | grep -m1 -E '^## '); then
    echo "NEWS.md in $tag has no '## ' heading — the release entry goes at the top." >&2
    exit 1
  fi
  case "$news_top" in
    "## v$VERSION"|"## v$VERSION "*) ;;
    *) echo "NEWS.md's top entry is '$news_top' but HEAD is tagged $tag — the top entry" >&2
       echo "must be '## v$VERSION (YYYY-MM-DD)'." >&2
       exit 1 ;;
  esac
  # Refuses anything that is not X.Y.Z, so a pre-release tag stops here. Then read the
  # file back: the stamp is the one write this release makes to the build, and the
  # validator below checks its shape, not its value.
  python3 scripts/collection_version.py "$STAC_DIR/collection.json" "$VERSION"
  stamped=$(version_of < "$STAC_DIR/collection.json")
  [ "$stamped" = "$VERSION" ] \
    || { echo "collection.json reads back version '$stamped' after stamping $VERSION" >&2; exit 1; }
  echo "release v$VERSION: HEAD at $tag, tree clean, NEWS.md agrees, collection.json stamped"
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
#
# On a full release the collection validated here is the STAMPED one, so the Version
# Extension's schema is checked before anything is published.
#
# --expect-provenance: the floor above, on a full release only. --only republishes one
# item from a tree that may hold one group, which cannot meet a full-tree floor; the
# preflight above refused already if that item would lose the provenance it has live.
if [ -n "$ONLY" ]; then
  echo "provenance floor: skipped under --only (a one-group tree cannot meet a full-tree floor; preflight compared the item's live provenance instead)."
  uv run python scripts/item_validate.py --base "$STAC_DIR" --expect "$n_local"
else
  uv run python scripts/item_validate.py --base "$STAC_DIR" --expect "$n_local" \
    --expect-provenance "$PROVENANCE_FLOOR"
fi

# --- Step 2: sync assets ---------------------------------------------------
if [ -n "$SKIP_SYNC" ]; then
  echo ""
  echo "=== 2+3: SYNC SKIPPED (--skip-sync) ==="
  echo "Assets and JSON on S3 are assumed current; registering from local files."
  if [ -z "$ONLY" ]; then
    # The one document a full release always changes is the collection, which preflight
    # just stamped. Registering it without syncing it would leave the bucket copy
    # unversioned, and rtj's reload-from-S3 would then silently revert the version the
    # API serves. One object, so keeping bucket and API in agreement costs nothing.
    aws s3 cp "$STAC_DIR/collection.json" "s3://$BUCKET/collection.json"
  fi
elif [ -n "$ONLY" ]; then

echo ""
echo "=== 2: SYNC ASSETS ($ONLY) ==="
# Same excludes and the same no --delete / no --size-only reasoning as the full path
# below; the source root is the item's own directory, so nothing outside it can be seen.
aws s3 sync "$STAC_DIR/$ONLY" "s3://$BUCKET/$ONLY" \
  --exclude '.*' --exclude '*/.*' --exclude '*.json' --exclude '*.aux.xml'

echo ""
echo "=== 3: SYNC JSON ($ONLY) ==="
# ONE explicit object, never the sync form used in the full path. That form —
# `--exclude '*' --include '*.json' --exclude '*/*'` — sweeps every root-level JSON,
# collection.json included, and a partial build's collection.json describes only the
# groups in the build. This line is the whole reason --only is safe; it is the one
# thing catalogue_release-check.sh exists to pin.
aws s3 cp "$STAC_DIR/$ONLY.json" "s3://$BUCKET/$ONLY.json"

else

echo ""
echo "=== 2: SYNC ASSETS ==="
# Exclude dotfiles at the root AND nested (macOS drops .DS_Store into item dirs);
# exclude *.json so the item/collection docs go in step 3, after their assets, and
# so no per-item sidecar reaches the bucket. (terra used to leave 68 .tif.aux.json
# files here; #34 retired it, but the exclusion still matters — see the *.aux.xml note.)
#
# No --size-only: a re-run after fixing an upstream number must re-upload even if
# the compressed size matches (LCHL's floodplain.gpkg is byte-identical in size to
# its S3 copy). No --delete: data/stac is wiped and rebuilt every run, so --delete
# would turn any short build into irreversible asset loss — versioning is Suspended.
# '*.aux.xml' matches none of the other excludes, and GDAL writes PAM sidecars whenever
# a read triggers statistics computation. None exists today, but the pipeline now makes
# two extra GDAL passes over these files, so exclude it rather than rely on that.
aws s3 sync "$STAC_DIR" "s3://$BUCKET" \
  --exclude '.*' --exclude '*/.*' --exclude '*.json' --exclude '*.aux.xml'

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
if [ -n "$ONLY" ]; then
  # No collection_register.sh here, deliberately: the collection row already exists (the
  # item is live), and the local collection.json may describe a one-group build.
  bash scripts/item_register.sh "$STAC_DIR/$ONLY.json"
else
# Collection first: pgstac items reference the collection row.
bash scripts/collection_register.sh "$STAC_DIR/collection.json"
# shellcheck disable=SC2046 — ids are validated basenames, no spaces
find "$STAC_DIR" -maxdepth 1 -name '*.json' ! -name collection.json \
  | sort | xargs bash scripts/item_register.sh
fi

# --- Step 5: verify --------------------------------------------------------
echo ""
echo "=== 5: VERIFY ==="
code=$(curl -s -o /dev/null -w '%{http_code}' "$API")
[ "$code" = "200" ] || { echo "Collection endpoint returned $code" >&2; exit 1; }

after_ids=$(fetch_live_ids)
fail=0

if [ -n "$ONLY" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "$API/items/$ONLY")
  [ "$code" = "200" ] || { echo "Item endpoint returned $code for $ONLY" >&2; fail=1; }
  # A republish adds nothing and loses nothing, so membership must be byte-identical to
  # the preflight read (both sorted by fetch_live_ids). Plain string compare, not the
  # `comm ... || true` shape below: that swallows a comm failure toward "no difference".
  # comm is only used to print the diff once the compare has already failed.
  if [ "$after_ids" != "$live_ids" ]; then
    echo "collection membership CHANGED during an --only release (before -> after):" >&2
    comm -3 <(printf '%s\n' "$live_ids") <(printf '%s\n' "$after_ids") | sed 's/^/  /' >&2 || true
    fail=1
  fi
  probe_item="$ONLY"
else
missing=$(comm -23 <(printf '%s\n' "$local_ids") <(printf '%s\n' "$after_ids") || true)
extra=$(comm -13 <(printf '%s\n' "$local_ids") <(printf '%s\n' "$after_ids") || true)
if [ -n "$missing" ]; then echo "NOT REGISTERED:"; printf '  %s\n' $missing; fail=1; fi
if [ -n "$extra" ] && [ -z "$ALLOW_RETRACT" ]; then
  echo "LIVE BUT NOT IN THIS BUILD:"; printf '  %s\n' $extra
  echo "  drop with: scripts/item_unregister.sh $(printf '%s ' $extra)"
  fail=1
fi
probe_item=$(printf '%s\n' "$local_ids" | head -1)
fi

# Asset probe: catches "the JSON is live but its COG never uploaded", which no amount
# of id comparison can see. Probing the LARGEST local asset and comparing
# Content-Length to the local byte count, not just asking for a 200 — a 200 alone is
# meaningless here, since the alphabetically-first asset exists from every prior
# release and would answer 200 even if step 2 uploaded nothing at all.
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

# Under --only, also prove the pgstac ROW is the one just built. A 200 from the item
# endpoint is as meaningless as a 200 from an old asset — the row was live before this
# release too. Read the live item and compare its assets and properties with the build's
# wholesale. Not checksums alone: the largest asset is an upstream gpkg copied verbatim,
# so a COG-only republish leaves its checksum identical; and labels, provenance and the
# loss/gain figures change with no byte changing at all. pgstac returns the document as
# written (measured: datetime strings round-trip in the builder's own mixed Z / +00:00
# forms) except for null-valued properties, which it omits — see below. A failed fetch
# or an unparseable body leaves live_state empty, which fails the compare rather than
# skipping it.
if [ -n "$ONLY" ]; then
  live_state=$(curl -sf --max-time 60 "$API/items/$ONLY" | python3 -c "
import json, sys
live = json.load(sys.stdin)
built = json.load(open('$STAC_DIR/$ONLY.json'))
bad = []
for name in sorted(set(built['assets']) | set(live.get('assets', {}))):
    if built['assets'].get(name) != live.get('assets', {}).get(name):
        bad.append('asset:' + name)
lp, bp = live.get('properties', {}), built['properties']
for k in sorted(set(bp) | set(lp)):
    # A null the build publishes comes back ABSENT: pgstac stores the key (measured on
    # the row: jsonb null) and the API drops it on output. That pair is the same
    # document; a null against a value, or a value against absence, is not.
    if bp.get(k) is None and k not in lp:
        continue
    if bp.get(k, '<absent>') != lp.get(k, '<absent>'):
        bad.append('property:' + k)
if not built['assets'] or not bp: print('EMPTY BUILD')
elif bad: print('STALE ' + ' '.join(bad))
else: print('OK %d assets, %d properties' % (len(built['assets']), len(bp)))") || live_state=""
  case "$live_state" in
    "OK "*) echo "live item ($ONLY): pgstac serves the document just built — ${live_state#OK }" ;;
    *) echo "  the live item is not the document just built: ${live_state:-read-back failed}" >&2
       fail=1 ;;
  esac
fi

# The version the API serves is the release's claim about itself, and the whole reason
# a version exists is that a consumer can trust that claim. Read it back rather than
# assume the register carried it. A failed read fails the release outright — it must
# not fall through to a comparison against an empty string that happens to match.
live_version=$(fetch_live_version) \
  || { echo "  could not read the live collection version after registration" >&2; live_version="<read failed>"; fail=1; }
if [ -n "$ONLY" ]; then
  if [ "$live_version" = "$live_version_before" ]; then
    echo "live collection version: $live_version (unchanged by --only, as required)"
  else
    echo "  live collection version CHANGED during an --only release: $live_version_before -> $live_version" >&2
    fail=1
  fi
elif [ "$live_version" = "$VERSION" ]; then
  echo "live collection version: $live_version — matches the tag just released"
else
  echo "  live collection version is '$live_version', but this release is v$VERSION" >&2
  fail=1
fi
# The bucket copy must carry the same stamp. rtj's stac_register-all.sh can reload this
# collection FROM S3, and that is harmless only while bucket and API agree — a stamp that
# reached pgstac but not the bucket would be reverted by that reload, silently.
if [ -z "$ONLY" ]; then
  bucket_version=$(curl -sf --max-time 60 "$S3_BASE/collection.json" | version_of) \
    || { echo "  could not read collection.json from the bucket" >&2; bucket_version="<read failed>"; fail=1; }
  if [ "$bucket_version" = "$VERSION" ]; then
    echo "bucket collection.json version: $bucket_version — agrees"
  else
    echo "  bucket collection.json version is '$bucket_version', but this release is v$VERSION" >&2
    fail=1
  fi
fi

[ "$fail" -eq 0 ] || { echo "RELEASE INCOMPLETE" >&2; exit 1; }
echo ""
if [ -n "$ONLY" ]; then
  echo "RELEASE COMPLETE — $ONLY republished; collection unchanged at $(printf '%s\n' "$after_ids" | grep -c .) items, version $live_version, $API"
else
  echo "RELEASE COMPLETE — v$VERSION: $(printf '%s\n' "$after_ids" | grep -c .) items live at $API"
fi
