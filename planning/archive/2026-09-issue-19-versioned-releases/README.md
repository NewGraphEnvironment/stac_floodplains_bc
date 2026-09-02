## Outcome

Every full catalogue release is now a git tag. `catalogue_release.sh` refuses unless HEAD is
exactly at a `vX.Y.Z` tag, the tracked tree is clean and the tag's own `NEWS.md` opens with that
version; it stamps `collection.json` with the STAC Version Extension (`collection_version.py`,
stdlib) before the validation gate and fails unless both the API and the bucket serve the
version back. `--only` never stamps and must leave the live version unmoved. The stamp is
release-time rather than build-time (the issue proposed build-time from `git describe`) because a
version means "the published catalogue is in this state", the rebuild precedes the tag in every
real flow, and a tagless clone would otherwise publish a fallback. `05_stac_register.py` became
`item_create.py`. `NEWS.md` opens the release record; v1.0.0 was cut on the NEWS commit, released
from it, and pushed only after RELEASE COMPLETE. What was learned: the two real defects the review
rounds found were one class — a gate reading a *proxy* for its subject (the working-tree NEWS.md
rather than the tag's; git's preferred tag rather than the release tag) — and both were invisible
to a harness whose fixture could not reach them until a case was written for each.

## Measurement

Full rebuild 7.5 min (20 items, 861 MB tree). Release 5.1 min: 726.9 MiB of assets + 106.9 MiB
of JSON uploaded, 161 objects across all 20 item prefixes — so the 19 items published before
#26/#33/#34/#35 were genuinely republished, not skipped. Live API before: `version` MISSING, no
extensions; after: `1.0.0` with the Version Extension, 20 items, bucket copy agreeing. Harness:
7 cases → 15 cases; four restored defects (verify compare removed, stamp removed, NEWS read from
disk, `describe` without `--match`) each turn it red. Validator half-stamp check proven on the real
tree in four states.

## Evidence

Release and rebuild logs were session scratch (`rebuild.log`, `release.log`), summarised in
`progress.md`; the live acceptance reads are recorded there verbatim. Review rounds:
`review-round1.md` … `review-round3.md` in this directory.

Closed by: PR for #19 (branch `19-versioned-catalogue-releases-stac-versio`), tag `v1.0.0`.
