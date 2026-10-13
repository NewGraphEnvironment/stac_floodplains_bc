# Review round 4 (#74)

Scope as briefed: (1) is `bash_hazards()`'s enumeration terminal, (2) is the guard reachable
from the release path, (3) anything wrong inside round 3's fixes, (4) three load-bearing
unchecked claims, checked.

Repo tree was clean before and after (`git status --porcelain` empty). All mutations were made
in a copy of `scripts/` under the session scratchpad, never in the repo.

---

## Findings

### 1. `[fragile]` `scripts/prov_fields-check.py:313-316` — the `$` subtraction is a PREFIX test, so `$ONLY_PATH` passes

`if not any(rest.startswith(ok) for ok in _ALLOWED_INTERPOLATIONS)` accepts any `$` whose text
*starts with* `$STAC_DIR`, `$ONLY` or `$only_bucket`. Bash's identifier is maximal, so
`$ONLY_PATH` is the variable `ONLY_PATH`, not `ONLY` followed by `_PATH`. The guard cannot tell
them apart.

Measured. In a copy of `scripts/`, `open('$STAC_DIR/$ONLY.json')` was changed to
`open('$STAC_DIR/$ONLY_PATH')`:

```
$ uv run python "$S/scripts/prov_fields-check.py" | grep -i "bash\|assertions"
  ok    the preflight program survives bash: every $ is one of three, nothing else bash expands
44 assertions, 0 failed
```

A sweep of 23 injected forms through the function verbatim (exec'd out of the source, so the
real code ran) flagged every one except the four prefix extensions:

```
'`id`'            -> FLAGGED      '$?'  -> FLAGGED      '$HOME'          -> FLAGGED
'$(touch /tmp/x)' -> FLAGGED      '$$'  -> FLAGGED      '$ONLYX'         -> MISSED
'$((1+1))'        -> FLAGGED      '$@'  -> FLAGGED      '$ONLY_PATH'     -> MISSED
'${ONLY}'         -> FLAGGED      '$*'  -> FLAGGED      '$STAC_DIRX'     -> MISSED
'"'               -> FLAGGED      '$!'  -> FLAGGED      '$only_bucket2'  -> MISSED
'\'                -> FLAGGED     '$#'  -> FLAGGED
'$'               -> FLAGGED      '$1'  -> FLAGGED
```

Consequence today is fail-safe, not fail-open: all three variables appear only inside
`open(...)` paths, so an unintended name expands empty, python raises, and the
`|| { ... refusing to publish blind ...; exit 1; }` fires. But the docstring's claim is that
this is a subtraction over *every* `$`, and it is not — it is a subtraction over every `$`
that does not begin with one of three strings, which is a different and weaker set. The same
class as round 3's finding: the set was reasoned about rather than computed at the boundary.

Fix is one expression — require the next character to be outside the identifier set:

```python
_ID = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
...
if not any(rest.startswith(k) and rest[len(k):len(k) + 1] not in _ID
           for k in _ALLOWED_INTERPOLATIONS):
```

Verified against the sweep above: that form flags `$ONLYX`, `$ONLY_PATH`, `$STAC_DIRX` and
`$only_bucket2` while `$ONLY.json`, `$STAC_DIR/` and `$only_bucket'` (the three real sites,
each followed by `.`, `/` or `'`) still pass.

### 2. `[fragile]` `scripts/prov_fields-check.py:233` — the slice's end marker `")` is the one sequence the hazard scan cannot see

`release_preflight_program()` ends the slice at `text.index('")', start)` and `body` excludes
that `"`. So a `"` immediately followed by `)` is removed from the body *and* truncates it, and
the scan then reports clean on a program bash will not survive. It is blind to exactly the
character that shipped once (a double quote in a comment, round 2).

Measured. A comment whose last two characters are `")` inserted after `return out` in a copy:

```
$ sed -n '340p' "$S/scripts/catalogue_release.sh"
# the end marker of this program is a quote then a paren: ")
$ uv run python "$S/scripts/prov_fields-check.py" | grep -i "bash\|assertions"
  ok    the preflight program survives bash: every $ is one of three, nothing else bash expands
44 assertions, 0 failed
$ bash -n "$S/scripts/catalogue_release.sh"
.../catalogue_release.sh: line 342: syntax error near unexpected token `('
```

A balanced pair of quotes is still caught, because the first `"` of the pair always lands
inside the body — re-measured with `(a "wire name")`, which the guard flagged. Only an odd
`"` sitting immediately before a `)` escapes.

The runtime outcome is fail-safe, and measured rather than assumed: the `"` closes the
`python3 -c` argument and the following `)` closes the `$(`, leaving the rest of the python
program as bash tokens *inside the enclosing `if [ -n "$ONLY" ]; then ... fi`* — one compound
command, which bash must parse in full before executing any of it. Minimal repro:

```
$ /bin/bash parse.sh
BEFORE
parse.sh: line 6: syntax error near unexpected token `'reached''
exit=2
```

Nothing inside the `if` ran, and in `catalogue_release.sh` every write (sync, register) is past
that block, so the release aborts before touching the bucket. So: not a data-loss path, but the
guard reports a pass on the one input it was written to refuse.

Cheapest fix: assert the slice really ended at the end of the command rather than at the first
`")`, e.g. after computing `end`, require `text[end:end + 4] == '") \\'` (what the real line
carries) and raise the same "the markers moved" `SystemExit` otherwise. That restores "a `"`
anywhere in the program is reported".

### 3. `[fragile]` `scripts/prov_fields-check.py:227-245` — the guard covers 1 of the 7 inline `python3 -c "` programs in `catalogue_release.sh`

`release_preflight_program()` anchors on `text.index("only_prov=$(curl")`, so the hazard scan
sees only the step-0 preflight. The file holds six more inline double-quoted python programs
carrying the identical class — a backtick or `$(...)` in any of them runs a command on every
release, silently, because the program's own output is unaffected (that is precisely how the
round-2 backtick shipped unnoticed).

Enumerated rather than recalled — every `python3 -c "` in the file, with the hazard characters
counted in each body:

```
line 122: backtick=0 backslash=1 dollars=[]
line 129: backtick=0 backslash=0 dollars=[]
line 293: backtick=0 backslash=0 dollars=['$STAC_DIR/$ONLY.','$ONLY.json',"$only_bucket'"]   <- the only one guarded
line 611: backtick=0 backslash=0 dollars=['$STAC_DIR/$probe','$probe_item.json', ...]
line 636: backtick=0 backslash=0 dollars=['$STAC_DIR/$probe','$probe_item.json','$probe_href']
line 661: backtick=0 backslash=0 dollars=['$STAC_DIR/$ONLY.','$ONLY.json']
line 769: backtick=0 backslash=0 dollars=['$STAC_DIR/*.json']
```

All six are clean today, so this is a scope gap and not a live defect. The `\` at line 122 is
`print('\n'.join(...))`, which bash leaves alone (a backslash is only special before `$`,
backtick, `"`, `\` or newline), so it is correct as written and would be a false positive for
the current scan — worth a per-site allowance rather than a global ban if the scan is widened.

Widening it is a loop, not a design: iterate `re.finditer(r'python3 -c "', text)`, slice each to
its first unescaped `"`, and run `bash_hazards` over each with the union allowance
`{$STAC_DIR, $ONLY, $only_bucket, $probe_item, $probe_href}`. That is what makes the stated
class ("what bash expands inside an inline python program in this script") closed, rather than
one instance of it.

---

## Q2 — is the guard reachable from where it matters?

No, and there is no mechanical protection in the release path.

- `prov_fields-check.py` is run by nothing automatically: it is absent from `run_pipeline.sh`
  (grep of the file lists `01_stage.R`, `02_raster_tag.py`, `03_cog.py`, `style_drift-check.py`,
  `04_gpkg_style.py`, `item_create.py`, `item_validate.py` only) and absent from
  `catalogue_release.sh`. Same for `catalogue_release-check.sh`. This is stated and intended.
- Inside `catalogue_release.sh` the only control against reintroducing the hazard is the
  comment at line 318-325 ("NO BACKTICKS and NO DOUBLE QUOTES anywhere in this program"),
  i.e. a human reading the diff — which this repo's own `code-check.md` rule says is not a
  control.
- The two breakage shapes are not symmetric, which matters for what a release-path check could
  buy:
  - **truncation** (a stray `"`): already fails the whole script at bash parse time
    (finding 2, measured). A shape check on the preflight's output would be redundant.
  - **execution** (a backtick or `$(...)` in a comment): the program still runs, the output is
    unchanged, and the release cannot tell. **Nothing in the release path can see this.**

So a cheap in-release assertion does not close the class that actually shipped. The change that
*would* close it is structural: move the program to `scripts/only_preflight.py` and call it
`python3 scripts/only_preflight.py "$STAC_DIR/$ONLY.json" "$only_bucket"`, after which bash
never expands it and all three findings above become moot. The design already anticipates that
move — `release_preflight_program()` raises a `SystemExit` telling you to re-point it if the
program leaves the inline `python3 -c`. Recommending it as a follow-up, not as a blocker on
this branch.

---

## Q3 — round 3's fixes

Nothing broken.

- `scripts/item_create.py:634,637` — `PROV_PROPERTIES["link_run_uid"]` resolves to
  `link:run_uid` (read statically: `n=8`, `link_run_uid -> link:run_uid`), so the traceability
  print is now joined to the map. The nested `'...'` inside the `f"..."` is single-inside-double
  and parses on the pinned floor (`ast.parse` clean).
- `scripts/catalogue_release.sh:286-289` — "the two `-o /dev/null` calls read a status code, not
  a body" is exact: lines 574 and 581 are the only `-o` uses, line 622 is `-sI` (headers to
  stdout), and line 290 is the only redirect-to-file.
- `scripts/item_validate.py:534-536` — "item_create.py prints that plus one census row, the
  `link:run_uid` one" matches the two print statements in `item_create.py`.
- `scripts/02_raster_tag.py:99-101`, `CLAUDE.md:143-149`, `scripts/README.md:231-237`,
  `prov_fields-check.py:222-226` — all four re-readings hold. `CLAUDE.md`'s "four publish-side
  copies" resolves to `item_create.py` + `02_raster_tag.py` + `item_validate.py` +
  `catalogue_release.sh`'s preflight.
- `bash -n` clean on both shell scripts; `ast.parse` clean on all four touched python files.

Two notes, neither a finding:

- `scripts/prov_fields-check.py:27` — `import re` is now unused; round 3 removed the only
  `re.findall`. Dead import, no behavioural effect.
- `NEWS.md` — "The extension forbids a null — every field is typed `string`" is loose:
  `processing:datetime` is typed `string`, `processing:software` is typed `object` whose values
  are typed `string`. The conclusion (a null is forbidden either way) is correct and verified
  against the schema below; only the one-clause reason is imprecise.

---

## Q4 — load-bearing claims, checked against a command

**(a) "No raster changed, and no `file:checksum` moved."** The strongest claim in the NEWS
entry, and the one with no rollback behind it. Every script that writes asset bytes was diffed
against the base for non-comment change:

```
$ for f in 01_stage.R 02_raster_tag.py 03_cog.py 04_gpkg_style.py style_qml-write.py fp_gpkg.R; do ... done
scripts/03_cog.py non-comment-changed-lines=0
scripts/04_gpkg_style.py non-comment-changed-lines=0
scripts/style_qml-write.py non-comment-changed-lines=0
scripts/fp_gpkg.R non-comment-changed-lines=0
scripts/02_raster_tag.py non-comment-changed-lines=0
scripts/01_stage.R non-comment-changed-lines=0
```

`git diff --name-only 844ba81 HEAD` also shows `03_cog.py`, `04_gpkg_style.py`,
`style_qml-write.py` untouched entirely. `fp_provenance.R` is comment-only as well. The claim
holds: no code that produces an asset's bytes changed, so no `file:checksum` can move.
Separately, `README.Rmd`, `scripts/readme_functions.R` and `README.md` carry no reference to
any renamed property (the 19 `nge:` hits in `index.html` are `change:`/`range:` substrings in
minified JS, not property names — `grep -o 'nge:[a-z_]*' | sort | uniq -c`).

**(b) "An absent value omits its key, forced by the processing extension's schema."** Read from
the schema itself (`curl https://stac-extensions.github.io/processing/v1.2.0/schema.json`),
not from memory:

- `definitions.require_any_field` is an `anyOf` of seven `required` clauses, and the Item arm
  `allOf`s it into `properties` — so an item declaring the extension with no `processing:` field
  is refused. Matches the biconditional in `check_processing_stamp`.
- `processing:datetime`: `{"type": "string", "format": "date-time", "pattern": "(\\+00:00|Z)$"}`
  — a null fails, and `item_validate._UTC_INSTANT` accepts exactly `Z|+00:00`, the same set.
- `processing:software`: `{"type": "object", "patternProperties": {".{1,}": {"type": "string"}}}`
  — a null value fails, a non-string entry fails, and an **empty** `{}` validates, which is
  exactly why `item_validate.py:766` refuses it separately ("An empty object validates and ...").
  That comment is accurate.
- `fields` carries `"additionalProperties": false` with `"patternProperties": {"^(?!processing:)": {}}`,
  so a misspelled `processing:*` key would be refused too.

**(c) "`catalogue_release-check.sh` ALL PASS" and "`prov_fields-check.py` 44/0."** Both re-run
on this HEAD, clean tree:

```
$ uv run python scripts/prov_fields-check.py | tail -1
44 assertions, 0 failed
$ bash scripts/catalogue_release-check.sh | tail -1
ALL PASS
```

**(d) Bonus, since the brief asked about history expansion.** Measured rather than reasoned, on
both shells the script can meet:

```
$ /bin/bash hist.sh          # bash 3.2 (macOS)
RESULT=[ok:x]
$ /opt/homebrew/bin/bash hist.sh   # bash 5
RESULT=[ok:x]
```

with `not!!a problem` inside the double-quoted `python3 -c` body. History expansion is off in a
non-interactive shell on both, so `!` is not a hazard here. With that settled, the *character*
enumeration in `bash_hazards` — backtick, `"`, `\`, `$` — is complete for a double-quoted string
in a non-interactive bash script (it is POSIX's own list, minus `!`). Locale and `IFS` do not
apply: nothing is split inside double quotes, and the result is consumed by an assignment.
`$'...'` is not ANSI-C quoting inside double quotes, and is caught by the `$` arm regardless.

**So: the enumeration of characters is terminal. The two enumerations that are not are the set
the `$` arm subtracts (finding 1) and the region of text it is run over (findings 2 and 3).**

---

## Verdict

Three `fragile` findings, all in the guard rather than in the shipped path, all measured, none
a data-loss route — each current breakage shape fails the release safe. Findings 1 and 2 are
one-expression fixes; finding 3 is a loop. Nothing wrong inside round 3's fixes.
