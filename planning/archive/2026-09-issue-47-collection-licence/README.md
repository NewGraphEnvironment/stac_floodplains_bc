# #47 — Collection publishes `license: proprietary`

Merged as [PR #51](https://github.com/NewGraphEnvironment/stac_floodplains_bc/pull/51),
merge commit `40299f9`, 2026-09-04.

The collection served `"license": "proprietary"` — a restriction we do not hold — with no
`providers` and no citation, while the published products are a derivative of Impact
Observatory's `io-lulc-annual-v02` (CC BY 4.0), delineated off MRDEM-30 (OGL-Canada-2.0) and
the BC Freshwater Atlas (OGL-BC). All three oblige credit; none is share-alike, so CC BY 4.0
outbound is permitted. The collection now publishes `license: CC-BY-4.0`, six `providers`, a
`rel: license` and a `rel: derived_from` link, `sci:citation`, and the CC BY §3(a)(1)(B)
statement that the input was modified. The repo carries an MIT `LICENSE` for the scripts —
two licences over two different things, matching `stac_dem_bc` and `stac_uav_bc`.

**Left open deliberately.** #47 was merged with `Relates to`, not `Closes`: its own
Verification is a read of the live API, and until the catalogue is republished the collection
still serves `proprietary`. Its **Phase 6 — cut the release — transferred to #26**, which
owns the publish. #47 closes when the catalogue is published, not when the code landed.

## Measurement

Nothing here is a performance number; the measurements are all about what a consumer is
actually served, and two of them changed the design.

- **`rel: license` survives pgstac, `rel: item` does not.** `INFERRED_LINK_RELS` in
  stac-fastapi-pgstac is `[self, item, parent, collection, root, items, child]`; `get_links()`
  keeps every other rel and resolves its href through `urljoin`. That is why the build's 23
  `rel: item` links are served as none. Read from source — **still unmeasured against
  `images.a11s.one`**, since no collection there publishes such a link. The release is what
  settles it.
- **pystac covers one of four defect states** for the scientific extension, not zero as an
  earlier reading claimed. It refuses the extension declared with no field; it cannot see a
  field published without its extension, cannot see both absent, and cannot check the
  citation's content at all. Turned a false premise in three files into a table.
- **A presence check is not a value check**, measured against the real collection: the
  original step-5 guard answered `OK` for a licence link whose href had been rewritten, for a
  citation reading "Copyright. All rights reserved.", and for a missing `derived_from` link.
  This was the single most valuable finding of the change — the guard existed to catch pgstac
  mangling a link, and href rewriting is the one thing pgstac does to a link it keeps.
- **`built-has-no-*` arms change no verdict** across all 16 absence states; the served-side
  `is None` arm is what refuses. Two rounds of reasoning were wrong about the code they sat in.

## Evidence

- `findings.md` — the measurement record, including the three false claims and how each was
  caught
- `review-round1.md` / `review-round2.md` / `review-round3.md` — 14 findings, all fixed, none
  dismissed. Round 2's best finding sat inside round 1's fix; round 3 corrected round 2's
  explanation of its own fix
- 8 of 8 validator guards proved by mutating the source and grepping for each guard's own
  message. One came back `*** WRONG GUARD` and was the most useful result of the day
- `scripts/catalogue_release-check.sh` went 90 → 100 assertions; case 9j proved to
  discriminate — against the pre-fix form it reports `RELEASE COMPLETE` while publishing a
  collection with no attribution at all

## The wrong turns worth keeping

Three, all of the same class and none visible by reading:

1. "The scientific extension validates with zero `sci:` fields" — written into three files
   from a schema dump truncated mid-word at `"summ`. Caught only because a restore-the-bug
   proof fired the *wrong* guard.
2. Step 5 "reads all three back" — it checked presence.
3. The `built-has-no-*` arms "close the both-absent hole" — they do not.

Each sat inside the previous round's fix. Round 3 closed the `licence_of` silent-pass class by
enumeration (AST-derived candidate set, all 12 absence states executed) and explicitly refused
to close this one. It should not be treated as terminal.
