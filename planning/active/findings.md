# Findings — Move the nge: item fields to standard or descriptive names (#74)

## Measured 2026-10-13

### The live per-field provenance census (API, nulls dropped)

```
link_run_uid           18
link_config_sha256     21
link_sha               21
link_version           21
flooded_version        21
drift_version          21
produced_datetime      21
landcover_source       21
landcover_collection   21
landcover_stac_url     21
landcover_key          21
landcover_item_hash    21
```

`kotl_bt_ff04`, `larl_bt_ff04`, `sloc_bt_ff04` are missing **only** `link_run_uid`;
`mcgr_ch_ff04` and `pine_bt_ff04` carry none of the twelve. So the catalogue has **three**
populations, not two — which is why the plan's original "per-section all-or-nothing presence"
arm was dropped: it would have refused three live items on its first run. The hole is modelled
upstream (`item_create.py:536-537`: `link_run_uid` is legitimately null on a fresh block whose
schema predates link#262), and `link_sha` / `link_version` come from two different leaves of
the same section (`fp_provenance.R:65-66`), so one-sided nullity is reachable by construction.

### The processing extension v1.2.0 schema (fetched 2026-10-13)

- Every typed field is `string`; **no field admits `null`**.
- `processing:software` is an `object` with `patternProperties {".{1,}": {"type": "string"}}` —
  so `{}` is valid, and entry values must be strings.
- The Item branch is `allOf[require_any_field, fields]`, and `require_any_field` is an `anyOf`
  of seven single-field `required` objects. **Declaring the extension on an item with no
  `processing:` field fails validation.** This is what forces the conditional declaration.
- `processing:datetime` carries `"format": "date-time"` **and** `"pattern": "(\\+00:00|Z)$"`.
  All 21 live `produced_datetime` values end in `Z`; the value is passed through verbatim from
  upstream `landcover$run$datetime_utc`, which this repo does not shape-check, so the pattern
  is a new constraint on an unguarded input.
- `fields` has `additionalProperties: false` with `patternProperties {"^(?!processing:)": {}}`,
  so pystac refuses an **unknown** `processing:` key once the extension is declared, and
  ignores every other prefix.

## The sibling precedents

`stac_airphoto_bc#47` (published 2026-10-11, v1.0.0) is the template:

- `scripts/airphoto_props.py` holds the field map, the named required set, and a prefix table
  `FIELD_PREFIXES = {"proj": …, "file": …, "processing": …, "airphoto": None}` — the `None`
  being the "this catalogue alone writes it, so no schema" case.
- `nge:fly_version` + `nge:fly_sha` became **one** `processing:software` entry,
  `{"fly": "<version>+<sha>"}` (semver build metadata), and `scripts/stac_validate.py`'s
  `tags_disagree()` reassembles `FLY_VERSION + "+" + FLY_SHA` to compare it. That reassembly is
  what let two fields become one without touching a raster.
- COG tag names kept; item JSON only; no schema vendored. It refused the issue's
  checked-in-copies instruction on the ground that it uses no crate schema.
- `airphoto_props.py:203-216` cites this repo's `item_validate.check_provenance` as the
  anti-pattern to avoid — a check that compares items to each other cannot see a key missing
  from all of them.

`stac_pointcloud_bc` is where the vendored-schema mechanism lives (`schemas/<prefix>/vX.Y.Z/`
plus a `schemas_preload()` seeding `pystac`'s `RegisteredValidator` cache). Not used here,
because no crate schema is authored.

crate's rule (`pkgdown/assets/stac/README.md:13`): "A prefix earns a schema here only when more
than one catalogue writes it, or something outside NGE reads it … provenance that only one
catalogue writes goes in the standard fields instead." `crate#23` stays open pending the
prefixes the sibling migrations settle on.

## Plan review (Plan agent, 2026-10-13)

Findings folded into `task_plan.md` before the baseline. The ones that changed the design:

| finding | what changed |
|---|---|
| per-section all-or-nothing is false on 3 live items | replaced by a per-field exact census (verified above) |
| a prefix table is weaker than the key-set equality it replaces | the declared **key** set is still asserted — every published key must be declared, entry names included |
| the per-section counts were printed, never asserted | the census is the assertion; a section lost on every item used to pass |
| `processing:software` spans all three upstream sections | sections re-addressed as (property, entry) pairs |
| `{}` and `{"link": "+<sha>"}` are schema-valid | both refused explicitly; one-sided version/sha is an upstream break, not a null |
| `--only`'s preflight goes blind on the renamed build | two arms: canonicalised value-loss, plus a key-shape comparison that covers the two all-null items |
| the fixtures `nge:probe`/`nge:kept` become vacuous once the preflight canonicalises | re-expressed in real declared names |
| `NGE_PROVENANCE_NULL` must be derived as declared-minus-present | a mechanical port keeps `v is None` and makes it always empty |
| the map's field domain needs a totality check against `02_raster_tag.py` | asserted in the new driver and in `test_pipeline.R` |
| stale premises outside the listed files | `01_stage.R:44`, `02_raster_tag.py:75-82`, `fp_provenance.R:5`, `catalogue_release-check.sh` header, seven `CLAUDE.md` facts |
| `index.html` / `README.Rmd` / `readme_functions.R` are clean | every `nge:` hit there is a minified-JS `change:` substring; no time spent |

## The rename moves no bytes — measured, not reasoned (2026-10-13)

`WSG=larl ALLOW_DRIFT_SKEW=1 Rscript scripts/test_pipeline.R` passes end to end in ~21 s, and
the item it builds was compared asset by asset against what the API serves for
`larl_bt_ff04`:

```
identical file:checksum : 10 of 10 assets
moved                   : 0
```

So the claim that this is an item-JSON-only change is a measurement. `larl` is also one of the
three items in the 11-of-12 population, so the run exercised the omitted-key path: it published
8 provenance keys (no `link:run_uid`), and its COGs still carry all eleven `NGE_` value tags
plus `NGE_PROVENANCE_NULL = link_run_uid`.

The skew override is still required (`drift` 0.20.0 installed against 0.8.0 in the record) —
re-measured here rather than taken from the note, and it changed no bytes for this group.

## Mutation table (re-measured 2026-10-13 after round 2)

`scripts/prov_fields-check.py` is **44 assertions, 0 failed**. Each guard was then removed in a
**copy** of `scripts/` and the driver re-run, so the measurement is of the guard rather than of
the working tree. (38 when first measured; round 1 added two `tags_drop` arms, round 2 three static ones
and round 3 one more, so the table below is a re-run rather than the original.)

| defect restored | assertions red |
|---|---|
| the declared-key arm | 2 |
| the stray-software-entry arm | 1 |
| the per-field census | 4 |
| the floor | 1 |
| `seen == 0` | 1 |
| `check_field_prefixes` | 3 |
| the processing-extension biconditional | 2 |
| the empty-software-map arm | 1 |
| the `<version>+<sha>` pair arm | 1 |
| the `processing:datetime` shape arm | 1 |
| the COG-tag reassembly | 2 |
| `NGE_PROVENANCE_NULL` as declared-minus-present (ported mechanically instead) | 2 |
| holding the bridged tags out of the generic diff | 1 |
| **the writer's refusal of a half-present software entry** | **0** |

And the five copies of the field map, mutated one at a time (round 2 added the preflight's,
which nothing had pinned):

| copy mutated | assertions red |
|---|---|
| `item_create.py`'s `PROV_PROPERTIES` | 1 |
| `02_raster_tag.py`'s `PROV_FIELDS` | 1 |
| `catalogue_release.sh`'s preflight `NEW` | 1 |
| …its `SOFTWARE` entries | 1 |
| …its `PREFIXES` tuple, including the retired `nge:` it alone reads | 1 |
| the preflight moved out of its inline `python3 -c` entirely | refused outright, naming the cause |

The one `0 red` row is the honest gap. The driver mirrors `item_create.py`'s writer rather than
importing it — importing runs the whole build — so mutating the writer cannot turn the driver
red. What *is* proven is the backstop that decides whether such a tree can be published: the
validator's `<version>+<sha>` arm, which refuses a half-present entry whatever wrote it. The
writer's own `raise` is a fail-fast convenience in front of that.

## Review round 1 — 7 findings, all fixed

Reviewer notes are in `review-round1.md`. Each was reproduced before it was fixed:

| # | finding | verified how | fix |
|---|---|---|---|
| 1 | `test_pipeline.R` lost the ADD direction of the staging join: only `prov_fields ⊆ names(meta)` remained, so a thirteenth staged field would be staged, published nowhere, and seen by nothing | read the file — the data-derived `setdiff(names(meta), meta_core)` was gone | restored, as set equality against the declared list, with the comment saying why nothing else can see it |
| 2 | the `--only` shape arm refused a provenance **gain**, calling it a renamed contract — the exact shape a re-run `kotl`/`larl`/`sloc` will produce, and #36's path is what it would block | traced the reachable case | made asymmetric: a key the bucket has and the build lacks refuses; a key the build gains is reported and allowed. New case 17 pins it |
| 3 | `01_stage.R` still asserted the pre-#74 null contract eight lines below an edited block | read it | corrected, and it now says where the positive statement survives |
| 4 | `prov_fields-check.py` was documented nowhere, while all four siblings are in both `CLAUDE.md` and `scripts/README.md` | grep, 0 hits | added to both |
| 5 | the "a tag missing from the COG" fixture passed `None`, which **writes the literal string `"None"`** — so it re-tested the value-differs path and the missing-tag direction was uncovered; the inline comment stated the false fact | re-measured: `update_tags(A='x', B=None, C='')` reads back `A='x'`, `B='None'`, `C` absent | fixtures gained a `tags_drop` that pops the key; two arms now cover the direction, including `NGE_PROVENANCE_NULL` dropped on an all-absent item |
| 6 | `PROV_CENSUS`'s comment said to read the numbers off what `01_stage.R` and `item_create.py` print; neither prints a per-field count | read both | the validator now prints a `census:` line on every run, asserted or not, and the comment points at it |
| 7 | `check_deprecated` ran before `check_processing_stamp`, so a malformed `processing:software` reported 21 items as unmarked-and-not-rebuilt instead of one shape message | traced `_software`'s `{}` fallback | the field-name and processing arms are hoisted above it |

Round 1 also verified clean, so round 2 need not re-derive it: the COG-tag bridge and
reassembly, the declared-minus-present null derivation, `PROV_SECTIONS` still discriminating,
every census/floor/declared-key arm reachable with a unique needle, `publish()` not being
verification-reads-its-own-output (the `ast` comparisons can fail and were shown to),
the `--only` shell details (`IFS='|'` positions, the heredoc, one `trap … EXIT`, no quoting
hazards in the inline python), case 16's shim rewrite, and the R primitives.

It independently re-ran `prov_fields-check.py` (38/0 at the time), `catalogue_release-check.sh`
(ALL PASS) and pystac against the real item, confirming all three schema claims.

## Review round 2 — 6 findings, all fixed

Reviewer notes in `review-round2.md`. One real bug, inside this branch's own shell:

| # | finding | verified how | fix |
|---|---|---|---|
| 1 | **bug** — a markdown code span inside the `--only` preflight's `python3 -c "…"` argument is a **command substitution**: bash ran `nge:` on every preflight and printed `nge:: command not found` into the operator's output. Benign only because that span named nothing executable; `link` and `drift`, the two words the paragraph is about, both are | reproduced: a backtick span inside a double-quoted `python3 -c` prints `nge:: command not found` and the program still returns 1 | backticks removed from the inline program, with a NO BACKTICKS note and the measurement beside it |
| 2 | the case-12 assertion matched `live: 2 \| built: 2`, a line the release prints BEFORE the `--only` branch — so it also matches in cases 15 and 16, where both arms refuse. It could not fail on the property its label named | read the release script's print order | replaced with a count of both shape messages being zero |
| 3 | two comments claimed the publish map is "the one place the old names survive"; `canon()` in `catalogue_release.sh` reads the retired prefix too, deliberately, and a reader trusting the comment would delete the branch that lets `--only` work across the rename | grep for `nge:` in the scripts | both corrected (`item_create.py`, `CLAUDE.md`) to name `canon()` as the second reader and why |
| 4 | `PROV_FIELDS`'s comment said "derived from the map"; it is a hand-written literal, which is why the `assert` below it exists | read it | comment says it is written out for its ORDER, which a set has none of |
| 5 | the restored ADD-direction message named one remedy, but the set also catches a new NON-provenance `meta.json` field, for which "published nowhere" is false and the real fix (`meta_core`) was unnamed | traced `meta_core` as the hardcoded complement | the message now names both cases and both remedies |
| 6 | the preflight's copy of the map was a **fifth** copy pinned by nothing, while the docs called the static comparison "the only thing joining those three" — a thirteenth field would leave the value arm blind to its loss | counted the copies | `prov_fields-check.py` now slices the inline program out of the shell script and compares `NEW`, `SOFTWARE` and `PREFIXES`; three new assertions, each proven to fire, and a failed slice refuses rather than passing |

Round 2 verified clean: the asymmetric shape arm cannot be slipped by a rename presenting as
gain-only (a rename never retains a published key, and a renamed *entry* is caught by the value
arm); the `bridged` subtraction and reassembly fire in the tags-present/entry-absent direction;
`02_raster_tag.py` writes `NGE_PROVENANCE_NULL` in the same `sorted()` order the validator
derives; `_corrected()` is type-safe against a non-string entry; `PROV_FIELDS`' order matches
`01_stage.R`; `PROVENANCE_FLOOR` agrees with `PROV_CENSUS`; the `seen == 0` early return carries
the census; the R set algebra holds (`setequal(character(0), NULL)` is TRUE, a JSON null keeps
its name); the real collection's only namespaced field is `sci:citation`, with its extension
declared; one `trap … EXIT`; and the `IFS='|'` field positions including the trailing empty.

Noted without action: the printed `census:` line is `field N` pairs, readable but not pasteable
into the `"field": N,` literal. The comment says so rather than implying otherwise.

## A defect inside round 2's fix, and the enumeration that closes the class

Round 2's finding 1 was a backtick span inside the `--only` preflight's `python3 -c "…"`
argument, which bash ran as a command. The fix removed the backticks and added a comment
recording the measurement — and that comment contained a **quoted phrase**, which ended the
`python3 -c` argument early and broke 28 assertions in `catalogue_release-check.sh`. Same
mechanism, one character over: prose written inside a double-quoted shell argument.

Recalling the hazards was what produced the second one, so the class is closed by enumeration
instead. `prov_fields-check.py` now slices the program out of the shell script and refuses on
every character bash still expands inside double quotes, plus any `$` that is not one of the
three interpolations the program is written to receive. Each member injected into the program
in a copy of `scripts/`:

| injected | caught |
|---|---|
| a backtick span | yes |
| a double quote | yes |
| a backslash | yes |
| an unexpected `$VAR` | yes |
| an unexpected `${VAR}` | yes |

That is the whole set for a double-quoted bash string: `` ` ``, `"`, `\`, `$`. The guard is
over the characters rather than over the phrasings, so there is nothing left for a future
comment to get wrong, and `catalogue_release-check.sh` is the second instrument — it is what
caught the quote within the hour, by exercising the preflight rather than reading it.

## Review round 3 — the mechanism, and a defect inside round 2's enumeration

Round 3 was asked for the MECHANISM rather than more instances. Its answer: of the thirteen
prior findings, nine were one shape — **a comment, message or printed line asserting a property
the code does not have** — and three of those were that shape sharpened, where the prose is
itself program input. Only two were the copies-and-joins shape, which round 2 closed. It
enumerated all ten copies of the provenance fact with the join pinning each: eight below their
source, two above.

And it found a defect **inside round 2's enumeration**, which is the second time this branch has
reproduced a class inside its own fix:

| # | finding | verified how | fix |
|---|---|---|---|
| 1 | **bug** — the hazard enumeration listed three characters and matched `$NAME`/`${NAME}`, so it missed `$(…)` — the *same mechanism* as the backtick that shipped — along with `$?`, `$$`, `$@`, `$*`, `$!`, `$#`. The reviewer injected `MARKER = '$(touch /tmp/PWNED_MARKER)'` into the preflight: the driver passed 44/0 with the bash arm **ok**, the release-check suite passed, and bash created the file | reproduced independently here: a `$(touch …)` inside the `python3 -c` argument ran and created the probe file | the `$` arm is now a **subtraction over every `$`** — each one must BEGIN one of the three allowed interpolations — and 15 injected forms are all caught, 0 uncaught |
| 2 | `CLAUDE.md` still said the static comparison is "the only thing joining those three" after round 2 made it four | read it | corrected, and it now names the bash enumeration too |
| 3 | `scripts/README.md` carried the same stale claim, and `prov_fields-check.py` said "three copies" in one place and "the fifth copy" in another | read both | both corrected |
| 4 | `item_create.py`'s traceability print held a **sixth**, bare copy of a published key name, joined to nothing: a rename would make it read `0/23` silently | read it | reads `PROV_PROPERTIES["link_run_uid"]` instead, in both the predicate and the label |
| 5 | the stated reason for `PROV_FIELDS` being a written list ("the ORDER is what NGE_PROVENANCE_NULL reads in") is false — both producers `sorted()` | read both | it says what it is: the declaration the assert checks the map against |
| 6 | `PROV_CENSUS`'s comment said neither upstream script prints a per-field count; `item_create.py` prints the `link_run_uid` row | read the print | corrected to name that one row |
| 7 | this file said 43 assertions when the driver reported 44 | ran it | corrected, and the count now comes with its arithmetic |

Two more claims were checked here and tightened rather than left: `NGE_PROVENANCE_NULL` is the
only **provenance** tag the all-absent items carry (not the only tag — the shared identity and
metric tags are there too), and "every other read takes curl's stdout" now excludes the two
`-o /dev/null` status probes, which read no body.

### The enumerations that close the two classes

**Shell expansion inside the preflight's `python3 -c "…"`** — the complete set bash expands
inside a double-quoted string is `$`, `` ` ``, `\` and the closing `"`. The guard covers all
four, with `$` as a subtraction rather than a pattern, and every form was injected in a copy of
`scripts/`:

```
backtick span, double quote, backslash, $(...) substitution, $(...) in a comment,
backtick substitution, $?, $$, $@, $*, $!, $#, $1, $VAR, ${VAR}
15 forms, 0 uncaught
```

**Quantified prose in the branch's own comments** — 107 added comment lines carry a
quantifier (`every`, `each`, `all`, `only`, `never`, `none`, `nothing`). Round 3 checked the
documentation claim by claim and this session re-checked the mechanically falsifiable ones:
the one-`trap` claim (one `trap` statement, the second grep hit is the comment about it), the
`curl` claim (tightened), the tag names on a real build (measured on `larl`), `PROV_FIELDS`'
order against `01_stage.R`, and the ten copies with their joins. Four were false and are fixed
above; the rest hold.

## Review round 4 — three more holes in the guard, so the construct went instead

Round 4 was asked whether the two enumerations were terminal. The character set was: `$`,
`` ` ``, `\` and the closing `"` is POSIX's own list for a double-quoted string, and `!` was
measured not to apply (history expansion is off non-interactively, on bash 3.2 and 5 alike).
What was not terminal was everything around it:

| # | finding | verified how | fix |
|---|---|---|---|
| 1 | the `$` subtraction was a **prefix** test, and bash's identifier is maximal — so `$ONLY_PATH`, `$ONLYX`, `$STAC_DIRX` and `$only_bucket2` all passed as "one of the three" | the reviewer changed `$ONLY.json` to `$ONLY_PATH` in a copy and the driver stayed 44/0 | moot: the program is no longer a shell argument |
| 2 | the slice's end marker `")` is the one sequence the scan cannot see — an odd `"` before a `)` both truncates the program and is excluded from the text being scanned | a comment ending `: ")` gave 44/0 while `bash -n` reported a syntax error | moot, same reason |
| 3 | the guard covered 1 of the **7** inline `python3 -c "` programs in `catalogue_release.sh`; the other six carry the identical class | enumerated: all six clean today (0 backticks, no stray `$`) | filed as [#77](https://github.com/NewGraphEnvironment/stac_floodplains_bc/issues/77) with the three options and the measurement |

Three fixes in three rounds, each correct, each leaving a new hole. The hazard was never the
characters — it was the **construct**: a program written as the argument of a double-quoted
shell string, where bash gets to it first. So the construct is gone. `scripts/only_preflight.py`
is a stdlib-only file taking two paths as argv and the live item on stdin, run as `python3`
(not `uv run`: the release machine holds nothing else, and `catalogue_release-check.sh` shims
`uv`). There is no shell quoting left to get wrong, the comments can say anything, and
`prov_fields-check.py` now **imports** the module to compare its map against the validator's
instead of slicing a shell script — plus one assertion that the release still calls the file,
because reverting the extraction would bring the class back while the comparisons kept passing.

| mutation | assertions red |
|---|---|
| `only_preflight.py`'s map | 1 |
| …its software entries | 1 |
| …its prefix tuple, including the retired `nge:` it alone reads | 1 |
| the release reverting to an inline `python3 -c` | 1 |

Round 4 also checked three load-bearing claims against commands: every asset-writing script has
**zero** non-comment changed lines against the base commit (so "no raster changed" is a
property of the diff, not a hope); the processing v1.2.0 schema's shapes are as documented, with
`processing:software` typed `object` of string values rather than `string` — NEWS said the loose
thing and now says the precise one; and both suites pass on this HEAD.

Also removed: an `import re` left unused by round 3, and a second non-finding —
`PROV_PROPERTIES["link_run_uid"]` resolves statically, as intended.

## Review round 5 — the new file, and the class that terminates the loop

| # | finding | verified how | fix |
|---|---|---|---|
| 1 | `only_preflight.py`'s **live** side read `live.get("properties", {})`, so any readable JSON that is not an item — an error page, a collection, a redirect body — compared as empty and printed a clean line. The built side already raised on the same shape, so one of three inputs was honest | the reviewer measured `echo {} \| only_preflight.py …` → `0\|2\|\|\|`, rc 0, no refusal | both documents it does not construct are asserted: `type == "Feature"` and a dict `properties`, or refuse. The bucket side had the same shape — a bad bucket copy read every built key as *gained*, which is reported rather than refused — and is now guarded with it |
| 2 | four pointers still placed the comparison inside `catalogue_release.sh` after round 4 moved it, and one claimed a bash enumeration that was deleted with the construct — a reader told a guard is in place that is not | grep for the guard's identifiers, which returned only prose | `scripts/README.md`, `CLAUDE.md`, `item_create.py` and a superseded duplicate paragraph in the driver all corrected |

Round 5 also verified, with measurements, the things only it had reason to check: every failure
mode of the new program refuses (missing argv, nonexistent path, empty stdin, a list, a bare
string, `properties: null`); `pipefail` inside `$( )` makes a failing `curl` or `python3` a
non-zero substitution so the `||` fires; the heredoc body and `EOF` sit at column 0; `IFS='|'`
keeps the trailing empty field in position; a `|` or newline inside a key corrupts its own
field, which is one of the refusing fields, so it cannot turn a refusal into a pass; there is
exactly one `trap … EXIT`, armed after a six-X `mktemp`; `python3` over `uv run` is right
because the harness shims `uv`; and the "the release still calls the file" assertion could not
be made to pass against a revert (single-quoted inline, `/dev/stdin`, or a deleted call).

And it stated out loud what nothing had written down: **until this release lands, `--only`
refuses every item**, because every live item's bucket copy is pre-rename. That is the designed
behaviour; it is now in NEWS.

### The enumeration that ends the review

Five rounds, and twice a round found a defect inside the previous round's fix. The rule for
stopping is an enumeration rather than a quiet round, and the class round 5 landed on — **a
comparison that compared nothing, reporting clean** — is enumerable. Every comparison this
branch adds or changes, with what it does when it has nothing to compare:

| comparison | on an empty comparison |
|---|---|
| `only_preflight` live document | refuses (`type`/`properties` asserted) |
| `only_preflight` built document | refuses (`KeyError` on `properties`) |
| `only_preflight` bucket document | refuses (same assertion as live) |
| `only_preflight` `processing:software` of the wrong type | refuses rather than skipping the four fields |
| `check_provenance` | `seen == 0` is a problem |
| `check_cog_tags` | `compared == 0` is a problem |
| `check_field_prefixes`, `check_processing_stamp` | report clean on zero items — covered because `main()` always runs `check_provenance` over the same tree, and the driver asserts that an empty tree is not a pass |
| `prov_fields-check`'s literal joins | a file that will not parse, or a preflight that moved, raises `SystemExit` rather than passing |
| `test_pipeline.R`'s staged↔published join | `setequal(character(0), prov_fields)` is FALSE, so an empty staged set fails |

Nothing in that set sits above its source. Combined with the two earlier enumerations — the
complete character set bash expands inside a double-quoted string (now moot: the construct is
gone), and the ten copies of the provenance fact with the join pinning each — the review ends
here rather than on a quiet round.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `catalogue_release-check.sh` case 16 asserted a key list that did not exist in the fixture | read the actual message rather than predicting it — the fixture carries two provenance keys, not three |
| a "nothing was said" assertion written as a `grep -c` inside `expect_out` | `expect_out` only matches positively; the negative form is `expect_eq "$(grep -c … || true)" 0` |
| a guard over a construct, fixed three times | the third fix removed the construct — a program in a file has no shell quoting to get wrong |
| an "enumeration" written as a pattern over the forms we thought of | `$(…)` slipped it — invert it to a subtraction over every occurrence of the dangerous character |
| a backtick span in a comment inside `python3 -c "…"` | bash expands it before python sees it — keep backticks out of any inline program, and prefer a heredoc when prose must carry them |
| the bucket read used `curl -o`, which the check harness shim ignores (it prints to stdout), leaving an empty file the comparison then read as nothing | redirect instead: `curl -sf "$url" > "$file"` |

## Issue context

**If we do it:** each field an item carries says what it is. Clients that know the standard extension read the standard fields, and a reader does not have to know that `nge` means New Graph Environment. **If we never do:** the fields stay readable only to people who know the initials.

Decided for the catalogue family in NewGraphEnvironment/stac_pointcloud_bc#12 (2026-10-10):
- A field with a standard home uses it.
- Otherwise its prefix names what it describes.
- `nge:` stays only where New Graph Environment itself is the subject.

Each custom prefix gets a JSON Schema in crate, which items list in `stac_extensions` (NewGraphEnvironment/crate#23 is the umbrella; `lidarbc` and `las` are done there). **Prefer a standard field.** A custom prefix earns a crate schema only when more than one catalogue writes it, or something outside NGE reads it (`crate/pkgdown/assets/stac/README.md`), because every schema is permanent and every field change is a new version. Provenance that only this catalogue writes goes in `processing:*` or a `derived_from` link.

Once the mapping below is settled, file one crate issue for the custom prefixes that remain and link it from crate#23. This catalogue's rebuild waits on that crate deploy. Validate against copies of the schemas checked into this repo, as stac_pointcloud_bc#2 does, not against the live URLs. The [processing extension](https://github.com/stac-extensions/processing) (v1.2.0) defines `processing:datetime`, `processing:version`, `processing:software` (a name → version map) and `processing:lineage`.

## Fields (main, 2026-10-10)

The mapping below is a proposal. Check each row against what the field holds before renaming it.

| field | proposed | note |
|---|---|---|
| `nge:produced_datetime` | `processing:datetime` | the same meaning |
| `nge:flooded_version`, `nge:link_version`, `nge:drift_version` | `processing:software` `{"flooded": …, "link": …, "drift": …}` | |
| `nge:link_sha`, `nge:link_config_sha`, `nge:link_run_uid` | a prefix naming the link run (e.g. `link:`) | provenance with no standard home |
| `nge:landcover_stac_url` | a `derived_from` link to the land-cover item | a STAC core relation |
| `nge:landcover_collection`, `nge:landcover_source`, `nge:landcover_key`, `nge:landcover_item_hash` | a `landcover:` prefix | they describe the input land cover, not NGE |

`nge:probe`, `nge:kept` and `nge:x` appear only in test fixtures (`scripts/catalogue_release-check.sh`, `scripts/test_pipeline.R`), not in items.

## Do the COG tags move too? (decides the cost)

Not in the mapping above, and it is the difference between an item-JSON republish and
re-encoding the whole catalogue.

`02_raster_tag.py:250` derives each COG tag name as `NGE_<FIELD>` from `PROV_FIELDS`, and
`item_validate.py:546` verifies *"each COG's `NGE_` tags agree with its item's non-null `nge:`
properties"*. So renaming the properties either breaks that cross-check or moves the tags with
them — and moving the tags rewrites every COG's bytes, so every `file:checksum` in all 23 items
moves, on a bucket with **no rollback**.

**stac_airphoto_bc#47 already decided this for the family, and chose to keep the tag names:**
*"The COG tags keep their names (`FLY_VERSION`, `FLY_SHA`, `PIPELINE_SHA`), so the rename moves
no checksum."* It published 2026-10-11 as item JSON only, 0 of 10,100 API items left carrying an
`nge:` key. Following it here means the cross-check gains a property → tag-name map (the one
place the old names survive) and this catalogue's rename needs **no COG rebuild at all** —
which also means it does not have to wait for a rebuild, contrary to the "When" section below.

Worth confirming against airphoto's `stac_validate.py` before committing to it, since this
repo's tag set is 12 fields rather than 4 and `PROV_NULL_TAG` has no property counterpart.

## When

Renaming changes every published item, so it rides with this catalogue's next full rebuild, not a release of its own. NEWS names each old → new pair, because a saved filter on an old name stops matching.



