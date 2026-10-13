# Code-check round 2 — branch `74-move-the-nge-item-fields-to-standard-or` (base 844ba81)

Six findings. No blocker: the rename itself, the publish map, the census, the COG-tag bridge
and the `--only` arms all check out, and both self-contained drivers pass against the tree as
it stands (`prov_fields-check.py` 40/40; `catalogue_release-check.sh` ALL PASS).

What was verified clean this round, so round 3 need not re-derive it: the asymmetric shape
arm cannot be slipped by a rename presenting as gain-only (a rename never retains a published
key, so `dropped` is always non-empty; a renamed `processing:software` *entry* is caught by
the value arm, because `canon()` maps entries to staged fields and an unrecognised entry name
drops its fields out of `bv`); `check_cog_tags`'s `bridged` subtraction and the reassembly
loop both fire in the "tag present, entry absent" direction; `NGE_PROVENANCE_NULL` is derived
declared-minus-present and 02 writes the same `sorted()` order; `_corrected()` is type-safe
against a non-string `flooded` entry; `main()`'s hoist (field prefixes -> processing stamp ->
deprecated) landed; `PROV_FIELDS` order matches `01_stage.R` exactly; `PROVENANCE_FLOOR=21`
is consistent with `PROV_CENSUS`; `setequal(character(0), NULL)` is TRUE and jsonlite keeps a
null element's name, so `test_pipeline.R`'s new set algebra holds; the collection's only
namespaced field is `sci:citation` and it declares `SCIENTIFIC_EXT`, so `check_field_prefixes`
passes the real collection; `attribution_drift-check.py` still passes; and every residual
`nge:` hit in `index.html` and `stage_years-check.R` is a `change:` substring.

---

## 1. [bug] `scripts/catalogue_release.sh:312` — a markdown code span inside `python3 -c "…"` runs as a command

Line 292 opens `python3 -c "` and the string closes on line 350. Line 312 sits inside it:

```
    # retired `nge:` prefix is the staged name already, and the rest goes through the map
```

Backticks inside a double-quoted word are command substitution. Measured by running the real
lines 292–350 verbatim with a stubbed `curl`:

```
run.sh: line 63: nge:: command not found
RESULT=1|1|||
```

So every `--only` preflight prints a shell error to stderr, into the one output a release
operator is expected to read, immediately beside the provenance messages. The Python still
works today only because the span sits in a comment and `nge:` is not a command — the next
span someone adds in that comment block *runs*, and `link` and `drift`, the two words that
paragraph is about, are both real executables.

Fix: drop the backticks (the sibling shell comments outside the string, e.g. line 270 and
line 352, can keep theirs), or move the program into a heredoc / its own file.
`code-check-shell.md`, "Quoting" — code spans executed, not just deleted.

## 2. [fragile] `scripts/catalogue_release-check.sh:610` — the new case-12 assertion cannot fail on the property it names

```sh
expect_out "...and the bucket copy agreed on the key shape (no refusal printed)" "live: 2 | built: 2"
```

`expect_out` is `grep -q --`, a substring match, and the needle is a substring of
`catalogue_release.sh:248`:

```sh
echo "live: $n_live | built: $n_local | host: $HOST"
```

That line is the **item-count** line and it sits *before* the `if [ -n "$ONLY" ]` block at
line 250, so it prints on every run that gets as far as the preflight — including case 16,
where the shape arm refuses, and case 15, where the value arm refuses. `$LIVE` is two ids and
the fixture tree holds two items in every one of those cases, so the needle is `live: 2 |
built: 2` in all of them. Nothing the bucket shape arm does can turn this assertion red.

The property the label claims is "no shape message printed", which wants its own needle, e.g.

```sh
expect_eq "no renamed-contract refusal" "$(grep -c 'FULL-release change' "$OUT" || true)" 0
expect_eq "and no gain reported"        "$(grep -c 'provenance gained since' "$OUT" || true)" 0
```

(`|| true` after `grep -c` is correct here; `|| echo 0` would append a second line.)

## 3. [fragile] `scripts/item_create.py:176` and `CLAUDE.md:117` — "the one place the old names survive" names the one place they do not

```python
# is why the `nge:` prefix is now absent from the whole repo except where the COG tags and
# this map name it.
```

Both halves are wrong. `PROV_PROPERTIES` contains no `nge:` string at all — its values are
`link:`, `landcover:` and `processing:`. The live `nge:` reader is
`scripts/catalogue_release.sh:320`, inside `canon()`:

```python
if k.startswith('nge:'):
    out[k[4:]] = v
```

That branch is load-bearing: it is what lets the `--only` value arm compare a post-#74 build
against a pre-#74 live item. Delete it on the strength of this comment and the arm compares a
renamed build against a pre-rename item, finds nothing lost, and passes — which is precisely
the failure the comment at `catalogue_release.sh:270` warns about.

`CLAUDE.md:117` carries the same claim ("The map in `item_create.py` is the publish boundary
and the one place the old names survive"), and it contradicts the sentence two lines above it,
which correctly says the staged names are also what `01_stage.R` and `02_raster_tag.py` write.
Reword both to name `catalogue_release.sh`'s `canon()` as the second `nge:` site.

## 4. [fragile] `scripts/item_create.py:211` — "Derived from the map rather than written twice"

```python
# The twelve staged fields, in 01_stage.R's order. Derived from the map rather than written
# twice: this is the one list that must not drift from the map, because every lookup below
# is keyed on it.
PROV_FIELDS = [ ... twelve literals ... ]
assert set(PROV_FIELDS) == set(PROV_PROPERTIES) | {f for fs in PROV_SOFTWARE.values() for f in fs}, ...
```

It *is* written twice — the `assert` three lines down exists for exactly that reason. The
order claim is correct (checked against `01_stage.R`'s `PROV_FIELDS`); only "derived" is
false. Either say "a second literal, pinned to the map by the assert below", or actually
derive it (`list(PROV_PROPERTIES) + [f for fs in PROV_SOFTWARE.values() for f in fs]` does not
reproduce 01_stage's order, so the honest move is the reword).

## 5. [fragile] `scripts/test_pipeline.R:192-193` — the restored ADD direction names the wrong remedy

```r
staged_prov <- setdiff(names(meta), meta_core)
if (!setequal(staged_prov, prov_fields)) {
  stop("meta.json and this test disagree on the staged provenance field set — staged but ",
       "not declared here (and so published nowhere): ", ...)
```

`meta_core` is a hardcoded list of the 17 non-provenance `meta.json` keys, so `staged_prov` is
"everything 01_stage.R stages that is not in that list" — which includes any **new
non-provenance** field. That is the likelier addition, and for it the message is a false
diagnosis: the field is not a provenance field, it is not "published nowhere" (item_create
publishes plain properties too), and the fix is to add it to `meta_core`, which the message
never mentions. The guard fires correctly and points the reader at the publish map.

Add the third possibility to the message ("…or it is not provenance at all, in which case add
it to `meta_core` above"). Same class as `code-check.md`'s "A guard that fires correctly and
then points at the wrong fix".

## 6. [fragile] `catalogue_release.sh`'s `NEW` map is a fifth, unpinned copy of the publish map

`prov_fields-check.py` statically pins `item_create.py` <-> `item_validate.py` <->
`02_raster_tag.py`, and `test_pipeline.R` joins staging to the published item at build time.
Nothing joins `catalogue_release.sh:294-313` (`NEW`, `SOFTWARE`, `PREFIXES`) to any of them,
and both `scripts/README.md:232-234` and `findings.md` describe the static comparison as "the
only thing joining those three" without saying the shell copy is joined by nothing.

Consequence of a 13th field added without touching `NEW`: `canon()` drops it from both `lv`
and `bv`, so the `--only` **value** arm goes blind to its loss — failing toward pass on an
irreversible publish. The **shape** arm backstops it (post-#74 an absent value omits its key,
so a loss shows up in `dropped`), which is why this is a weakened backstop rather than a hole,
but the backstop is not stated anywhere and the "only thing joining those three" sentence
reads as if the map were fully pinned.

Cheapest fix: `prov_fields-check.py` already parses files with `ast`; a fourth assertion could
`re`-extract the `NEW = {...}` / `SOFTWARE = {...}` literals out of the shell script's inline
program and `ast.literal_eval` them against `PROV_PROPERTIES` / `PROV_SOFTWARE`. Failing that,
say in the shell comment that `NEW` is unpinned and the shape arm is what covers a drift.

---

## Note, not a finding

`planning/active/findings.md` records "`scripts/prov_fields-check.py` is 38 assertions, 0
failed"; the driver now reports **40** (round 1's two `tags_drop` arms). The mutation table
below it was measured against the 38-assertion tree. Worth re-stating before
`/planning-archive`, since that file becomes the evidence record.
