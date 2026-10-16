#!/bin/bash
# catalogue_release.sh — publish the built catalogue: validate -> sync -> register -> verify.
#
# Usage:
#   bash scripts/catalogue_release.sh
#   bash scripts/catalogue_release.sh --allow-retract     # deliberate item removal
#   bash scripts/catalogue_release.sh --only bulk_all_ff04 # republish ONE item (pilot)
#   GEOSERV_HOST=root@1.2.3.4 bash scripts/catalogue_release.sh
#
# --only <item_id> republishes one existing item: its assets, its JSON, its pgstac row.
# It NEVER publishes collection.json — a partial build's collection describes only the
# groups in that build, and registering it would replace the live 23-group collection
# with a one-group one, with no rollback (bucket versioning is Suspended). The
# PARTIAL_STAGE interlock and the live-vs-build comparison guard exactly that document,
# so both are skipped under --only, out loud. The item must already be live: a new item
# needs the collection's extent/summaries/links updated, which only a full release does.
# Validation still covers the whole tree on disk, so with a full 23-item build present
# --only re-hashes that item's assets; correct, just slow. Proven by
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

# The provenance floor (#32): EXACTLY how many items carry provenance at all in the
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
# v1.0.0; a full rebuild from today's producer tree carries bulk_all_ff04 and no longer
# stages bulk_co_ff04 at all (floodplains#125 retired the targets: blocks), so the next
# full release sets whatever its build prints in the same commit as its NEWS entry.
# 23 of 23, measured on the build this release publishes (v2.0.0, #89): every rostered group
# carries a provenance record now. Exact in both directions, so this is the count and not a
# lower bound. It was 21 of 23 at v1.1.0 — mcgr and pine carried none — and both gained one
# when the whole-network runs produced them.
PROVENANCE_FLOOR=23

# What this release RETIRES (#76): the exact live item ids it removes from the catalogue.
# A LITERAL set by a human, the same shape and for the same reasons as PROVENANCE_FLOOR
# above — no env override, and the check harness reads this line with an anchored sed, so it
# has to stay one bare assignment. EMPTY is the normal state; a non-empty literal shipped on
# main is itself a failure, which catalogue_release-check.sh asserts.
#
# It exists because `--allow-retract` PERMITS publishing past a live item absent from the
# build and never removes one: step 5 tolerated the leftover under the flag, so
# RELEASE COMPLETE printed with the retired items still live. For floodplains#125 that is a
# group serving two floodplains built on different networks and, after floodplains#117,
# different DEM grids, with nothing in the items saying which is current. Naming the ids here
# is what lets the release do the removal itself, in band, so it cannot be half-done.
#
# The two flags are not interchangeable. This literal is for a REPLACEMENT — a group whose
# item id changes — and the arms below refuse unless the group survives in the build.
# `--allow-retract` is for a REMOVAL, a group leaving the catalogue with nothing taking its
# place, and it grants no delete.
# Last used at v2.0.0 (#89), the whole-network cutover: 23 ids over 22 groups, each
# replaced by its group's <wsg>_all_ff04, MORR being the two-for-one case this mechanism
# was built for. NEWS.md under v2.0.0 names them; cleared here in the commit after that
# release. Clearing is NOT optional once item_retract_s3.sh has run: the already-retired
# arm below tells a just-retired id from a typo by the BUCKET copy, and the S3 retract
# deletes exactly that witness — so a literal left set would refuse the NEXT release with
# "names an item that was never published", at the price of a new commit, NEWS entry and tag.
RETIRED_ITEMS=""

# The licence the collection must be SERVING when the release finishes (#47). A third
# copy of item_create.py's COLLECTION_LICENSE and item_validate.py's EXPECTED_LICENSE, and
# deliberately so: those two check the bytes on disk, this one checks what a consumer is
# actually handed. They can disagree, which is the entire point of step 5 reading it back.
EXPECT_LICENSE="CC-BY-4.0"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

ALLOW_RETRACT=""
# Normalised at top level, not only inside the full-release branch that fills them: `set -u`
# is on, and steps 6 and 7 below sit outside that branch, so an --only run would die on an
# unbound variable rather than skip a retirement it has already refused to have.
# Normalised HERE, above the flag refusals below, not down in the preflight where it used to
# sit. Those refusals tested `-n` on the RAW literal — which the rule on this very block
# forbids, and which a literal of only whitespace makes wrong: empty in fact, non-empty to
# `-n`. So --only was refused for a retirement that was not happening, under a message about
# publishing a smaller collection. One-directional (it cannot let a retirement through) and
# still a false refusal pointing at the wrong remedy.
#
# `grep -c .` over the normalised form is the only honest emptiness test for this literal.
retired_ids=$(printf '%s\n' $RETIRED_ITEMS | grep . | LC_ALL=C sort -u || true)
n_retired=$(printf '%s\n' "$retired_ids" | grep -c . || true)   # prints 0 and exits 1 when empty

# The shape guard $ONLY gets below and item_unregister.sh gets before its SQL. Without it these
# ids reach a URL and an `aws s3 rm` prefix unvalidated, and the failure is not a syntax error:
# curl normalises dot segments, so an entry of `../collection.json` HEADs the bucket's own
# collection document, reads 200, and is reported "already retired by an earlier run" — a
# release that completes announcing a retirement it never performed. Checked before anything
# reads one.
for id in $retired_ids; do
  case "$id" in
    -*|*[!A-Za-z0-9_-]*)
      echo "ERROR: RETIRED_ITEMS holds something that is not an item id: $id" >&2
      exit 1 ;;
  esac
done
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
# Refused rather than reported, and refused HERE, because every retirement arm below lives in
# the full-release branch of the preflight. Under --only none of them runs: an operator who
# sets the literal and then reaches for --only for an unrelated pilot would get no delete, no
# refusal and no mention of it, and the literal would still be sitting there for whoever cuts
# the next release. A "skipped under --only" line would be the other option and is worse — it
# teaches the operator that the combination is a supported no-op.
if [ -n "$ONLY" ] && [ "$n_retired" -gt 0 ]; then
  echo "--only and a non-empty RETIRED_ITEMS do not combine: a retirement publishes a" >&2
  echo "smaller COLLECTION, and --only never publishes the collection. Clear the literal" >&2
  echo "or cut a full release." >&2
  exit 1
fi
# ...and neither do these two, which is the less obvious one. `--allow-retract` waives exactly
# the arms a retirement depends on: the containment arm, the step-5 surplus arm, step 7's
# equality arm, and the "no live watershed group is lost" arm whose own comment calls it the only
# guard that survives ALLOW_SKIPPED=1. A release carrying both would delete every id in the
# literal with all four inert — the most destructive configuration available here, reached by
# passing a flag that reads like extra caution.
#
# They are for two different jobs. The literal is a REPLACEMENT: these ids go and their groups
# stay, which is checkable, so it is checked and the delete is performed. The flag is a REMOVAL:
# a group leaves the catalogue, which the group arm cannot distinguish from a short build, so it
# is waived and nothing is deleted. Wanting both in one release means wanting the guards off for
# the replacement too; cut two releases instead.
# --skip-sync uploads NOTHING but collection.json on a full release (step 2+3 below). That is
# safe only while every id the collection links is already in the bucket, which is true for a
# republish and false the moment a build ADDS an item: the published collection would name
# objects that were never uploaded, and a reload-from-S3 deletes the collection's rows before
# discovering one 404s. Refused here rather than reported, because the combination has no
# legitimate use — the whole point of the flag is "the bytes are already up".
#
# The orphan/added sets are not known until the preflight has read the live collection, so the
# test itself lives there; this is only the note that it exists.
if [ -n "$ALLOW_RETRACT" ] && [ "$n_retired" -gt 0 ]; then
  echo "--allow-retract and a non-empty RETIRED_ITEMS do not combine." >&2
  echo "The flag waives the containment, group-survival and served-equals-build arms — the" >&2
  echo "exact guards a retirement relies on — so the two together would delete every id in" >&2
  echo "the literal unchecked. The literal alone retracts; the flag alone retracts nothing." >&2
  echo "For a replacement, drop the flag. For a group leaving with no replacement, clear the" >&2
  echo "literal and keep the flag. For both, cut two releases." >&2
  exit 1
fi

cd "$REPO"

# Fielded search, used by both the preflight and the verify. `fields.include` is
# mandatory, not an optimization: an unfielded GET /items returns the full
# unsimplified floodplain geometries — ~34 s and ~34 MB for 17 items (measured when the collection held 17), growing
# linearly as groups are added, so it would eventually just time out. Fielded it is
# 8 KB in 0.15 s.
fetch_live_ids() {
  curl -sf --max-time 120 -X POST "$API_ROOT/search" \
    -H 'Content-Type: application/json' \
    -d "{\"collections\":[\"$COLLECTION\"],\"limit\":1000,\"fields\":{\"include\":[\"id\"]}}" \
    | python3 -c "import sys,json; print('\n'.join(sorted(f['id'] for f in json.load(sys.stdin)['features'])))"
}

# The live watershed groups, one per line, for the "no group is lost" arm. A second fielded
# search rather than widening fetch_live_ids, so an ordinary release — which never calls this
# — makes exactly the requests it made before. `properties.wsg` is a published field on every
# item (measured on larl_bt_ff04, 2026-10-14: "LARL"), which is why the arm reads it instead
# of parsing a group out of an id: CLAUDE.md's rule is that nothing here takes an id apart,
# and `wsg` is the fact itself rather than a reconstruction of it.
fetch_live_wsgs() {
  curl -sf --max-time 120 -X POST "$API_ROOT/search" \
    -H 'Content-Type: application/json' \
    -d "{\"collections\":[\"$COLLECTION\"],\"limit\":1000,\"fields\":{\"include\":[\"id\",\"properties.wsg\"]}}" \
    | python3 -c "import sys,json
feats = json.load(sys.stdin)['features']
out = set()
for f in feats:
    w = (f.get('properties') or {}).get('wsg')
    if not w:
        raise SystemExit('live item %s serves no wsg' % f.get('id'))
    out.add(w.upper())
print('\n'.join(sorted(out)))"
}

# The live collection's version, or the literal MISSING when it carries none. MISSING is
# a real state (the catalogue before its first versioned release), and a failed read must
# not look like it: curl -f and a parse that raises on a non-JSON body both fail the
# pipeline, and every caller tests the exit status before using the value.
version_of() { python3 -c "import sys,json; print(json.load(sys.stdin).get('version', 'MISSING'))"; }
fetch_live_version() { curl -sf --max-time 60 "$API" | version_of; }

# The licence, the licence link and the citation, as whatever is serving the collection
# actually hands them over (#47). Prints ONE token — OK, or BAD followed by each field that
# is wrong — so the caller branches on a value rather than on a grep, which under pipefail
# would read a failed fetch as a clean no-match. A failed fetch or an unparseable body
# raises here and fails the pipeline, exactly as version_of does, so "served wrong" and
# "could not read" stay distinguishable.
#
# It is read back rather than assumed because publishing a field is not serving it, and for
# the link that gap is real: pgstac REBUILDS a collection's links array through get_links(),
# dropping every rel it infers — which is why the 23 rel=item links this build publishes are
# served as none. rel=license falls outside that set and should survive. This is what turns
# "should" into evidence.
#
# The expected value arrives as argv, not interpolated into the script text: a literal
# spliced into a quoted python -c body is one apostrophe away from a syntax error, and the
# whole point of this function is that it fails loudly rather than emptily.
#
# Compared FIELD BY FIELD against the collection.json this release published, not merely
# checked for presence. Presence is not the question: the question is what the pipe did to
# the values, and the one thing pgstac does to a link it keeps is rewrite the href through
# urljoin. A presence check answers OK for a licence link pointing anywhere at all, and for
# a citation reading "Copyright. All rights reserved." (both measured).
#
# Comparing served against published is not a round-trip through our own assignment: the
# published copy is this pipeline's INPUT, and item_validate.py already gated it verbatim
# against its own independently written literal before a byte was synced. `license` is the
# exception, compared to the constant as well, because it is the one field a consumer's
# rights actually turn on.
#
# Absence is refused on every field, on both sides — see the note on the citation branch
# for which arm does that and which one only names the side at fault.
licence_of() {  # $1 = the published collection.json; served JSON on stdin
  python3 -c '
import json, sys
want, local_path = sys.argv[1], sys.argv[2]
served, built = json.load(sys.stdin), json.load(open(local_path))

def href(d, rel):
    ls = [l for l in (d.get("links") or []) if l.get("rel") == rel]
    return ls[0].get("href") if len(ls) == 1 else None

bad = []
if served.get("license") != want:
    bad.append("license=" + repr(served.get("license")))
# The three-way split matters; the `built-has-no-*` arms do NOT change any verdict.
# Verified over all 16 absence states: it is the `is None` arm on the SERVED side, in each
# branch below, that refuses every absence including both-absent — which is the hole a plain
# `served != built` had, since None == None. What the built-side arms change is which side
# the message accuses, and that is worth the branch: "the build never published it" sends
# you to collection.json, "the API dropped it" sends you to pgstac. A release log naming the
# wrong one costs an investigation in the wrong place.
if built.get("sci:citation") is None:
    bad.append("built-has-no-citation")
elif served.get("sci:citation") is None:
    bad.append("sci:citation-absent")
elif served.get("sci:citation") != built.get("sci:citation"):
    bad.append("sci:citation-differs")
for rel in ("license", "derived_from"):
    s, b = href(served, rel), href(built, rel)
    if b is None:
        bad.append("built-has-no-" + rel + "-link")
    elif s is None:
        bad.append("rel=" + rel + "-link-absent")
    elif s != b:
        bad.append("rel=" + rel + "-href=" + repr(s))
print("OK" if not bad else "BAD " + " ".join(bad))' "$EXPECT_LICENSE" "$1"
}

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

# LC_ALL=C, so this sorts the way the live side does. fetch_live_ids sorts in Python, which is
# codepoint order; a shell `sort` follows LC_COLLATE, and step 7 compares the two as plain
# strings. The two agree for id-shaped input on this machine (measured), so the exposure is a
# release cut on a differently-configured host, where the mismatch would report "the retirement
# did not take" AFTER the delete had run. Every other id or group list compared in this script
# is pinned the same way — `retired_ids` below and `build_wsgs` in the group arm — because a
# `comm` needs both sides ordered alike to mean anything. Enumerated rather than asserted: an
# earlier version of this comment claimed pinning it HERE fixed every comparison at once, and
# `build_wsgs` was still on a bare `sort`, feeding the one arm that survives ALLOW_SKIPPED=1.
local_ids=$(for f in "$STAC_DIR"/*.json; do
  b=$(basename "$f" .json); [ "$b" = collection ] || echo "$b"
done | LC_ALL=C sort)
n_local=$(printf '%s\n' "$local_ids" | grep -c . || true)
[ "$n_local" -ge 1 ] || { echo "No item JSON in $STAC_DIR." >&2; exit 1; }

# Fail before the sync if the host is unreachable, rather than after ~1.3 GB is up.
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
  # Here-string, closing the last two members of the early-exit class (see the NEWS scan
  # below). Both of these are pre-existing and both carry tiny inputs — $live_ids is ~300 B
  # against a 64 KiB pipe buffer — and both fail toward refusal, so neither was reachable or
  # unsafe. Converted anyway: a class is closed by having no members, and the two left behind
  # are what a later reader would copy.
  if ! grep -qxF -- "$ONLY" <<<"$live_ids"; then
    echo "$ONLY is not live. --only republishes an EXISTING item; a new item needs a" >&2
    echo "full release, which updates the collection's extent, summaries and links." >&2
    exit 1
  fi
  echo "live-vs-build comparison: skipped under --only (this build may hold one group; nothing is retracted)."
  # The provenance floor cannot apply to a one-group tree, and --only is the release path
  # in use — so the guard here is the live item itself (#32 review). Two arms, because the
  # rename in #74 showed one is not enough:
  #
  #   VALUES, from the API. Any value the live item serves that this build does not carry is
  #   provenance LOST between the producer's record and the build — a reader that found
  #   nothing, or only some sections. Per field, not a total: network found and landcover lost
  #   is the realistic shape and a count would pass it. Both sides are canonicalised to the
  #   STAGED field names first, so the comparison still works across #74's rename: the live
  #   item may be serving `nge:link_version` while the build publishes
  #   `processing:software.link`, and a scan for either name alone would compare a full item
  #   against an empty one and call it clean.
  #
  #   SHAPE, from the BUCKET. The API drops null properties (#31/#36, measured), so it cannot
  #   show what KEYS a pre-#74 item was published with — the two all-provenance-less items
  #   serve none at all, and a contract change on them would look like no change. The bucket
  #   copy is the document this release would overwrite and it keeps its nulls, so it is what
  #   answers "is this the same contract". Any difference refuses --only: republishing one
  #   item under a new contract leaves every other live item on the old one, which is
  #   invisible from the API and permanent on a bucket with versioning Suspended.
  # The bucket copy, fetched before the comparison and cleaned up on EXIT. One trap in this
  # script, so there is nothing for a second one to replace.
  only_bucket=$(mktemp -t only_bucket.XXXXXX) \
    || { echo "Could not create a temp file for the bucket comparison." >&2; exit 1; }
  trap 'rm -f "$only_bucket"' EXIT
  # Redirection, not `curl -o`: every other read of a DOCUMENT in this script takes curl's
  # stdout (the two `-o /dev/null` calls read a status code, not a body), and the check
  # harness shims curl by printing the fixture — so a `-o` here would leave an empty file and
  # the comparison would be made against nothing. Measured: it did, and 28 assertions failed.
  curl -sf --max-time 60 "$S3_BASE/$ONLY.json" > "$only_bucket" \
    || { echo "Could not read the bucket copy of $ONLY — refusing to publish blind. It is" >&2
         echo "live, so the bucket must hold it; a 403/404 here is a bucket problem." >&2; exit 1; }
  # A FILE, not an inline `python3 -c` (#74): the program used to be the argument of a
  # double-quoted shell string, and bash got to it before python did. Three characters broke
  # it in one afternoon — a markdown backtick span that RAN, the quoted phrase in the comment
  # recording that, and a `$(` the pattern written to catch both did not match. Every fix was
  # right and every one left a new hole, because the hazard was the construct. In a file there
  # is no shell quoting left to get wrong.
  #
  # `python3`, not `uv run`: this needs stdlib only, it must work on a release machine holding
  # nothing but this repo, and catalogue_release-check.sh shims `uv`.
  only_prov=$(curl -sf --max-time 60 "$API/items/$ONLY" \
    | python3 scripts/only_preflight.py "$STAC_DIR/$ONLY.json" "$only_bucket") \
    || { echo "Could not read the live item's provenance — refusing to publish blind." >&2; exit 1; }
  # IFS='|', so an empty field stays in its own position: with whitespace splitting, an empty
  # `lost` beside a non-empty `dropped` would hand the dropped keys to the wrong variable and
  # the wrong message would be printed for them.
  IFS='|' read -r only_live_prov only_built_prov only_lost_prov only_dropped_prov only_gained_prov <<EOF
$only_prov
EOF
  echo "provenance under --only: live item carries $only_live_prov value(s), this build carries $only_built_prov."
  if [ -n "$only_lost_prov" ]; then
    echo "The live $ONLY carries provenance this build does not: $only_lost_prov." >&2
    echo "A reader that found nothing, or only some sections, or a stage from a tree without the" >&2
    echo "producer's provenance.json. Refusing before anything is written." >&2
    exit 1
  fi
  if [ -n "$only_dropped_prov" ]; then
    echo "The bucket copy of $ONLY publishes provenance key(s) this build does not: $only_dropped_prov." >&2
    echo "A renamed or re-shaped provenance contract is a FULL-release change — republishing one" >&2
    echo "item would leave every other live item on the old contract, and the API cannot show it" >&2
    echo "because it drops nulls. Refusing." >&2
    exit 1
  fi
  if [ -n "$only_gained_prov" ]; then
    echo "provenance gained since the bucket copy: $only_gained_prov (an area re-run upstream; --only may publish it)."
  fi
else
orphans=$(comm -23 <(printf '%s\n' "$live_ids") <(printf '%s\n' "$local_ids") || true)
added=$(comm -13 <(printf '%s\n' "$live_ids") <(printf '%s\n' "$local_ids") || true)

# --skip-sync + an item this build ADDS. The flag means "the bytes are already on S3", which a
# new item makes false: step 2+3 would upload collection.json and nothing else, publishing a
# document that links objects that do not exist. rtj's reload-from-S3 reads exactly those
# links, DELETEs every row of the collection, then 404s and aborts — the stac-dem-bc outcome,
# on a bucket with versioning Suspended. It also survives a FAILED release, because the
# collection `cp` happens at step 2+3 and the probe that might notice is at step 5.
if [ -n "$SKIP_SYNC" ] && [ -n "$added" ]; then
  echo "--skip-sync cannot publish a build that ADDS items:" >&2
  printf '  %s\n' $added >&2
  echo "The flag uploads only collection.json on a full release, so the collection would link" >&2
  echo "objects that were never sent. Run without --skip-sync." >&2
  exit 1
fi

# --- what the literal names, checked before what the catalogue holds -------------------
# Each arm names the id it refuses on. All of them run inside step 0, upstream of the
# validator and of every byte written, so a wrong literal costs a message and nothing else.
if [ "$n_retired" -gt 0 ]; then
  # Already in the build: the id would be registered by step 4 and deleted by step 6 of the
  # same run. Cheap, and it is the state an upstream un-retirement produces — a group whose
  # area.yml went back to naming the species scenario after the literal was written.
  also_built=$(comm -12 <(printf '%s\n' "$retired_ids") <(printf '%s\n' "$local_ids") || true)
  if [ -n "$also_built" ]; then
    echo "RETIRED_ITEMS names an item THIS BUILD also produces:" >&2
    printf '  %s\n' $also_built >&2
    echo "Registering and then deleting the same id in one release is not a retirement." >&2
    exit 1
  fi

  # Not live. Two very different states, told apart by the BUCKET copy, which is the one
  # independent witness available here — neither sync passes --delete and the S3 deletion is
  # a separate, later, deliberate step, so a just-retired id still has its document in the
  # bucket while a typo never had one.
  #
  # The distinction is what keeps the release idempotent (its header promises that). If both
  # states refused, a verify failure AFTER the delete would make the re-run impossible: the
  # ids are no longer live, so the literal could not be satisfied, and editing it costs a new
  # commit, a new NEWS entry and a new tag because of the clean-tree and exact-tag gates.
  not_live=$(comm -23 <(printf '%s\n' "$retired_ids") <(printf '%s\n' "$live_ids") || true)
  already_retired=""
  for id in $not_live; do
    # THREE outcomes, not two, and this arm is the reason the distinction matters: it exists so
    # a re-run after a verify failure is possible, and its refusal costs a new commit, a new
    # NEWS entry and a new tag. Collapsing "the bucket holds no such Item" into "the bucket
    # could not be read" would send an operator to that price for a timeout. This file states
    # the rule twice already, for fetch_live_version and for the licence read-back: a failed
    # read must not look like a known answer.
    #
    # The STATUS first, by HEAD, which is cheap. Then the BODY, and its id — because a 200 from
    # a URL only proves something answers at that key, and the key is built from the literal.
    # `collection` was the reachable case: it clears the shape guard, is absent from
    # `local_ids` by construction, and `collection.json` of course answers 200, so a
    # HEAD-based witness reported it "already retired" and the release completed announcing a
    # retirement it never performed. Asking the document who it is closes that whole class,
    # the `../collection.json` form included — the difference between guarding the symptom and
    # checking the property.
    #
    # Branching on the probe's OUTPUT rather than its exit status, deliberately: the pipeline
    # carries two statuses and `$( )` hides PIPESTATUS, so a value is the only thing that can
    # tell python's verdict from curl's transport failure.
    code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 60 "$S3_BASE/$id.json" || echo 000)
    ident=""
    if [ "$code" = 200 ]; then
      # Only now the body, which is 5.6-18.2 MB per item on the v2.0.0 build (measured; it
      # was 4-9 MB before the whole network widened every item). Bounded by construction:
      # $not_live is EMPTY on any release where every id in the literal is still live, i.e.
      # every release except a re-run. Do not "optimise" this back to a HEAD — that is the
      # defect above. NOTE the --max-time 60 below is now against an 18 MB body.
      ident=$(curl -sf --max-time 60 "$S3_BASE/$id.json" 2>/dev/null \
        | python3 -c "import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('UNREADABLE'); raise SystemExit(0)
print('MATCH' if d.get('type') == 'Feature' and d.get('id') == sys.argv[1] else 'OTHER')" "$id" \
        || true)
    fi
    case "$code:$ident" in
      200:MATCH)
        already_retired="$already_retired $id" ;;
      200:OTHER)
        echo "RETIRED_ITEMS names something that is not an item of this collection: $id" >&2
        echo "The bucket holds an object at $id.json, but it is not a STAC Item with that id." >&2
        echo "Check the literal against what the collection actually serves." >&2
        exit 1 ;;
      404:*|403:*)
        echo "RETIRED_ITEMS names an item that was never published: $id" >&2
        echo "It is absent from the API and the bucket answers $code for $id.json, so there is" >&2
        echo "nothing to retire. Check the literal against what the collection serves." >&2
        exit 1 ;;
      *)
        echo "Could not read $id.json from the bucket (HTTP '$code', verdict '${ident:-none}')." >&2
        echo "This arm decides whether $id was already removed by an earlier run of this" >&2
        echo "release, or had no document here at all, and those have different remedies — so" >&2
        echo "a read it could not complete is refused rather than guessed. Retry." >&2
        exit 1 ;;
    esac
  done
  if [ -n "$already_retired" ]; then
    echo "RETIRED_ITEMS: already retired by an earlier run of this release —$already_retired"
    echo "  (absent from the API, still in the bucket; the S3 objects are a separate step)"
  fi
fi

# --- what the catalogue holds that this build does not ---------------------------------
if [ -n "$orphans" ]; then
  echo "These items are LIVE but absent from this build:" >&2
  printf '  %s\n' $orphans >&2
  unaccounted=$(comm -23 <(printf '%s\n' "$orphans") <(printf '%s\n' "$retired_ids") || true)
  if [ -n "$unaccounted" ] && [ -z "$ALLOW_RETRACT" ]; then
    echo "These are LIVE, absent from this build, and not named in RETIRED_ITEMS:" >&2
    printf '  %s\n' $unaccounted >&2
    echo "Either name them in RETIRED_ITEMS — which makes the release delete them, and" >&2
    echo "requires each one's watershed group to survive in this build — or, for a group" >&2
    echo "leaving the catalogue with no replacement, use --allow-retract." >&2
    # The second remedy is only REACHABLE with an empty literal, because the flag and a
    # non-empty literal are refused together. Printing it unconditionally would send an
    # operator mid-retirement to a flag that refuses, and the arm that fires next would be
    # the refusal rather than the release.
    if [ "$n_retired" -gt 0 ]; then
      echo "  (this release already retires $n_retired item(s), and --allow-retract does not" >&2
      echo "   combine with that — either add these ids to the literal, or retire them in a" >&2
      echo "   separate release.)" >&2
    fi
    exit 1
  fi
  [ -z "$unaccounted" ] || echo "--allow-retract set — publishing past $(printf '%s\n' "$unaccounted" | grep -c . || true) unretired orphan(s)." >&2

  # The group arm. Gated on $orphans, which costs an ordinary release nothing and loses no
  # coverage: if a live group has no item in the build then every one of its items is live
  # and unbuilt, so $orphans cannot be empty while a group is missing.
  #
  # This is the ONLY arm that survives ALLOW_SKIPPED=1. That flag suppresses PARTIAL_STAGE
  # altogether (01_stage.R), so the interlock above is ABSENT rather than passing and a short
  # build looks like a full one. The worked case, measured 2026-10-14 while the upstream
  # conversion was half done: a full rebuild staged 10 of 23 groups, so with ALLOW_SKIPPED
  # set the orphan set was 17 ids a human could fill into the literal in good faith, every
  # other arm would pass, and the collection would silently drop 13 watershed groups onto a
  # bucket with no versioning. What refuses it is that `mcgr`, `ufra`, `will` and the rest
  # appear in no build id at all. All 23 stage as of v2.0.0, so that exact shape is not
  # reachable from today's tree — the arm is for the next partial conversion, not that one.
  if [ -z "$ALLOW_RETRACT" ]; then
    live_wsgs=$(fetch_live_wsgs) \
      || { echo "Could not read the live watershed groups — refusing to publish blind." >&2; exit 1; }
    build_wsgs=$(for f in "$STAC_DIR"/*.json; do
      b=$(basename "$f" .json); [ "$b" = collection ] && continue
      python3 -c "import sys,json
w = (json.load(open(sys.argv[1])).get('properties') or {}).get('wsg')
if not w: raise SystemExit('built item %s carries no wsg' % sys.argv[1])
print(w.upper())" "$f"
    done | LC_ALL=C sort -u) \
      || { echo "Could not read the watershed groups out of this build." >&2; exit 1; }
    lost=$(comm -23 <(printf '%s\n' "$live_wsgs") <(printf '%s\n' "$build_wsgs") || true)
    if [ -n "$lost" ]; then
      echo "These watershed groups are LIVE but no item in this build covers them:" >&2
      printf '  %s\n' $lost >&2
      echo "A retirement replaces a group's item; it does not drop the group. Fix upstream" >&2
      echo "and rebuild — that is almost always a build that skipped a group, so check" >&2
      echo "data/raw/PARTIAL_STAGE and whether ALLOW_SKIPPED was set when it was staged." >&2
      # Same reachability point as the containment arm: --allow-retract is the remedy only
      # when nothing is being retired, and this arm fires during a retirement too.
      if [ "$n_retired" -gt 0 ]; then
        echo "  (--allow-retract is NOT the way out here: it does not combine with the" >&2
        echo "   $n_retired item(s) in RETIRED_ITEMS, and it would waive this very arm.)" >&2
      else
        echo "If the group really is leaving the catalogue, --allow-retract is the flag." >&2
      fi
      exit 1
    fi
    echo "watershed groups: $(printf '%s\n' "$build_wsgs" | grep -c . || true) in this build, every live group covered"
  fi
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
  # Here-string for the same SIGPIPE reason as the id scan below; `grep -m1` exits early too,
  # and $news is the whole file (47,156 B on the v2.0.0 commit, against a 64 KiB pipe
  # buffer — 1.39x, so re-measure this one as NEWS.md grows).
  if ! news_top=$(grep -m1 -E '^## ' <<<"$news"); then
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

  # Every retired id has to be named in the release entry — the issue's own third work item
  # ("record the retirement in the release notes for the version that carries it, listing the
  # item ids removed"), asserted rather than remembered. Here and not in the orphan block,
  # because $news is the TAGGED NEWS.md and the version gate is what reads it; a check from
  # the working tree would pass on a file that was written and never added.
  #
  # The TOP section only, from the version heading to the next one: an id named in last
  # release's entry is not this release documenting itself. Deleting a public item id is the
  # least reversible thing this script does, and a release note is the only place a consumer
  # can find out it happened.
  if [ "$n_retired" -gt 0 ]; then
    news_entry=$(printf '%s\n' "$news" | awk '/^## /{n++} n==1')
    unnamed=""
    for id in $retired_ids; do
      # Delimited, not a substring. `grep -qF "$id"` passed for any entry merely CONTAINING
      # the text: an id of `collection` matched every real entry, and `bulk_all_ff04` would
      # match an entry that only named `bulk_all_ff04_v2`. The ids are charset-guarded above,
      # so none of them can carry a regex metacharacter into this pattern.
      # A here-string, not a pipe. `grep -q` exits at its first match, and under `set -o
      # pipefail` the writer's SIGPIPE becomes the test's answer once the text exceeds the pipe
      # buffer — measured at 64 KiB on this machine. NEWS.md is 47,156 B on the v2.0.0
      # commit and its top section 36,129 B, so this is not reachable yet; it is 1.8x of
      # margin on a file that only grows — it was 2.0x before this release's own entry
      # (main's top section is 32,989 B), measured with the awk slice just below — and
      # the failure would read as "the id is not named" for an id that is.
      # This file already documents the trap for `grep -m1` a few lines up.
      grep -qE "(^|[^A-Za-z0-9_-])$id([^A-Za-z0-9_-]|\$)" <<<"$news_entry" \
        || unnamed="$unnamed $id"
    done
    if [ -n "$unnamed" ]; then
      echo "RETIRED_ITEMS names items the NEWS.md entry for v$VERSION does not mention:$unnamed" >&2
      echo "Retiring an item deletes a public id. List every one in the release entry, in the" >&2
      echo "tagged commit, or a consumer has no record that it was withdrawn." >&2
      exit 1
    fi
    echo "retirement: $n_retired item(s) named in RETIRED_ITEMS and in the v$VERSION entry"
  fi
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
  # --partial for the same reason (#26): the deprecation check's set compare is against the
  # WHOLE catalogue, and a one-group tree cannot meet it — without this every group but the
  # two marked ones is refused, killing the #36 single-group path. Its per-item arms still run.
  uv run python scripts/item_validate.py --base "$STAC_DIR" --expect "$n_local" --partial
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
#
# TWO calls, and the ORDER is the point: the items first, collection.json last, never one
# sync over both. `aws s3 sync` parallelises its uploads and guarantees nothing about the
# order within a pass, so a pass that happened to put collection.json up and then failed —
# network, credentials, a Ctrl-C — left the bucket's collection linking item documents that
# do not exist. rtj's reload-from-S3 reads exactly those `rel: item` hrefs, DELETEs every row
# of the collection, and only then discovers one of them 404s: it aborts, and the collection
# serves nothing. Its own script records that happening to stac-dem-bc.
#
# Latent on every release so far, because none of them ADDED an item — every href in the
# collection already resolved. The release that completed floodplains#125 added 23 at once,
# which is the largest exposure this bucket has had, so the window is closed now rather than
# discovered then. The --skip-sync path above already had this shape (one `cp` of the
# collection); this makes the full path agree with it.
aws s3 sync "$STAC_DIR" "s3://$BUCKET" \
  --exclude '*' --include '*.json' --exclude '*/*' --exclude 'collection.json'
aws s3 cp "$STAC_DIR/collection.json" "s3://$BUCKET/collection.json"

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
# CONTAINMENT, not equality. The retirement has not happened yet at this point — step 6 runs
# after every probe below, so that a probe failure costs nothing — which means the ids this
# release is about to delete are legitimately still live here. Demanding equality instead
# would also break the re-run after a verify failure, when they are legitimately gone.
# Step 7 is where equality is required, once the delete has actually run.
surplus=$(comm -23 <(printf '%s\n' "$extra") <(printf '%s\n' "$retired_ids") || true)
if [ -n "$surplus" ] && [ -z "$ALLOW_RETRACT" ]; then
  echo "LIVE BUT NOT IN THIS BUILD, AND NOT RETIRED BY IT:"; printf '  %s\n' $surplus
  echo "  drop with: scripts/item_unregister.sh $(printf '%s ' $surplus)"
  fail=1
fi
probe_item=$(head -1 <<<"$local_ids")
fi

# Every id the published collection links must have a document in the bucket. Until now
# NOTHING checked this: step 5 compared ids against the API and probed one asset of one item,
# and the only bucket reads in this script were collection.json, $ONLY.json and the retirement
# witness. So the invariant the step-3 sync split rests on — "collection.json never links an
# absent object" — was enforced by the ORDER of two statements and never read back, which is
# the whole shape of a guard that cannot fail. A HEAD per id, which is cheap, and it also
# catches a sync that died partway in the normal path.
if [ -z "$ONLY" ]; then
  # The set this iterates is the COLLECTION'S OWN `rel: item` links, read out of the document
  # about to be published — not `$STAC_DIR/*.json`. The two agree only because item_create.py
  # writes links and files in one run, and nothing read that back: item_validate.py checks the
  # item COUNT, never the links against the files. An id the collection links whose document is
  # absent is exactly what kills a reload-from-S3, so it is the links that have to be the
  # question. Asserted equal to the file set as well, since a disagreement either way is a
  # broken build.
  linked_ids=$(python3 -c "
import json, posixpath, sys
d = json.load(open(sys.argv[1]))
out = set()
for l in d.get('links') or []:
    if l.get('rel') == 'item':
        b = posixpath.basename(l.get('href') or '')
        out.add(b[:-5] if b.endswith('.json') else b)
print('\n'.join(sorted(out)))" "$STAC_DIR/collection.json") && links_read=1 \
    || { echo "  could not read the rel:item links out of the built collection.json" >&2
         fail=1; links_read=""; linked_ids=""; }
  # Compared whether or not the set is EMPTY. Guarding the compare on `-n "$linked_ids"` let a
  # collection that links NOTHING pass silently while the build held items — a guard failing
  # toward pass, and the state a dropped link block would produce.
  if [ -n "$links_read" ] && [ "$linked_ids" != "$local_ids" ]; then
    echo "  the built collection.json links a different item set than this build holds:" >&2
    comm -3 <(printf '%s\n' "$linked_ids") <(printf '%s\n' "$local_ids") | sed 's/^/    /' >&2 || true
    fail=1
  fi
  absent=""; unread=""
  for id in $linked_ids; do
    code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 60 "$S3_BASE/$id.json" || echo 000)
    # 404/403 is "no document"; anything else is a read that did not complete, and those have
    # different remedies. Collapsing them is the mistake the retirement witness 400 lines above
    # refuses to make, and that this file states the rule against three times — and here it
    # would print an alarming and false claim about a reload deleting the collection.
    case "$code" in
      200) ;;
      404|403) absent="$absent $id($code)" ;;
      *)       unread="$unread $id($code)" ;;
    esac
  done
  if [ -n "$absent" ]; then
    echo "  the bucket has no document for item(s) this collection links:$absent" >&2
    echo "  A reload-from-S3 would delete the collection's rows and then fail on these." >&2
    fail=1
  fi
  if [ -n "$unread" ]; then
    echo "  could not read the bucket document for item(s):$unread" >&2
    echo "  Not the same as absent, and not assumed to be: retry before concluding anything." >&2
    fail=1
  fi
  [ -n "$absent$unread" ] \
    || echo "bucket documents: all $(printf '%s\n' "$linked_ids" | grep -c . || true) linked item(s) present"
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
# wholesale. Not checksums alone, because a checksum answers a narrower question than this
# needs: labels, provenance and the loss/gain figures all change with no byte changing at
# all. (Until #80 there was a second reason — the largest asset was an upstream gpkg copied
# verbatim, so a COG-only republish left its checksum identical. No published asset is a
# verbatim upstream copy now: both GeoPackage bundles are written here by the R-side GDAL,
# 3.8.5 on this machine rather than the 3.12+ the uv env gives the COGs, so a rebuild on a
# differently-linked machine moves them.) pgstac returns the document as
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

# The licence a CONSUMER is handed is the only one that governs what they may do with the
# data, and it is the last thing in this pipeline that is not yet evidence: item_validate.py
# proved the bytes on disk, and everything between here and there — the sync, pypgstac, the
# API's own serialiser — is a place they could be lost. Both surfaces, for the same reason
# the version stamp checks both: rtj's stac_register-all.sh can reload this collection from
# S3, which is harmless only while bucket and API agree.
#
# Full release only. --only never publishes collection.json, so there is nothing here it
# could have changed, and asserting a licence it did not write would make an unrelated
# drift refuse a correct republish.
if [ -z "$ONLY" ]; then
  # READFAIL rather than a BAD token: the read failure is already reported on its own line,
  # and letting it fall through would print a second, false line claiming the API served
  # something wrong. Distinguishing the two is the point of the sentinel.
  live_licence=$(curl -sf --max-time 60 "$API" | licence_of "$STAC_DIR/collection.json") \
    || { echo "  could not read the live collection licence after registration" >&2
         live_licence="READFAIL"; fail=1; }
  case "$live_licence" in
    OK) echo "live collection licence: $EXPECT_LICENSE, sci:citation and both links served as published" ;;
    READFAIL) : ;;
    *)  echo "  the API is not serving the licence this build published: ${live_licence#BAD }" >&2
        fail=1 ;;
  esac

  # The deprecation markers (#26), read back for exactly the reason the licence is: the
  # field's ENTIRE purpose is that a consumer sees it, and publishing is not serving. Per-item
  # rather than a collection field, so it rides the same fielded search the id comparison uses.
  #
  # One reader, one pass over the build, one token — the licence_of shape. The first version
  # of this did it in three guarded stages that read the build TWICE per file (~226 MB of
  # JSON parsing) and had three places to fail toward pass; collapsing it removes the class
  # rather than patching instances.
  #
  # The served set is intersected with the build's ids on purpose: registration is an upsert,
  # so under --allow-retract a dropped marked item stays live, and comparing raw sets would
  # report RELEASE INCOMPLETE for a retraction the operator explicitly asked for.
  #
  # Be honest about the cost. Orphans are the id comparison's business above, but that
  # comparison gates BOTH its message and `fail=1` on `[ -z "$ALLOW_RETRACT" ]` — so in the one
  # mode this intersection exists for, a retracted item that is still live serving
  # `deprecated: true` is reported by nothing, and RELEASE COMPLETE prints. Retracting a marked
  # item therefore wants an explicit `item_unregister.sh` for it; the release will not say so.
  #
  # A build-side null cannot reach here — item_validate.py refuses `deprecated: null` — so
  # served-absent means served-absent rather than served-and-dropped-by-the-API.
  dep_state=$(curl -sf --max-time 120 -X POST "$API_ROOT/search" \
    -H 'Content-Type: application/json' \
    -d "{\"collections\":[\"$COLLECTION\"],\"limit\":1000,\"fields\":{\"include\":[\"id\",\"properties.deprecated\"]}}" \
    | python3 -c "
import glob, json, sys
served = {f['id'] for f in json.load(sys.stdin)['features']
          if (f.get('properties') or {}).get('deprecated') is True}
built_ids, built_marked = set(), set()
for path in glob.glob('$STAC_DIR/*.json'):
    d = json.load(open(path))
    if d.get('type') != 'Feature':
        continue
    built_ids.add(d['id'])
    if (d.get('properties') or {}).get('deprecated') is True:
        built_marked.add(d['id'])
served &= built_ids
fmt = lambda s: ' '.join(sorted(s)) or 'NONE'
print('OK ' + fmt(built_marked) if served == built_marked
      else 'BAD ' + fmt(served) + '|' + fmt(built_marked))") \
    || { echo "  could not read the deprecation markers back after registration" >&2
         dep_state="READFAIL"; fail=1; }
  case "$dep_state" in
    "OK "*) echo "deprecation markers served: ${dep_state#OK }" ;;
    READFAIL) : ;;
    *) # `|` cannot appear in an id: item_create.py builds them as <wsg>_<sp>_ff0N from
       # directory names, and item_validate.py refuses anything else. (The shape check at the
       # top of THIS script validates only $ONLY, so it is not the reason.)
       _d="${dep_state#BAD }"
       echo "  the API serves deprecated on '${_d%%|*}' but this build marks '${_d#*|}'" >&2
       fail=1 ;;
  esac

  bucket_licence=$(curl -sf --max-time 60 "$S3_BASE/collection.json" | licence_of "$STAC_DIR/collection.json") \
    || { echo "  could not read the licence from the bucket copy of collection.json" >&2
         bucket_licence="READFAIL"; fail=1; }
  case "$bucket_licence" in
    OK) echo "bucket collection.json licence: agrees" ;;
    READFAIL) : ;;
    *)  echo "  the bucket copy does not carry the licence this build published: ${bucket_licence#BAD }" >&2
        fail=1 ;;
  esac
fi

# AFTER every probe, and this placement is the design. A delete between step 4 and step 5
# would precede the asset probe, the checksum probe, the version read-back, both licence
# read-backs and the deprecation read-back — all of which set `fail=1` and fall through to
# here — so the realistic bad day would be seventeen public items deleted and a release
# reporting INCOMPLETE. Placed here, a failed probe costs a failed release with the
# catalogue untouched, and the re-run is clean.
[ "$fail" -eq 0 ] || { echo "RELEASE INCOMPLETE" >&2; exit 1; }

final_ids="$after_ids"
if [ "$n_retired" -gt 0 ]; then
  echo ""
  echo "=== 6: RETIRE ==="
  # item_unregister.sh, not SQL written here: it already constrains each id's shape before
  # interpolating it, always scopes pgstac.delete_item to one collection (the one-arg form
  # reaches into the sibling collections in this same database), and is idempotent.
  #
  # COLLECTION and GEOSERV_HOST passed explicitly because neither is exported: without them
  # the subscript falls back to its own defaults, so a release pointed at a throwaway
  # collection — which this script's own header documents — would delete from the real one.
  #
  # Only the ids actually LIVE. The literal may legitimately name one the preflight reported
  # as already retired by an earlier run of this release, and `item_unregister.sh` is
  # idempotent — but "unregistering 1 item(s)" for an id that was already gone is a log line
  # that says something untrue, and it would make a count of deletes stop meaning anything.
  # The 404 check below still covers every id in the literal, so nothing is taken on trust.
  to_delete=$(comm -12 <(printf '%s\n' "$retired_ids") <(printf '%s\n' "$live_ids") || true)
  if [ -n "$to_delete" ]; then
    # `|| { ... exit 1; }` and not a bare call. item_unregister.sh sends one `DO $$...$$;`
    # block per id to a single `psql -v ON_ERROR_STOP=1`, with no enclosing transaction, so
    # an error on the twelfth id leaves eleven deleted and stops. Bare under `set -e` that
    # killed this script before step 7 — the ONLY evidence the delete happened — and before
    # the RELEASE INCOMPLETE block below that says the state is recoverable and how. The
    # operator saw a psql error and nothing else, on the one genuinely half-finished state
    # this script can reach. v2.0.0 is the first release to run it with a non-empty literal.
    COLLECTION="$COLLECTION" GEOSERV_HOST="$HOST" \
      bash scripts/item_unregister.sh $to_delete \
      || { echo "" >&2
           echo "RELEASE INCOMPLETE — the catalogue was published and the retirement failed" >&2
           echo "PART WAY THROUGH. item_unregister.sh deletes one id at a time under" >&2
           echo "ON_ERROR_STOP with no transaction, so some ids are gone and some are not." >&2
           # Say WHICH, rather than reprinting the whole literal. This is the state step 7
           # exists to report and the one state it never runs in, so the read happens here
           # instead; an operator told "some of these 23 may be gone" has to do it by hand
           # against a catalogue that is already half changed. Best-effort: a failed read
           # falls back to naming them all, which is the old behaviour and still true.
           if post_ids=$(fetch_live_ids); then
             gone=$(comm -23 <(printf '%s\n' "$to_delete") <(printf '%s\n' "$post_ids") || true)
             left=$(comm -12 <(printf '%s\n' "$to_delete") <(printf '%s\n' "$post_ids") || true)
             echo "already unregistered:$(printf ' %s' $gone)" >&2
             echo "still served:$(printf ' %s' $left)" >&2
           else
             echo "could not re-read the collection; these were the ids it was asked to" >&2
             echo "unregister, some of which may already be gone:" >&2
             printf '  %s\n' $to_delete >&2
           fi
           echo "No assets were deleted — no sync passes --delete, and item_retract_s3.sh is" >&2
           echo "a separate later step you have not reached — so this is recoverable." >&2
           echo "Re-run this release: it is idempotent, and the preflight tells an" >&2
           echo "already-deleted id from a never-published one by the bucket copy." >&2
           exit 1; }
  else
    echo "nothing to unregister — every id in RETIRED_ITEMS was already absent from the API"
  fi

  echo ""
  echo "=== 7: VERIFY RETIREMENT ==="
  # The ONLY evidence the delete happened. item_unregister.sh warns and exits 0 when it
  # deletes nothing, and this script never parses its NOTICEs, so without reading the
  # catalogue back a silently-empty delete reports OK.
  final_ids=$(fetch_live_ids) \
    || { echo "Could not re-read the collection after the retirement." >&2; exit 1; }
  rfail=0
  still=$(comm -12 <(printf '%s\n' "$retired_ids") <(printf '%s\n' "$final_ids") || true)
  if [ -n "$still" ]; then
    echo "RETIRED BUT STILL SERVED:" >&2; printf '  %s\n' $still >&2
    rfail=1
  fi
  # Now equality, which is the whole point: the served set and the build's set must agree,
  # so a group can never be left serving both its whole-network item and its species one.
  #
  # UNCONDITIONAL, and that is not an oversight. It used to carry `[ -z "$ALLOW_RETRACT" ]`,
  # copied from the step-5 arm — but the flag and a non-empty literal are refused together and
  # this whole block is gated on a non-empty literal, so that test could never be false. A
  # condition that cannot be false reads as a live escape hatch on the one arm the retirement
  # turns on, and the next reader looking for how to waive it would have found what looked like
  # the way.
  if [ "$final_ids" != "$local_ids" ]; then
    echo "after the retirement the served set is not this build (served vs built):" >&2
    comm -3 <(printf '%s\n' "$final_ids") <(printf '%s\n' "$local_ids") | sed 's/^/  /' >&2 || true
    rfail=1
  fi
  for id in $retired_ids; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$API/items/$id" || true)
    case "$code" in
      404|410) ;;
      *) echo "  $id still answers $code from the API" >&2; rfail=1 ;;
    esac
  done
  if [ "$rfail" -ne 0 ]; then
    echo "RELEASE INCOMPLETE — the catalogue was published but the retirement did not take." >&2
    echo "The assets are all still in the bucket (no sync passes --delete, and the S3" >&2
    echo "deletion is a separate later step), so this is recoverable. Re-run this release" >&2
    echo "first; it is idempotent and the preflight treats an already-deleted id as a re-run." >&2
    echo "To put a retired item BACK instead, fetch its document and register that — " >&2
    echo "item_register.sh reads local files only, so the bucket URL cannot be passed to it:" >&2
    echo "  aws s3 cp s3://$BUCKET/<item-id>.json \"\${TMPDIR:-/tmp}/\"" >&2
    echo "  scripts/item_register.sh \"\${TMPDIR:-/tmp}/<item-id>.json\"" >&2
    echo "  then RE-RUN THE RELEASE: this collection.json no longer links that item, so" >&2
    echo "  restoring only the API row leaves the bucket and the API disagreeing, which is" >&2
    echo "  the state a reload-from-S3 turns into an empty collection." >&2
    echo "Do not run scripts/item_retract_s3.sh until the release reports COMPLETE." >&2
    exit 1
  fi
  # |$to_delete|, not $n_retired. The literal's size counts ids this run may have found
  # already absent — the preflight's "already retired by an earlier run" path, which is the
  # normal state of a re-run after a verify failure. Reporting the literal there would claim
  # a delete that did not happen: the same untrue log line the comment above $to_delete
  # refuses for item_unregister.sh.
  echo "retired $(printf '%s\n' "$to_delete" | grep -c . || true) item(s) this run;" \
       "the collection now serves exactly this build"
fi

echo ""
if [ -n "$ONLY" ]; then
  echo "RELEASE COMPLETE — $ONLY republished; collection unchanged at $(printf '%s\n' "$after_ids" | grep -c .) items, version $live_version, $API"
else
  echo "RELEASE COMPLETE — v$VERSION: $(printf '%s\n' "$final_ids" | grep -c .) items live at $API"
fi
