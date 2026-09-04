# Review round 3 — #47, scoped to round 2's fixes

Reviewed the **working tree** (index == worktree: `git diff` is empty, `git diff --cached`
carries all 15 files). Everything below was measured, not read.

What I ran:

- `bash scripts/catalogue_release-check.sh` → **ALL PASS**, exit 0, 9.3 s.
- **Restored round 2's exact defect** (the citation arm as a bare value compare, which is what
  round 2 measured passing on both-absent) → **case 9d goes red on its own message**
  (`no 'sci:citation-absent' in output`), 9c/9e–9i stay green. So 9d does pin the new arm.
- **Deleted the whole step-5 licence block** → **17** assertions red, including case 2's two
  positive-control lines. The block as a unit is well pinned.
- **Deleted each `built-has-no-*` arm** (three of them, two separate runs) → **ALL PASS both
  times.** See finding 1.
- **Full absence truth table** for `licence_of`, over three program variants, with the field
  set enumerated from the function's own AST rather than by reading it (table below).
- Re-ran the **pystac five-state table** in `item_validate.py:87–95` against the real
  collection: all five rows reproduce exactly as written.
- Build measured: 23 items, `nge:landcover_collection` = `io-lulc-annual-v02` on 21 / null on 2,
  `nge:landcover_stac_url` = the Planetary Computer on the **same** 21, 21 carrying a non-null
  `nge:` value. `PROVENANCE_FLOOR=21` is exact in both directions. Collection: `CC-BY-4.0`,
  6 providers, both links at the expected hrefs, 770-char citation.
- `uv lock --check` clean, `uv.lock` unmodified.
- **README.md's quoted citation is byte-identical** to the published `sci:citation` after
  normalising the markdown blockquote (`> ` prefixes, backticks, the `<...>` autolink). A
  fourth copy that nothing checks, but it currently agrees.

---

## Findings

### [fragile] scripts/catalogue_release.sh:161 and :173–176 — the rationale round 2 added, and the one it copied, are both false about the code they sit in

The comment above the citation arm:

> Absent on BOTH sides compares equal, so without this the step reports "served as published"
> about a field that exists nowhere — the same hole the built-has-no-`<rel>`-link arm below
> closes for the links

and the one at line 161 it cites:

> `built-has-no-<rel>-link` matters: without it, a link absent from BOTH sides compares equal
> and the whole check goes quiet on the input that most needs it.

Neither is true of the function as written. Measured — the field set enumerated from the AST
(`served.license`, `{served,built}.sci:citation`, `href({served,built}, rel)` for
rel ∈ {`license`, `derived_from`}; note `built.license` is never read), then every absence
state run through three variants:

| state | current | built-arms removed | value-compare only (the true prior form) |
|---|---|---|---|
| control | PASS | PASS | PASS |
| `license` absent SERVED | refuse | refuse | refuse |
| `license` absent BOTH | refuse | refuse | refuse |
| citation absent BOTH | refuse | refuse | **PASS** |
| citation absent SERVED only | refuse | refuse | refuse |
| citation absent BUILT only | refuse | refuse | refuse |
| citation differs | refuse | refuse | refuse |
| `license` link absent BOTH | refuse | refuse | **PASS** |
| `license` link absent SERVED only | refuse | refuse | refuse |
| `license` link absent BUILT only | refuse | refuse | refuse |
| `derived_from` link absent BOTH | refuse | refuse | **PASS** |
| `derived_from` link absent SERVED only | refuse | refuse | refuse |
| `derived_from` link absent BUILT only | refuse | refuse | refuse |

The middle column is identical to the first in **every** state. The three `built-has-no-*`
arms change no verdict; they only change which side the message points at. What actually
closes the both-absent hole is the `elif served… is None` / `elif s is None` arm sitting
immediately below each of them — and either arm alone closes it (I checked both directions:
removing only `elif served is None` also refuses, via `built-has-no-citation`). They are
mutually redundant, which is fine; the comments asserting one of them is load-bearing are not.

Why it matters rather than being pedantry. Round 2's finding was argued from a comparison —
*"the link arm was added for exactly this reason and the citation arm was not"* — and that
comparison rests on a claim about the link arm that is false. The fix is harmless, but the
repo now carries two comments telling the next reader which arm is safety-critical, and
they name the wrong one. `code-check.md`, "An assertion that matches an interpolated value
cannot see the claim around it": the tell is a comment that says what something *is* rather
than naming it, and the predicate here is sound while the sentence is not.

Cheapest honest fix is to say what is true: the absence arms are redundant on purpose, either
one refuses, and the built-side one exists so the message points at the build rather than at
the API.

### [fragile] scripts/catalogue_release-check.sh — the both-absent state, which is the state round 2's fix is *about*, has no fixture; one is three lines and is discriminating

Every licence knob in `force_fields` mutates the **served** side only (the shim rewrites the
API/bucket response; `$STAC/collection.json` on disk, which `licence_of` reads as "built", is
never touched). So no case can reach any `built-has-no-*` arm — proved by deleting all three
and getting **ALL PASS**.

That is the answer to *"is there any assertion that would still pass if the guard it tests were
deleted outright?"* — there is no assertion for those three arms at all.

The load-bearing gap is not the arms (finding 1: they change no verdict) but the **state**.
Nothing pins "no citation anywhere → refused". The only thing standing between the prior
value-compare-only form and a green release is case 9d's *message* string, which is a proxy: a
plausible rewrite such as

```python
if served.get("sci:citation") is None and built.get("sci:citation") is not None:
    bad.append("sci:citation-absent")
elif served.get("sci:citation") != built.get("sci:citation"):
    bad.append("sci:citation-differs")
```

keeps 9d green and reopens the silent pass.

I built the fixture and proved it both ways. Inserted before case 10:

```bash
echo "case 9j: a BUILT collection.json with no sci:citation (absent from both sides) fails it"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("sci:citation",None); json.dump(d,open(sys.argv[1],"w"))' "$STAC/collection.json"
run_release
expect_eq "exit non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
expect_out "names the built-side absence" "built-has-no-citation"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sci:citation"]="fixture citation"; json.dump(d,open(sys.argv[1],"w"))' "$STAC/collection.json"
```

- against the current script: **both assertions pass**;
- against the value-compare-only form: **`exit non-zero` FAILS — the release completes green,
  `RELEASE COMPLETE`, publishing a collection that carries no attribution at all.**

That is the assertion the suite is missing. It works because `item_validate.py` is shimmed away
in this harness, so nothing upstream intercepts the mutated build.

**Reachability on a real release: none.** `check_collection_metadata` refuses a build with no
`sci:citation` in every state (round 2 proved this by mutation; I re-confirmed the pystac half
today), and step 1 gates step 5. So this is defence-in-depth being pinned, not a live hole —
same standing the link arms already have.

### [low] scripts/README.md:59, CLAUDE.md and NEWS.md still describe `check_citation_premise` as a one-property guard

Round 2's finding 3 corrected the step-**5** row and left every other surface. The code
(`item_validate.py:270–271`) now checks **two** properties; three documents name one:

- `scripts/README.md`, step 1 row: *"every item's `nge:landcover_collection` checked against the
  collection the citation attributes (#47)"*
- `CLAUDE.md`, new paragraph: *"it refuses a build whose items name a landcover collection the
  citation does not attribute"*
- `NEWS.md`, Unreleased: *"which refuses a build whose items name a landcover collection the
  published citation does not attribute"*

`nge:landcover_stac_url` is the half round 1 asked for precisely because a host move keeping the
collection id is invisible to the id check. A reader trusting any of the three would conclude it
is unguarded. `code-check.md`, "A fix that reaches one enforcement surface reads as complete on
all of them" — the same class round 2 named, one surface over.

### [low] scripts/item_validate.py:1390–1393 — the success line states a conjunction the code checks per-property

```
… every item's nge:landcover_collection is io-lulc-annual-v02 and its
nge:landcover_stac_url is the Planetary Computer, or null
```

`check_citation_premise` applies its null tolerance **per property** (`for prop, want in claims:
… if got is not None and got != want`), so an item with the collection set and the URL null
passes, and the printed sentence is false of that item — "or null" reads as governing the pair.
This is the operator's verdict line for a guard whose whole job is to keep a published legal
claim honest.

Not reachable in today's data (measured: both properties set on the same 21 items, both null on
the same 2, and both live in `PROV_SECTIONS["landcover"]`, so the producer writes them together).
Wording only; the code is right.

Separately, the same line omits the derivation-statement check `check_collection_metadata` also
performs (CC BY 4.0 §3(a)(1)(B)) — an undercount, harmless.

---

## Answers to the specific questions

**1. `licence_of`'s citation ordering — right? Can any pair collapse? Is the hole open
anywhere else?**

Ordering is right, and it is *insensitive* to ordering: the two absence arms are mutually
redundant, so either order refuses every absence state (measured, both orders). No pair
collapses to a pass — the truth table above has zero PASS cells outside the control.

The field set is complete, taken from the AST rather than from reading:

| field | absent SERVED | absent BUILT | absent BOTH |
|---|---|---|---|
| `license` | `BAD license=None` | not read from built at all — compared to the `EXPECT_LICENSE` constant, so built's copy is irrelevant here and is gated at step 1 by `item_validate.py`'s own `EXPECTED_LICENSE` | `BAD license=None` |
| `sci:citation` | `sci:citation-absent` | `built-has-no-citation` | `built-has-no-citation` |
| `links[rel=license].href` | `rel=license-link-absent` | `built-has-no-license-link` | `built-has-no-license-link` |
| `links[rel=derived_from].href` | `rel=derived_from-link-absent` | `built-has-no-derived_from-link` | `built-has-no-derived_from-link` |

**No cell is a silent pass.** `href()` folds "no link", "two links" and "link with no href"
into `None`, so all three refuse — with a message that says "absent" for a duplicate, which
round 2 already noted and which fails safe.

One field the function does **not** read: `providers`. Neither success line nor either
document claims it does, so this is scope, not a false claim — `check_collection_metadata`
pins all six as whole records on disk, and round 2 measured that a sibling collection's
providers do survive pgstac.

**2. Does `item_validate.py`'s reworded summary claim anything the code does not check?**
Yes, marginally — finding 4 (the conjunction). Everything else in the line is checked:
`license` by value, both links by exactly-one-plus-href, `len(EXPECTED_PROVIDERS)` providers
as whole records, `sci:citation` verbatim. The five-state pystac table the rewording rests on
reproduces exactly (measured today against the real collection, all five rows).

**3. Does 9d still exercise what it claims? Is any harness assertion stale or vacuous?**
9d exercises the `served is None` arm and is discriminating: restoring round 2's exact defect
turns its message assertion red while its `exit non-zero` assertion stays green — so the
message is the load-bearing half, which is the #46 discipline working. 9g's
`sci:citation-differs` is now a distinct string from 9d's, closing round 2's operator-ambiguity
note.

Nothing is stale. Nothing is vacuous in the sense of "passes on the broken code":

- `LICENCE_LITERAL` — the sed fails to `""` on a renamed variable, an inline `${…:-}` default,
  an unquoted value or a trailing comment, and `""` ≠ `CC-BY-4.0`, so it fails **loud** in every
  degradation I could construct. The stated limitation (a *separate later reassignment*) is
  real and is now written out, matching `PROVENANCE_FLOOR`'s. `grep -c '^EXPECT_LICENSE=' = 1`
  would still close it terminally; documenting it is a defensible choice, not a defect.
- Case 2's two licence lines are tautological **on their own** — the harness says so — and
  deleting the step-5 block turns them red along with 15 other assertions.
- What *is* untested: the three `built-has-no-*` arms (finding 2). Deleting them is invisible.

**4. Anything failing toward pass or toward silent success?**
Nothing in the shipped code. Traced again and all refuse: a failed/non-JSON read → `json.load`
raises → `pipefail` → `READFAIL` → `fail=1` with no second false line; an unknown `force_fields`
knob → `SystemExit` → empty shim stdout → `READFAIL` → the case's own message assertion goes
red rather than silently passing; `expect_out`'s `grep -q --` patterns contain no BRE
metacharacter that could widen a match (`CC-BY-4.0`'s dots match themselves).

The only silent-success shape in this area is the **absent fixture** of finding 2, which is
about the suite, not the release.

---

## Convergence — what I can show, and what I cannot

**Closed, and shown rather than asserted:** *"a field `licence_of` reads can be absent from one
or both sides and still return OK."* The candidate set is not a judgement — it is the four
`served`/`built` field reads extracted from the function's own AST, and nothing sits above that
source, because the function reads no other document and takes no other input than `$1` and
`EXPECT_LICENSE`. All four × {served-absent, built-absent, both-absent} = 12 states plus the
value-differs cases were executed; zero passes. Deleting the redundancy and the whole block
were both executed too. That class is terminal.

**Not closed:** *"a comment or a printed line claims something the code does not do."* Round 1
found it in a docstring, round 2 in two documents, round 3 in two code comments and one success
line — four rounds, four instances, each one *inside the previous round's fix*. I have no
enumeration for this class: the candidate set is every sentence in the diff that makes a claim,
and I read them rather than measured them. The right terminator, if you want one, is the
`code-check.md` recipe — parse the file, dump every comment and every `print`/`echo` that makes
a positive claim about behaviour, and mark which ones name a mechanism rather than a fact. That
set is finite and small here (roughly a dozen), and doing it from recollection is exactly what
left round 2's two false comments standing.

So: **the licence guard itself has converged; the prose around it has not been shown to.**
