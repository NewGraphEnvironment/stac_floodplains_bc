# Review round 2 — #47 licence + attribution (the round-1 fixes)

Reviewed the **working tree** (everything is staged; `git diff` and `git diff --cached` agree,
so index == worktree). Scope was round 1's six fixes first, then the whole diff against
`code-check.md` and `code-check-shell.md`.

What I ran, so the negatives mean something:

- `bash scripts/catalogue_release-check.sh` → **ALL PASS**, exit 0 (97 assertions, 9c–9i included).
- **Restore-the-bug on the round-1 defect.** Copied `scripts/` to a scratch tree, replaced
  `licence_of` with the presence-only version round 1 found, re-ran the harness:
  9c/9d/9e/9f stayed green, **9g, 9h and 9i all went red** (4 FAILs, each naming its own
  message, not merely exit 1). So the three new cases genuinely exercise the altered modes
  and cannot pass for another reason.
- **Probed `licence_of` directly**, extracted verbatim from the script, against six crafted
  documents (table below).
- **`--only` bypass proved, not read.** Added two probe cases to a scratch copy of the harness
  running `--only` with `FAKE_LIVE_LICENCE`/`FAKE_BUCKET_LICENCE` set to every knob:
  `grep -c 'collection licence' out.txt` = **0**. The licence block never executes under `--only`.
- **Mutation battery on `check_collection_metadata`** against the real
  `data/stac/collection.json` (9 mutations, each producing its own distinct message — see below),
  and on `check_citation_premise` against a mutated copy of the real 23-item tree.
- Measured the build: 23 items, `nge:landcover_collection` = `io-lulc-annual-v02` on 21 / null
  on 2; `nge:landcover_stac_url` = `https://planetarycomputer.microsoft.com/api/stac/v1` on the
  same 21. `PROVENANCE_FLOOR=21` is the right literal, and `EXPECTED_SOURCE_STAC_URL` matches
  the data.
- Live vs built: **20 live, 23 built, 0 orphans**, the three new ids exactly
  `lnth_ch_ff04 / thom_ch_ff04 / unth_ch_ff04`. NEWS.md's claim is correct to the id.
- `uv lock --check` clean, `uv run` (auto-sync) clean, `uv.lock` unmodified by the
  `license = "MIT"` addition.

---

## Findings

### [fragile] scripts/catalogue_release.sh:176 — `sci:citation` absent on BOTH sides compares equal, and the success line then makes a false claim

The link arm three lines below carries an explicit guard for exactly this shape, with the
reasoning written out in the comment at line 161:

> `built-has-no-<rel>-link` matters: without it, a link absent from BOTH sides compares
> equal and the whole check goes quiet on the input that most needs it.

The citation arm has no equivalent. Measured, feeding the extracted function a built copy and
a served copy that both lack `sci:citation`:

| input | `licence_of` says |
|---|---|
| control (both good) | `OK` |
| built + served both lack `sci:citation` | **`OK`** |
| built + served both lack both links | `BAD built-has-no-license-link built-has-no-derived_from-link` |
| served has two `rel=license` links | `BAD rel=license-link-absent` |
| `$1` missing / unreadable | raises → rc 1 → `READFAIL`, `fail=1` |

On the both-absent citation, step 5 prints *"live collection licence: CC-BY-4.0, sci:citation
and both links served as published"* — a positive claim about a field that exists nowhere.

**Reachability: not on a real full release.** `check_collection_metadata` refuses a build with
no `sci:citation` in every one of its states (proved by mutation below), and step 1 gates step
5. But that is *equally* true of both links — `check_collection_metadata` pins their hrefs
exactly — and the link arm was still added. The asymmetry is the finding: one instance of a
class was closed and its sibling, four lines away in the same function, was not
(`code-check.md`, "A fix that reaches one enforcement surface reads as complete on all of
them"). One line closes it:

```python
if built.get("sci:citation") is None:
    bad.append("built-has-no-citation")
elif served.get("sci:citation") != built.get("sci:citation"):
    bad.append("sci:citation-differs")
```

### [low] scripts/catalogue_release-check.sh:329 — the `LICENCE_LITERAL` premise's stated scope is wider than the sed's

`sed -n 's/^EXPECT_LICENSE="\([^"$]*\)"$/\1/p'` correctly refuses the inline-default form
(`EXPECT_LICENSE="${EXPECT_LICENSE:-CC-BY-4.0}"` contains `$`, so it matches nothing and the
compare fails — good). It does **not** see a *separate later reassignment*: a second line
`EXPECT_LICENSE="$SOMETHING"` never matches the sed, so `LICENCE_LITERAL` still reads
`CC-BY-4.0` from line 66 and the premise passes while the effective value is an override.

The `PROVENANCE_FLOOR` premise states this limitation out loud ("An override ADDED after the
literal is not caught here"); the new comment beside `LICENCE_LITERAL` does not, and reads as
though it covers the case. Either copy the caveat, or make it terminal — e.g. also assert
`grep -c '^EXPECT_LICENSE=' "$RELEASE"` is 1.

### [low] CLAUDE.md and scripts/README.md undercount what step 5 now reads

Both predate round 1's `derived_from` fix. CLAUDE.md: *"step 5 reads all three back from the
API and the bucket. The link is the least safe of the three"*; `scripts/README.md`'s step-5
row: *"`license`, the `rel: license` link and `sci:citation`"*. The code now compares **four**
things across **two** links, and the release's own success line already says "both links".
A reader trusting either document would think `derived_from` is unguarded and add a second
check. (`code-check.md`, "Documentation Staleness".)

---

## Answers to the specific questions

**1. Any way the rewritten `licence_of` fails toward PASS? Name the input.**
One, measured: **a built and served collection that both lack `sci:citation`** (finding 1).
That is the only one I could construct. Everything else I tried refuses correctly:

- *Is comparing served-against-published circular?* No. The published copy is the pipeline's
  input, and `item_validate.py` gated it verbatim against its own independently-written
  literal at step 1, before a byte was synced — and nothing between step 1 and step 5 rewrites
  `$STAC_DIR/collection.json` (`collection_register.sh` reads it into a temp file and never
  writes it back; the stamp happens *before* step 1). `license` is additionally compared to the
  `EXPECT_LICENSE` constant, so the one field a consumer's rights turn on is not
  self-referential at all.
- *Published file missing or unreadable?* `json.load(open(...))` raises → rc 1 → `READFAIL` →
  `fail=1`. Refuses. Measured.
- *`$STAC_DIR` under `--only`?* Never reached — see question 2.
- *Is the `built-has-no-<rel>-link` arm right?* Yes, and it bites: measured `BAD
  built-has-no-license-link built-has-no-derived_from-link` on a both-empty-links pair. Its
  message points at the build rather than the API, which is slightly misleading wording on a
  line prefixed *"the API is not serving…"*, but it fails in the safe direction.
- *Duplicate served links?* `href()` returns `None` for `len != 1`, so two `rel=license` links
  report `rel=license-link-absent` — wrong word, right verdict.
- *200 with an empty or non-JSON body?* `json.load` raises → `READFAIL` → `fail=1`.
- Quoting: the `python3 -c` body is single-quoted bash and contains no `'` in its source; both
  values arrive via `sys.argv`. No interpolation hazard (`code-check-shell.md`, "Quoting").

**2. Does step 5 behave correctly under `--only`?**
Yes, proved rather than read. The whole block is inside `if [ -z "$ONLY" ]`
(catalogue_release.sh:632–655), so `licence_of` never opens `$STAC_DIR/collection.json` on that
path. Probe: two extra harness cases running `--only aaaa_ch_ff04` with `FAKE_LIVE_LICENCE` and
`FAKE_BUCKET_LICENCE` both set to `license` (and separately to `citation-altered`) →
`grep -c 'collection licence'` on the run output = **0**, and the only failure reported was an
unrelated checksum from the earlier corrupting case. Correct: `--only` never publishes
`collection.json`, so asserting a licence it did not write would refuse a correct republish
over unrelated drift.

**3. Do 9g–9i actually exercise the altered modes?**
Yes — proved by restoring round 1's defect, not by reading. With the presence-only
`licence_of` back in place, all three go red on **both** of their assertions (exit status *and*
their own message), while 9c–9f stay green. So each of the three is measuring the arm it names
and nothing else. Two notes:

- 9g and 9d assert the **same string** (`sci:citation-differs`), so the message cannot
  distinguish "dropped" from "altered" in a release log. Not a false pass — 9g's mutation is
  unreachable by a presence check, which is what makes it a real case — but the two states
  read identically to an operator.
- 9h's assertion (`rel=license-href=`) and 9i's (`rel=derived_from-link-absent`) are unique
  strings. Good discipline per `code-check.md`, "A restored bug can fire a DIFFERENT guard".

**4. Anything failing toward silent success anywhere in the diff?**
Only finding 1, and it is gated upstream. Everything else I probed refuses:

`check_collection_metadata`, mutating the real collection one field at a time — nine
mutations, nine distinct messages, no silent pass:

| mutation | message |
|---|---|
| drop `sci:citation` only | `scientific extension half-applied: extension declared, sci:citation absent` |
| drop the extension only | `scientific extension half-applied: extension absent, sci:citation present` |
| drop **both** | `the collection publishes no attribution at all …` ← round 1's fix 4, working |
| `sci:citation = "x"` | `sci:citation does not match the expected attribution verbatim` |
| `license = proprietary` | names both values and why `proprietary` is wrong |
| licence link href → evil | `rel='license' link points at 'https://evil/' …` |
| drop `derived_from` | `expected exactly 1 rel='derived_from' link, found 0` |
| 6 providers, Esri twice, Microsoft dropped | `providers missing or altered: Microsoft` |
| drop the derivation statement | names CC BY 4.0 §3(a)(1)(B) |

`check_citation_premise` (round 1's fix 3), mutating all 21 provenanced items:

| mutation | result |
|---|---|
| `nge:landcover_stac_url` → host moved | **21 problems** — the new half bites |
| `nge:landcover_collection` → `v03` | 21 problems |
| `nge:landcover_stac_url` **key removed** | 0 problems (silent here) |

The last row is not a hole: `check_provenance`'s set-equality on `REQUIRED_NGE_PROPERTIES`
reports it as `nge: property set differs from the declared contract` later in the same run, so
the release still refuses. Worth knowing that the null-tolerance in `check_citation_premise`
covers *absence* as well as *null*, and that the coverage comes from a different function.

The `READFAIL` sentinel (round 1's fix 2) is sound: `licence_of` prints only `OK` or `BAD …`,
so there is no collision, and the `READFAIL) : ;;` arm is only reached on a path that already
set `fail=1`. `case` returns 0 on every arm, so `set -e` is not tripped.

---

## Verified, not findings

- **`--only` is fully isolated from the licence check** (measured, above), and case 1 still
  reports exactly four "skipped under --only" lines.
- **`collection_version.py` appends** to `stac_extensions` (`exts = list(...)`), so the
  release-time stamp cannot displace `SCIENTIFIC_EXT` and break the biconditional.
- **The built artifact is correct**: `license: CC-BY-4.0`, `stac_extensions` carrying the
  scientific ext, `sci:citation` 770 chars, 6 providers with `url` intact, and both links at
  the exact expected hrefs. `check_collection_metadata` and `check_citation_premise` both
  return `[]` against it.
- **NEWS.md's release claim is exact**: 20 live, 23 built, 0 orphans, the three named new ids.
  So `--allow-retract` is genuinely not needed.
- **`pyproject.toml`'s `license = "MIT"` is inert and safe**: `uv lock --check` passes,
  `uv run` (auto-sync) succeeds, `uv.lock` unchanged, `[tool.uv] package = false` so nothing
  builds it. The `LICENSE` file is byte-identical in holder and year to `stac_dem_bc` and
  `stac_uav_bc`.
- **Shell traps**: no new arrays under `set -u`; no `ls` parsing; the two new `sed`
  expressions are BRE-safe on BSD; no unquoted heredoc carrying prose; every new
  `$(...) || { …; fail=1; }` ends on a zero-returning statement; the `python3 -c` bodies are
  single-quoted with no embedded apostrophe.

## Operational note (not a defect)

`licence_of`'s central premise — *"`license` and `derived_from` fall outside
`INFERRED_LINK_RELS` and survive"* — is still **reasoned, not measured against this API**. I
checked all four live collections at `images.a11s.one`: every one serves only
`self/root/parent/items/queryables`, and **none of their stored documents publishes a
`rel: license` link**, so there is no evidence either way. (`providers` *do* survive —
`stac-elevation-bc` serves its two back intact — which is a good sign for arbitrary
collection fields.)

If pgstac does drop them, the first full release discovers it at step 5, i.e. **after** the
700 MB sync and the pgstac load have already landed. Nothing is lost (the upsert is idempotent
and the disk copy is correct), but the run exits `RELEASE INCOMPLETE` over a catalogue that is
already live. The script already documents the way to settle it beforehand: `--skip-sync`
against a throwaway collection id.
