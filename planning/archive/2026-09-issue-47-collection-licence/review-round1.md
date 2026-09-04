# Review round 1 — #47 licence + attribution

Reviewed the **working tree** (the branch has staged-but-uncommitted corrections that
`main..HEAD` does not show — e.g. the pystac table in `item_validate.py` is already the
corrected four-state one, so the stale "all four pass" claim is *not* present anywhere).

What I ran, so the negatives below mean something:

- `bash scripts/catalogue_release-check.sh` → **ALL PASS**, exit 0 (cases 9c–9f included).
- `uv run --no-sync python -c "print('uv ok')"` → ok, so `license = "MIT"` (PEP 639 string
  form) does not break the env. `[tool.uv] package = false`, so nothing builds it.
- AST-extracted the duplicated literals from both files and compared:
  `CITATION == EXPECTED_CITATION`, `DERIVATION_STATEMENT == EXPECTED_DERIVATION_STATEMENT`,
  `PROVIDERS == EXPECTED_PROVIDERS`, and all three of licence / licence href / derived-from
  href — **all True**. The three-copy design is currently in agreement.
- Counted the build: 23 `meta.json`, 23 items, **21** carrying a non-null `nge:` value.
  `PROVENANCE_FLOOR=21` is the right literal.
- Probed `check_collection_metadata` against mutated real documents, and `licence_of`
  against a mutated real `collection.json` (details in the findings).

---

## Findings

### [fragile] scripts/catalogue_release.sh:135–149 (`licence_of`) — presence-only on the two fields whose failure mode is *alteration*, not absence

`licence_of` compares `license` by value, but the licence **link** only by `rel` presence
and `sci:citation` only by non-emptiness. Measured, feeding the real
`data/stac/collection.json` through the exact `python3 -c` body with two mutations:

```
links[license].href -> "https://images.a11s.one/collections/creativecommons.org/licenses/by/4.0/"
sci:citation        -> "Copyright New Graph. All rights reserved."
licence_of says -> OK   (rc 0)
```

So the release completes green while the API serves a licence link that resolves nowhere
and a citation that asserts the opposite of CC BY.

This matters more than a generic tightening, because it is the *stated purpose* of the
step. `item_create.py:566–571` and the new CLAUDE.md paragraph both say the `urljoin`
behaviour is "read from its source, not measured here, which is why
`catalogue_release.sh` step 5 reads all three fields back from the live API" — but the
one transformation pgstac performs on a surviving link is exactly a **href rewrite**, and
`licence_of` cannot see it. A reasoned claim is being cited as measured by a guard that
structurally cannot measure it (`code-check.md`, "A proxy is not the property").

Same shape for the citation: it is the field carrying two U+2013 en dashes, i.e. the one
most exposed to a serialiser/encoding round-trip, and it is checked for length only.

The expected values already exist as literals in `item_validate.py`
(`EXPECTED_LICENSE_HREF`, `EXPECTED_CITATION`), and the file already accepts a third
hand-typed copy (`EXPECT_LICENSE`) as the design. Two more argv parameters closes it.

Paired fixture gap: `catalogue_release-check.sh` case 9e only **deletes** the link and 9d
only **deletes** the citation. Neither fixture can reach the altered-value mode, so the
harness cannot report this (`code-check.md`, "A fixture that cannot reach the failure
mode"). A 4th knob (`lic == "href"` → rewrite the href; `lic == "text"` → replace the
citation) would.

### [fragile] scripts/catalogue_release.sh — `rel: derived_from` is asserted on disk and never read back

`check_collection_metadata` pins the `derived_from` href exactly. CLAUDE.md asserts, from
reading pgstac's source rather than from measurement, that "`license` and `derived_from`
fall outside that set and survive". Step 5 reads back `license` (value), the `license`
link (presence) and `sci:citation` (presence) — **`derived_from` is not read back at
all**, from the API or the bucket. So the half of the reasoned claim that names two links
is evidenced for one of them. One extra clause in `licence_of`, and the CLAUDE.md sentence
"step 5 reads all three back" already reads as though it covers this.

### [fragile] scripts/item_validate.py:246–263 — `check_citation_premise`'s docstring claims coverage its predicate does not have

> Nothing else here would notice if `drift` moved upstream to io-lulc-annual-v03, **or to
> an Esri-hosted variant on different terms**

The guard compares `nge:landcover_collection` only. A move to a different host serving the
same collection id — precisely the "Esri-hosted variant" the docstring names — passes.
The discriminating fact is already on every item and already in the required contract:
`nge:landcover_stac_url`, non-null on all 21 provenanced items and uniformly
`https://planetarycomputer.microsoft.com/api/stac/v1` (measured), and the published
citation asserts "accessed via Microsoft Planetary Computer" in so many words.

This is `code-check.md`'s "An assertion that matches an interpolated value cannot see the
claim around it", applied to a docstring: the predicate is sound, the sentence describing
it is not, and a reader takes the sentence as the contract. Either add the second
comparison in the same loop (same null-tolerant shape) or narrow the sentence.

### [fragile] scripts/item_validate.py:224–233 — the "neither present" state reports a remedy that walks back into a different guard

Measured on the real collection, dropping both `sci:citation` and the extension
declaration:

```
neither present -> ['sci:citation does not match the expected attribution verbatim']
```

The `elif` means the missing declaration is never named. An operator reading that message
adds `sci:citation` back, re-runs, and now trips the *half-applied* arm — one release
round-trip per half, on a guard whose own docstring justifies returning every problem so
that "a caller that reported one of them per run would cost a release round-trip per
defect". `code-check.md`, "A guard that fires correctly and then points at the wrong fix".

Detection is correct in every state (the comment table's claim holds); only the message is
wrong. Making it `if` rather than `elif`, or naming the absent declaration in the
value-mismatch branch, fixes it.

### [fragile] scripts/catalogue_release.sh:66 — `EXPECT_LICENSE` has no shape premise, unlike `PROVENANCE_FLOOR` three lines above it

`PROVENANCE_FLOOR` is pinned by an anchored sed in the harness (line ~300) with the
rationale written out: "a `${PROVENANCE_FLOOR:-0}` rewrite of the literal reads as an
empty premise rather than a passing compare". `EXPECT_LICENSE` is the same kind of
human-set literal, and it is now the *only* value comparison step 5 makes — yet it carries
no such pin. A later `EXPECT_LICENSE="${EXPECT_LICENSE:-CC-BY-4.0}"` would hand step 5 an
env escape hatch, and the harness would stay green (verified by inspection: `run_release`
sets no such variable, so case 2 and 9c both behave identically under the override form).
One line mirroring the existing premise assertion.

### [low] scripts/catalogue_release.sh:606–621 — the read-failure path emits a second, false line

On `curl` failure the handler sets `live_licence="BAD read-failed"`, then the `case`'s
`*)` arm prints *"the API is not serving the licence this build published: read-failed"*.
A transient network failure is therefore also reported as the API serving the wrong
licence. "Could not read" does stay distinguishable — the first line is emitted and only
on that path — and the existing version check has the same shape, so this is consistency
rather than regression. Worth a `continue`-style guard or a sentinel the `case` matches
explicitly, at some point.

---

## Answers to the specific questions

**1. Can `check_collection_metadata` / `check_citation_premise` pass on input they should
refuse?** No input found for `check_collection_metadata` beyond one harmless
normalisation. The count-plus-set pair does correctly catch a duplicated provider
(6 entries with Esri twice and Microsoft dropped → `providers missing or altered:
Microsoft`), a stripped `url` (probed: `rel='license' link points at
'https://evil.example/'…`), and the neither-present citation state. The one input that
compares equal when it arguably should not is a provider whose `roles` repeat a value
(`["licensor","licensor"]` → `[]`, measured), because `frozenset` collapses it — that
cannot publish a false attribution, so I am not counting it. The real gap is
`check_citation_premise`, above.

Two structural notes in its favour: `check_citation_premise` runs **after** the
`items != expected` floor, so the "loop over an empty set exits 0" hazard cannot fire;
and `failed.extend((path.name, p) for p in coll_problems)` does not shadow `main`'s
`p = ArgumentParser` (genexp scope), which was worth checking.

**2. Is step 5 correct under `set -euo pipefail`?** Yes, traced all three ways:

| input | what happens |
|---|---|
| `curl -sf` fails (connection or ≥400) | empty stdin → `json.load` raises → exit 1; `pipefail` makes the substitution non-zero → `\|\|` handler → *"could not read…"*, `fail=1` |
| 200 with a non-JSON body | `curl` exits 0, python raises → same handler, same message |
| valid JSON missing fields | python exits **0** printing `BAD …` → `case *)` → *"the API is not serving…"*, `fail=1` |

`set -e` is not tripped: the `||` suppresses it, and the `{ …; fail=1; }` group's last
statement returns 0. "Could not read" and "served wrong" stay distinguishable by the first
line, with the caveat in the `[low]` finding that the second line also prints on a read
failure.

**3. Do 9c–9f exercise what they claim, and is `force_fields` correct?** Yes, and the
whole harness is green (I ran it). `force_fields` takes three args at both call sites,
still handles `none` for the version, and `elif lic: raise SystemExit` makes a typo'd knob
loud rather than a silent no-op. The cases follow the #46 discipline correctly — each
greps for **its own guard's message**, not merely exit 1, so a run failing at some earlier
step cannot read as a pass. Isolation is right: `FAKE_LIVE_LICENCE` does not touch the
version or the id list, so preflight and the version compare are unaffected and step 5 is
demonstrably where each one lands. The fixture change breaks nothing pre-existing — case
12's `coll_hash` is computed at runtime, nothing else reads the collection's `links` or
`license`, and case 2's positive control now pins both new lines. The gap is the one in
finding 1: every negative case models *loss*, never *alteration*.

**4. Anything failing toward pass / silent success?** Finding 1 is the one that reaches a
published state: a served collection with a wrong licence link and a wrong citation
completes the release green. Findings 2, 3 and 5 are scope/escape-hatch gaps rather than
live failures; finding 4 is a message-only defect.

## Verified, not findings

- `PROVENANCE_FLOOR=21` matches the build (23 items, 21 with values, 23 staged
  `meta.json`) and is exact in both directions as #32 requires.
- `collection_version.py` **appends** to `stac_extensions`, so the release-time stamp
  cannot displace `SCIENTIFIC_EXT` and trip the biconditional. Confirmed by reading it and
  by case 2 passing after the stamp.
- The three hand-typed copies of every literal currently agree byte-for-byte (AST compare).
- `--skip-sync` still `aws s3 cp`s `collection.json` on a full release, so the new bucket
  read-back is satisfiable on that path; no new bypass was opened.
- `--only` correctly skips the licence read-back and never stamps.
- `licence_of` takes the expected value through argv rather than string interpolation, as
  its comment says; there is no quoting hazard in it.
