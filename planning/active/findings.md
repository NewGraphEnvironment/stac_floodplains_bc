# Findings — catalogue_release.sh --only <item_id> (#36)

## Issue context

## What changes if we do it

A single group can be rebuilt and pushed with one command, so a change can be piloted on
BULK and inspected live before it is cut across all 17 items.

## What happens if we never do

Every pilot is a hand-assembled sequence of `aws s3 sync` flags whose subtleties are
load-bearing and easy to get wrong in the direction that damages the live catalog.

## The path exists, it is just not supported

Contrary to how `catalogue_release.sh` reads, a single-item republish is mechanically fine:

- `item_register.sh` upserts individual items — its own header says *"additive — an item
  dropped from the build is NOT removed here"*.
- The asset sync runs without `--delete`, deliberately, so a partial tree only adds and
  updates.

What the release script refuses is publishing the **collection** from a partial build, and
that refusal is correct. After a single-group build, `collection.json` reads:

```
extent.spatial : [[-120.25, 52.71, -118.48, 53.48]]     <- one group's bbox
summaries      : {'scenario': ['ch_ff04'], 'species': ['ch'],
                  'region': ['fraser'], 'flood_factor': [4]}
item links     : 1
```

Registering that replaces a collection describing 17 groups with one describing one.
Versioning is Suspended, so there is no undo. `PARTIAL_STAGE` is guarding `collection.json`,
not the items — the two got conflated.

## Proposed

`catalogue_release.sh --only <item_id>`:

1. validate — `item_validate.py` over the built tree
2. sync — assets for that item id only
3. sync — **that item's JSON only**, explicitly never `collection.json`
4. register — `item_register.sh` for the one file, never `collection_register.sh`
5. verify — the existing checksum probe, against that item

The `PARTIAL_STAGE` interlock and the live-vs-build orphan comparison are both skipped
under `--only`, and the script should say so out loud rather than silently: neither is
meaningful when the operator has named a single item, and both would refuse.

## The trap worth encoding

Step 3's existing JSON sync is `--exclude '*' --include '*.json' --exclude '*/*'`, which
sweeps `collection.json` in. Under `--only` that must be an explicit single-object copy.
Getting this wrong is the one way this feature could damage the live catalog, so it wants
a test, not just care.

## Motivation

#33, #34 and #35 all change published bytes and all want piloting on BULK before a
17-group release against a bucket with no rollback.


## Exploration (2026-09-01, plan mode)

- Live collection has **20** items, not the 17 the issue, `scripts/README.md` and `CLAUDE.md` say.
  Measured with the fielded search the release script itself uses. Stale prose, not a defect.
- `data/stac` on this machine held a single-group `bulk_co_ff04` tree with
  `data/raw/PARTIAL_STAGE` = `bulk`, built 20:48, five minutes before #38 merged. Phase 5 rebuilds.
- The sweeping step-3 sync's argv (`aws s3 sync $STAC_DIR s3://$BUCKET --exclude '*' --include '*.json' --exclude '*/*'`)
  **never contains the string `collection.json`**. A test grepping for the name would be empty on the
  correct code and on the defect alike. The test asserts the shape instead: no aws invocation whose
  source is the tree root, no sync carrying `--include *.json`.
- `item_validate.py` requires exactly one `collection.json` in `--base` (line 709), so the file stays
  required under `--only`.
- Asset hrefs are `https://<bucket>.s3.us-west-2.amazonaws.com/<id>/<name>` (`05_stac_register.py:47,151`).
- rtj's reload-from-S3 reads the bucket's `collection.json` (untouched under `--only`) plus the item
  URLs it lists, so it picks up a republished `<id>.json` — consistent.

## Errors Encountered

| Error | Resolution |
|-------|------------|
