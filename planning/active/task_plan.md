# Task: Collection publishes license: proprietary — it is a CC BY 4.0 derivative of Impact Observatory LULC and must say so, with providers + citation (#47)

The published collection must state its licence correctly and carry the attribution
CC BY 4.0 requires: the land-cover input is Impact Observatory's 10 m annual LULC
(`io-lulc-annual-v02`, via Planetary Computer), and the published products are derivatives
of it (clipped to the floodplain, cross-tabulated 2017 → 2023).

**Measured 2026-09-03 on the live API:** the collection serves `"license": "proprietary"`,
no `providers`, no citation, and the repo has no `LICENSE` file. That is wrong in both
directions — it claims a restriction we do not hold, and it omits the credit the source
licence obliges. The items' `nge:landcover_source` / `_collection` / `_stac_url` properties
exist but are null on every live item (#17 forward-only) and the API drops nulls, so from
the API the source is not named anywhere today.

**Decisions taken with the user:** `LICENSE` = MIT for the code, CC-BY-4.0 for the
published catalogue (sibling-consistent with `stac_dem_bc` / `stac_uav_bc`); provider name
is the legal entity **New Graph Environment Ltd.**; this PR cuts a release, which also
publishes #26's item remodel.

The scientific extension's Collection branch is an `anyOf` with an arm that requires only
`summaries` — which our collection has — so declaring the extension with **no** `sci:`
field validates clean. Every guard below is therefore absolute and hardcoded, never derived
from the artifact.

## Phase 1: Collection metadata in the build

`scripts/item_create.py` (the `pystac.Collection(...)` block, ~line 460).

- [ ] Add module-level constants beside the existing config: `COLLECTION_LICENSE = "CC-BY-4.0"`, `LICENSE_HREF`, `SOURCE_COLLECTION_HREF` (the PC `io-lulc-annual-v02` collection URL), `PROVIDERS`, `CITATION`, `SCIENTIFIC_EXT`
- [ ] `PROVIDERS` — six entries, roles for Impact Observatory / Esri / Microsoft copied from the source record rather than reasoned: Impact Observatory `[producer, processor, licensor]`; Esri `[licensor]`; Microsoft `[host]`; Natural Resources Canada `[producer, licensor]`; Province of British Columbia `[producer, licensor]`; New Graph Environment Ltd. `[processor, host]`. Every entry carries a `url`
- [ ] Set `license=COLLECTION_LICENSE` and `providers=[pystac.Provider.from_dict(p) for p in PROVIDERS]`
- [ ] Add a `rel: license` link (`type: text/html`, `title: CC BY 4.0`) and a `rel: derived_from` link to `SOURCE_COLLECTION_HREF` — the measured `INFERRED_LINK_RELS` finding means both survive to the API, so the attribution is resolvable and not merely stated
- [ ] Declare the scientific extension via `ScientificExtension.ext(collection, add_if_missing=True)` (not a literal in `stac_extensions=`) and set `sci:citation = CITATION`
- [ ] Extend the collection `description` with the derivation + **modification** statement CC BY 4.0 §3(a)(1)(B) obliges, and the one-sentence release-mixing caution the issue asks for
- [ ] Rebuild (`uv run python scripts/item_create.py`) and read `data/stac/collection.json` by eye

Draft `CITATION` and the description sentence land in `findings.md` for review before they
are hardcoded in two places.

## Phase 2: The validator guard

`scripts/item_validate.py`. House style is the `REQUIRED_NGE_PROPERTIES` block (lines
68–130): absolute, hardcoded, set-equality. **Duplicate Phase 1's literals rather than
importing them** — importing `item_create.py` runs the whole build (it `SystemExit`s at
module level and writes 24 files), and a shared constant would make the guard `x == x`.

- [ ] `check_collection_metadata(doc) -> list[str]` — a **list**, not `str | None`, so a wrong licence and wrong providers report together rather than one release apart
- [ ] `license` — string equality against the hardcoded value
- [ ] `providers` — read `doc.get("providers") or []` (pystac omits the key entirely for an empty list, so a presence gate would skip silently). Assert `len(...) == 6` **and** set equality over the **full provider dicts** with `roles` normalised to a frozenset. Not a `(name, roles)` projection: that is blind to a duplicate entry and to a wrong or missing `url`
- [ ] Links — exactly one `rel: license` with the exact href; exactly one `rel: derived_from` with the exact href
- [ ] `sci:citation` — **full string equality** against the hardcoded literal, not token containment. Containment passes for a bag of words that attributes nothing; equality makes drift a readable diff. Same for the description's modification sentence — a whole-substring literal, since a marker like `modif` is satisfied by a description saying *unmodified*
- [ ] Scientific extension declared **iff** `sci:citation` is present — the biconditional `check_version_stamp` already uses (`item_validate.py:60-63`); half a declaration is invisible to pystac in both directions
- [ ] **Premise assertion** (the one thing tying the literals to the data): every item whose `nge:landcover_collection` is non-null must equal the collection the citation names. Null stays legal — 2 items legitimately carry none. Without this, a `drift` move to `io-lulc-annual-v03` publishes a false licence claim with every guard green
- [ ] Wire it into the `Collection` branch of the loop **before** `check_version_stamp`, collecting both sets of problems and `continue`ing once. Placing it after the count check would put it behind `check_checksums`' 670 MB re-read, which can short-circuit it — the #46 failure mode exactly

## Phase 3: Restore the bug and prove each guard fires

Per the #46 row: **grep the output for the expected message, never just the exit status** —
this file now has many guards and each of them exits 1.

- [ ] Positive control first: clean tree, validator green, the new summary line prints
- [ ] Mutate the constant in **`item_create.py`**, rebuild, then validate — not a hand-edit of `collection.json`. A hand-edit proves only the validator; it stays green forever if the build never applies the constant (rfp#243, "guard the chooser")
- [ ] One proof per guard: licence value; a duplicated provider; a provider with its `url` stripped; a missing `rel: license` link; a reworded citation; a description with the modification sentence removed; extension declared with `sci:citation` dropped; an item's `nge:landcover_collection` set to `io-lulc-annual-v03`
- [ ] Record each as *mutation → message matched* in `findings.md`, and assert the mutation actually took before trusting the result

## Phase 4: Read the licence back from the consumer

The API is the only place that proves pgstac did not drop what we published — and
`rel: license` is the least-attested of the three fields, since links go through
`get_links()`, a different code path from the stored content blob.

- [ ] `catalogue_release.sh` step 5, **full release only**: one `python3` reader over the fetched collection printing a single token, `|| live_meta=""`, then a `case` — the `live_state` shape at lines 490–517, never `curl | grep -q` (under `pipefail` a failed fetch reads as a clean no-match)
- [ ] Assert the API serves `license == CC-BY-4.0`, a `rel: license` link, and a non-empty `sci:citation`; distinguish "served, wrong" from "could not read" the way `fetch_live_version` distinguishes `MISSING`
- [ ] Mirror it on the **bucket** copy beside the existing `bucket_version` check — rtj's `stac_register-all.sh` reloads from S3, so a licence that reached pgstac but not the bucket gets silently reverted. Same argument the file already makes for the version stamp
- [ ] `catalogue_release-check.sh`: the fixture collection (lines 103–105) gains `license`, `providers`, the two links and `sci:citation`, or cases 2/8/9/9b/14 start failing
- [ ] Add three **negative** cases via `FAKE_LIVE_*` knobs on the curl shim, generalising `force_version()`: API serves `proprietary`; API serves no `sci:citation`; API serves no `rel: license` link — each must give `RELEASE INCOMPLETE`. Without them the new step-5 check is tautological, because the shim serves the fixture straight back from disk — the harness names this trap itself at lines 42–44
- [ ] Update the numbered case list in the harness docstring, its "what this cannot see" note (the new validator guard never runs there — `uv` is shimmed), and the release-step table in `scripts/README.md`

## Phase 5: Repo licensing surfaces

- [ ] `LICENSE` — MIT, `Copyright (c) 2025 Allan Irvine`, byte-consistent with the two siblings
- [ ] `README.md` — an `## Attribution` section carrying the same sentence as `sci:citation`, and stating plainly that the **scripts** are MIT while the **published catalogue metadata and derived products** are CC BY 4.0
- [ ] Record the outbound-licence reasoning beside it: io-lulc is CC BY with no ShareAlike; both OGLs permit redistribution under our own terms given attribution; MRDEM contributes a delineation, not redistributed pixels. No guard can ever check that chain, which is why it is written down
- [ ] `pyproject.toml` — add the `license` field (a third carrier of the same fact today unset)
- [ ] Record the deliberate **no** on item-level `license`: STAC 1.0/1.1 inherit it from the collection, and #26's provenance floor is what keeps the per-item `nge:landcover_*` attribution non-null
- [ ] `CLAUDE.md` — a short paragraph under the collection model naming the licence, the providers and where the citation literal lives in two files and why
- [ ] `NEWS.md` — the release entry, naming both #47 and #26 with the floor `21` recorded beside it

## Phase 6: Cut the release (post-merge)

Publishes #47's metadata **and** #26's item remodel. No orphans, so no `--allow-retract`.
The first release after this must be **full**, not `--only`: a release machine holding a
`data/stac` built before Phase 1 will now be refused, correctly. The tag is cut by hand on
the `NEWS.md` commit once it is on main, as `stac_uav_bc` does.

- [ ] `PROVENANCE_FLOOR=21` in `catalogue_release.sh` — the literal count `01_stage.R` printed for this build, and the count measured above
- [ ] Full rebuild through `run_pipeline.sh`, then `item_validate.py` clean
- [ ] `NEWS.md` top entry names the version; tag `vX.Y.Z` by hand on that commit
- [ ] `bash scripts/catalogue_release.sh` — validate → sync (3 new items' assets + `collection.json`) → register → verify
- [ ] Confirm from the API, not from the release output

## Validation

- [ ] `bash scripts/catalogue_release-check.sh` green, including the three new negative cases
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
