# Findings — Collection publishes license: proprietary (#47)

## Measurements taken before planning (2026-09-03)

All read from the producers themselves, not from the issue body.

| fact | source |
|---|---|
| `io-lulc-annual-v02` is `CC-BY-4.0`; licence link `https://creativecommons.org/licenses/by/4.0/`; providers Esri `[licensor]`, Impact Observatory `[processor, producer, licensor]`, Microsoft `[host]`; temporal 2017-01-01 → 2024-01-01 | `GET planetarycomputer.microsoft.com/api/stac/v1/collections/io-lulc-annual-v02` |
| `mrdem-30` is `OGL-Canada-2.0`; no `providers`, no licence link | `GET datacube.services.geo.ca/stac/api/collections/mrdem-30` |
| Live collection: `license: proprietary`, `providers: null`, `sci:citation: null`, `version: 1.0.0`, link rels served = `items/parent/root/self/queryables` only | `GET images.a11s.one/collections/stac-floodplains-bc` |
| Sibling `stac-elevation-bc` serves `providers` **and** `keywords` intact; our own collection serves `version` (an extension field) | `GET images.a11s.one/collections/...` |

## A `rel: license` link survives pgstac — measured, not assumed

The local build publishes **23** `rel: item` links and the API serves **none** of them,
which reads at first as "pgstac drops stored collection links". It does not. From
stac-fastapi-pgstac `stac_fastapi/pgstac/models/links.py`:

```python
INFERRED_LINK_RELS = ["self", "item", "parent", "collection", "root", "items", "child"]
...
links += [{**link, "href": self.resolve(link["href"])}
          for link in extra_links if link["rel"] not in INFERRED_LINK_RELS]
```

`core.py` passes `get_links(extra_links=collection.get("links"))`, so any rel *outside* that
list is kept and its href resolved through `urljoin(base_url, href)` — which returns an
absolute `https://` href unchanged. `item` is in the list; `license` and `derived_from` are
not. So both new links reach the API.

This is reasoning about source, not a measurement of *this* deployment — which is exactly
why Phase 4 reads them back from the live API after the release. `rel: license` is the
least-attested of the three fields we add, because links go through `get_links()`, a
different code path from the stored `content` blob that carries `license` and `sci:citation`.

## What pystac actually catches — measured, after getting it wrong

**The first version of this section was wrong**, and it is worth keeping the error: it said
the scientific extension's Collection branch has an `anyOf` arm requiring only `summaries`,
which our collection has, so declaring the extension with zero `sci:` fields would validate
clean. That came from a schema dump truncated mid-word at `"summ`, reasoned from rather than
measured. Arm 3 is `{"required": ["summaries"], "properties": {"summaries": {"$ref":
"#/definitions/require_any_field"}}}` — it requires a `sci:` key **inside** `summaries`, and
ours carries `scenario`/`species`/`region`/`flood_factor`.

The restore-the-bug run is what caught it. The case that dropped `sci:citation` while keeping
the extension fired **pystac's schema error**, not the guard's own message — which is only
visible because each proof greps for its own message rather than for exit 1.

Measured against the real collection, all five states:

| state | pystac | guarded here |
|---|---|---|
| extension declared + `sci:citation` present | passes | — |
| extension declared, `sci:citation` dropped | **rejects** | belt-and-braces |
| `sci:citation` present, extension not declared | passes | **yes** |
| neither present | passes | **yes** |
| extension + `sci:citation` of `"x"` | passes | **yes** |

So pystac covers exactly one of the four defect states. The schema is selected *by* the
extension list, so it can never see a field published without its extension; and where it
does look, `sci:citation` is only `type: string`, so no schema can tell a correct attribution
from a wrong one. That is what makes the verbatim comparison load-bearing rather than
belt-and-braces.

The proof for the biconditional was retargeted accordingly: the reachable mutation is the
direction pystac cannot see — keep the field, drop the declaration.

## The build tree already holds #26

| | |
|---|---|
| local items | 23 |
| live items | 20 |
| live-but-not-local (orphans) | **none** |
| local-but-not-live | `lnth_ch_ff04`, `thom_ch_ff04`, `unth_ch_ff04` |
| local items carrying a non-null `nge:` value | **21** of 23 |
| distinct `(landcover_source, landcover_collection, landcover_stac_url)` | 21 × `('io-lulc', 'io-lulc-annual-v02', 'https://planetarycomputer.microsoft.com/api/stac/v1')`, 2 × all-null |

So `PROVENANCE_FLOOR=21`, no `--allow-retract` is needed, and the premise assertion in
Phase 2 must treat a **null** `nge:landcover_collection` as legal — 2 items legitimately
carry none, and failing on them would be a guard that fails toward abort.

## Sibling licensing precedent

`stac_dem_bc/LICENSE` and `stac_uav_bc/LICENSE` are both MIT (21 lines,
`Copyright (c) 2025 Allan Irvine`), while their collections publish `CC-BY-4.0`. So the
established split is **code MIT, published data CC BY** — the repo `LICENSE` covers the
scripts, the collection's `license` field covers the products. The issue body asked for
CC BY 4.0 as the repo `LICENSE`; the user chose the sibling-consistent split instead.

`stac_dem_bc/scripts/collection_patch.py` exists for precisely this reason upstream — its
docstring says *"providers — CC-BY-4.0 obliges attribution and the collection carried none."*
It publishes `New Graph Environment` (no `Ltd.`); we publish the legal entity name here per
the issue, so the two collections on one endpoint will differ until `stac_dem_bc` follows.

## Why the literals are duplicated across item_create.py and item_validate.py

`item_validate.py:68-71` gives two reasons for duplicating `REQUIRED_NGE_PROPERTIES` rather
than importing. Only one carries here:

- *"importing that module would run the entire build"* — **still true**, and stronger than
  the comment says: `item_create.py` raises `SystemExit` at module level when nothing is
  staged, and writes 24 files as an import side effect.
- *"derived from the data, a value that vanished would take the expectation with it"* —
  **does not apply**. `license`, `providers` and the citation are literals, not derived.

The decisive reason is a third one: if both sides read one shared constant, the guard
degenerates to `x == x` — a round-trip through our own assignment, which returns identical
forever. Duplication only works because the assertions are **full equality**; token
containment would let the two copies drift arbitrarily far while staying green.

## Plan-agent review (concurrent, pre-baseline)

Eight substantive findings; the load-bearing ones were verified against the tree before
being folded into the plan. What changed:

| finding | change |
|---|---|
| citation guard was token-containment | → full string equality. A bag of words (`"Impact Observatory Esri CC BY 4.0 ..."`) passes containment while attributing nothing |
| providers guard was a `(name, roles)` projection | → full dict compare + `len() == 6`. The projection is blind to a duplicate entry (a set cannot see a repeat) and to a stripped or wrong `url` |
| extension/field check was one-directional | → biconditional, matching `check_version_stamp` |
| placement "after the count check" | → in-loop, before the stamp check. After the count check puts it behind `check_checksums`' 670 MB re-read, which short-circuits it |
| step-5 API check would be tautological in the harness | → three negative `FAKE_LIVE_*` cases. The curl shim serves the fixture back from disk; the harness names this trap itself at lines 42-44 for the version gate |
| nothing tied the citation to the data | → the premise assertion on `nge:landcover_collection` |
| bucket copy unchecked | → mirror the read-back on S3, same argument the file already makes for `version` |
| my own figure of "20 published item links" | → **23**. Corrected |

Its finding that a hand-edit of `collection.json` proves only the validator (rfp#243,
"guard the chooser") is why Phase 3 mutates the constant in `item_create.py` and rebuilds.

## Why the release harness needed negative cases, not just a fixture update

`catalogue_release-check.sh` shims `curl` to serve `$STAC_DIR/collection.json` straight back
from disk. So the new step-5 assertion "the API serves CC-BY-4.0" passes in the harness for
the same reason case 2's version assertion does — the shim is handing back the file the
release just stamped. The harness names this trap about itself at lines 42-44:

> Case 2's "live version 9.9.9 verified" is tautological on its own — the curl shim serves
> the stamped fixture back — which is why cases 8 and 9 exist: they are what prove the
> compare bites.

Cases 9c-9f are the 8-and-9 for the licence. `force_version()` generalised to
`force_fields()`, with `FAKE_LIVE_LICENCE` / `FAKE_BUCKET_LICENCE` breaking exactly **one**
field per case: a case that broke all three could pass on the strength of any one of them
and would not show the compare bites per field. The three are also lost by different
mechanisms — `license` and `sci:citation` ride in the stored document, while the link is
rebuilt by pgstac's `get_links()` — so the link case is the one modelling the real risk.

## Code-check round 3 — the fix was right, my explanation of it was not

Round 3 corrected round 2's *reasoning*, which had also been mine. I claimed the
`built-has-no-*` arms closed the both-absent hole. They do not. Measured over all 16 absence
states (served x built, citation x link), removing all three arms changes **no verdict**: what
refuses every absence, both-absent included, is the `is None` arm on the SERVED side. The
built-side arms only change which side the message accuses.

They are worth keeping for exactly that — "the build never published it" sends you to
`collection.json`, "the API dropped it" sends you to pgstac, and a release log naming the wrong
one costs an investigation in the wrong place — but the comment now says that instead of
claiming a detection role it does not have.

**The harness had no fixture for the state round 2's fix was about.** Every licence knob mutates
the *served* side; `$STAC/collection.json` was never touched, so the both-absent case was
unreachable and nothing pinned those arms. Case 9j mutates the built side. Verified to
discriminate rather than assumed.

| finding | verdict | action |
|---|---|---|
| `built-has-no-*` comments claim a detection role the arms do not have | **real, measured** | comments corrected to what the arms actually do |
| no fixture mutates the BUILT side | **real** | case 9j; harness 97 → 100 assertions |
| `scripts/README.md` step-1 row, `CLAUDE.md`, `NEWS.md` still say the premise checks the collection id only | **real** | all three name `nge:landcover_stac_url` too |
| the summary line reads as a conjunction; null-tolerance is per property | **real, wording** | reworded to "no item ... contradicts", each independently |

### On convergence — what is closed and what is not

Round 3 was asked to *show* convergence rather than assert it, since this repo's conventions
record that "this is now terminal" is wrong in the reassuring direction silently.

**Closed, and shown:** the `licence_of` silent-pass class. The candidate set is the four fields
the function reads, enumerated from its AST rather than by eye; all 12 absence states plus the
differs cases were executed; zero pass.

**NOT closed:** "a comment or a printed line claims something the code does not do." Four rounds,
four instances, each one sitting inside the previous round's fix:

| round | the false claim |
|---|---|
| pre-review | "the scientific extension validates with zero `sci:` fields" (caught by a proof firing the wrong guard) |
| 1 | step 5 "reads all three back" — it checked presence, not value |
| 2 | `built-has-no-*` "closes the both-absent hole" — it does not |
| 3 | three doc surfaces describing the premise guard as checking one property of two |

There is no enumeration for that class and it should not be treated as terminal. The cheapest
mitigation found so far is the one that caught the first instance: make the proof grep for the
message it expects, so a claim that has drifted from the code shows up as the wrong guard firing.

## Code-check round 2 — a defect inside round 1's fix

Exactly the shape `code-check.md` predicts ("a blocker sitting inside pass 1's blocker fix").
Round 1 replaced `licence_of`'s presence checks with value comparisons; the new version applied
`built-has-no-<rel>-link` reasoning to both links and **not** to the citation, so a citation
absent on *both* sides compared equal and step 5 would print "sci:citation and both links
served as published" about a field existing nowhere.

Closed with a three-way branch, proved both ways:

| input | result |
|---|---|
| citation absent on both sides | `BAD built-has-no-citation` (was `OK`) |
| citation absent on the served side only | `BAD sci:citation-absent` |
| unchanged | `OK` |

Splitting `absent` from `differs` also fixed a second thing the reviewer flagged: harness cases
9d (dropped) and 9g (altered) had been asserting the *same* string, so a release log could not
tell the two apart. They now assert different ones.

Two documentation corrections came with it — `CLAUDE.md` and `scripts/README.md` still described
step 5 as checking "all three" by presence, and `item_validate.py`'s summary line named only one
of the two properties `check_citation_premise` now checks. A summary that overstates or
understates what ran is the same class of problem as a guard that does.

The reviewer also confirmed, by restoring round 1's presence-only `licence_of` in a scratch copy
and re-running the harness, that cases **9g/9h/9i go red** while 9c-9f stay green — so the new
cases genuinely reach the altered mode the delete-only cases could not.

## OPEN — the pgstac link premise is still unmeasured against this deployment

`license` and `derived_from` surviving `get_links()` is read from stac-fastapi-pgstac's source
(`INFERRED_LINK_RELS`), not measured against `images.a11s.one`. No collection there publishes a
`rel: license` link today, so there is no positive evidence either way — `providers` and
`version` do round-trip, which is encouraging but is a different code path.

If the deployed version drops them, **the first full release finds out at step 5 — after the
sync and after the pgstac load**. The release then reports RELEASE INCOMPLETE with the assets
already on S3 and the collection already registered. Bucket versioning is Suspended, so that
state is repaired forward, not rolled back.

Cheap de-risking before the release, if wanted: `--skip-sync` against a throwaway collection id,
or simply register the collection and `curl` it. Not done here — it touches live
infrastructure, and Phase 6 is the operator's call.

## Code-check round 1 — the presence-vs-value hole

The reviewer's first finding was the most valuable of the change, and it was a guard failing
toward pass in the one place the whole feature turns on. `licence_of()` checked the licence
**link** for `rel` presence and `sci:citation` for non-emptiness, comparing only `license` by
value. Reproduced before fixing, against the real collection:

| served collection | old `licence_of` |
|---|---|
| `rel: license` href rewritten to `images.a11s.one/collections/creativecommons.org/...` | **OK** |
| `sci:citation` replaced with `"Copyright New Graph. All rights reserved."` | **OK** |
| `rel: derived_from` link removed entirely | **OK** |

Step 5 exists precisely because publishing a field is not serving it — and href rewriting
through `urljoin` is the *one* transformation pgstac performs on a link it keeps. The guard
was blind to it.

Fixed by comparing the served collection to the **published** one field by field. That is not
a round-trip through our own assignment: the published copy is the pipeline's input, and
`item_validate.py` already gated it verbatim against its own independently written literal
before a byte was synced. `license` stays compared to the constant too, since it is the field
a consumer's rights actually turn on. `built-has-no-<rel>-link` is in there because a link
absent from *both* sides would otherwise compare equal and go quiet.

The paired fixture gap was real too: cases 9c-9f only ever **deleted** a field, so the harness
could not reach the altered mode that the bug lived in. Cases 9g-9i cover it — an altered
citation, a rewritten href, and a dropped `derived_from`.

| finding | verdict | action |
|---|---|---|
| `licence_of` checks presence, not value | **real, reproduced** | compare served against published, field by field |
| `rel: derived_from` never read back | **real** | included in the read-back |
| `check_citation_premise` docstring overclaims ("Esri-hosted variant") | **real** | now checks `nge:landcover_stac_url` too, which is the half a host move would break; docstring corrected |
| the neither-present state reports "does not match verbatim" | **real** | named separately, with the remedy that actually applies |
| `EXPECT_LICENSE` has no shape premise | **real** | pinned in the harness as a bare literal, proved to fail when an env fallback is introduced |
| read failure prints a second, false line | **real, low** | `READFAIL` sentinel with its own case arm |

Nothing was dismissed as a false positive.

## Restore-the-bug results — 8 of 8

Each mutation applied to the **source** (`item_create.py`, or `meta.json` for the premise),
rebuilt, then validated, with the output grepped for **that guard's own message**. The
mutation is asserted to have taken first — `old not in text`, not `new in text`, since
`"".count()` is non-zero and the deletion case is the one that most needs the assertion.

| mutation | message matched |
|---|---|
| `COLLECTION_LICENSE` → `"proprietary"` | `collection license is 'proprietary', expected 'CC-BY-4.0'` |
| a seventh provider duplicating Esri | `collection carries 7 provider(s), expected 6` |
| Esri's `url` removed | `providers missing or altered: Esri` |
| the `rel: license` link renamed | `expected exactly 1 rel='license' link, found 0` |
| one word of `CITATION` changed | `sci:citation does not match the expected attribution verbatim` |
| `DERIVATION_STATEMENT` dropped from the description | `missing the derivation/modification statement` |
| `stac_extensions` dropped, `sci:citation` kept | `scientific extension half-applied: extension absent, sci:citation present` |
| `meta.json` landcover collection → `io-lulc-annual-v03` | `nge:landcover_collection is 'io-lulc-annual-v03'` |

Row 7 is the retarget. Its first form — drop the field, keep the extension — came back
`*** WRONG GUARD`, because pystac rejects that state before the guard runs. See above.

## The three hand-typed copies of the citation agree

The attribution exists in three places by design — `item_create.py` (published),
`item_validate.py` (the expectation) and `README.md` (human-readable) — each typed
independently rather than copied, so that agreement is evidence rather than a duplicate of
one mistake. All three matched on first comparison:

- `item_create.py` vs `item_validate.py`: byte equality, asserted on every build by
  `check_collection_metadata`. Green on the first validator run.
- `item_create.py` vs `README.md`: compared once by hand, stripping the blockquote markers,
  backticks and autolink brackets — identical. **Not guarded**: the README is prose, not
  published metadata, and a drift guard over rendered markdown would be more machinery than
  the risk warrants. The collection is the authority, and the README says so.

## The proof harness reverts the file it mutates

`prove.py`'s `restore()` runs `git checkout HEAD -- scripts/item_create.py` after every case,
so any hand edit to that file made *while the run is in flight* is silently reverted the next
time a case ends. It happened once here: the corrected comment about what pystac catches was
written mid-run, and the next `restore()` took it out.

Cost nothing because the sweep for the old wording found it, but it is the "do not edit files
a long run is reading" rule with a sharper edge — this run does not merely *read* the file, it
writes a known-good version over it. Edits to a mutated file wait for the run to finish.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `stat -f '%Sm' -t '%FT%TZ' file` printed filesystem info, not mtime | `stat` on this machine resolves to **GNU coreutils**, not BSD — `-f` is `--file-system` there, and the format string became a filename argument. Use `ls -l --time-style=full-iso`, or `command stat -c`. The BSD form is what macOS documentation shows, so the snippet reads correctly and does the wrong thing |
| An assertion that the mutation took was vacuous for the deletion case | `path.read_text().count(new) >= 1` with `new = ""` is always true — `"".count()` returns `len+1`. Asserted `old not in text` instead, which is meaningful for every case including the one that most needs it |
