# stac_floodplains_bc

Publish layer for the floodplain land-cover-change collection `stac-floodplains-bc`. Takes the
per-watershed-group outputs produced by the [`floodplains`](https://github.com/NewGraphEnvironment/floodplains)
driver, converts rasters to COGs, uploads to `s3://stac-floodplains-bc` (us-west-2), and
registers a STAC collection served by the shared `geoserv` pgstac/titiler stack at
`images.a11s.one`.

## Core principle

**No modelling here.** All floodplain + LULC + transition computation lives upstream in
`floodplains` (which uses the `link` / `flooded` / `drift` packages). This repo only stages,
COG-converts, tags, uploads, and registers. If a number needs recomputing, fix it in
`floodplains`, re-run there, and re-publish.

## Layout

- **Rebuild** — `scripts/01_stage.R`, `02_raster_tag.py`, `03_cog.py`, `item_create.py`,
  `item_validate.py`, chained by `run_pipeline.sh`. Makes **no network writes**: publishing is a
  separate command, so a rebuild or smoke test cannot reach S3 or the live catalog. Source data
  comes from `$FLOODPLAINS_DATA` (default `../floodplains/data`).
- **Publish** — `scripts/catalogue_release.sh` (validate → sync → register → verify), over
  `item_register.sh` / `collection_register.sh` / `item_unregister.sh`, with
  `collection_version.py` stamping the release version. Needs AWS credentials and
  SSH, not the source tree, so a release can be cut from a machine that does not hold it.
  (There is no `04_s3_upload.R`; its sync folded into the release script in #14.)
  `--only <item_id>` republishes one live item and never `collection.json` — the single-group
  pilot path (#36), pinned by `catalogue_release-check.sh`.
- `pyproject.toml` + `uv.lock` — the Python env (pystac / rasterio) for `03_cog.py` + `item_create.py`, run via
  `uv run` (auto-syncs). This repo pilots uv for the `stac_*_bc` family (see `stac_dem_bc#16`);
  the conda→uv blocker (GDAL/rasterio wheels) was cleared here empirically.
- `data/` — gitignored (`raw/` staged inputs, `stac/` COG + item outputs).

## Collection model

Served from the shared `stac` DB at `images.a11s.one` — not a dedicated subdomain.

**One item per `(watershed group, species, scenario)` target**, id `<wsg>_<sp>_ff0N` — *not* one per
group. MORR carries two (`morr_co_ff04` + `morr_ch_ff06`), and the collection mixes flood factors,
so any cross-group aggregate must filter on `scenario` or `flood_factor` or it sums different
extents (ff04 = functional floodplain, ff06 = valley bottom).

Assets per item: 3 classified-year COGs + a transition COG, plus **three** GeoPackages —
`floodplain_landcover.gpkg`, `floodplain.gpkg` (ff02/ff04/ff06 delineations), and
`transition_vector.gpkg` (the transition patches alone, ~14% of the bundle's bytes). Every layer of
all three carries `wsg`/`species`/`scenario`, so merged multi-item GeoPackages stay separable by
attribute.

Two of the eleven-plus-one `nge:` provenance properties describe the landcover input (#40):
`nge:landcover_key` is a **fingerprint of what was produced** — the producer's per-year content
digests over cell values plus geometry (floodplains#64), folded to one scalar as `sha256:` of the
text `<year>=<digest>` lines, years ascending, newline-joined — so it moves on one changed cell and
not on a re-written identical file; `nge:landcover_item_hash` is the **identity of what was
read**, a hash over the resolved STAC item ids, which an in-place upstream re-derivation leaves
unchanged. Until #40 the identity was published under the fingerprint's name. The fold rule lives
in `scripts/fp_provenance.R`, and `scripts/fp_provenance-check.R` proves the reader offline against
the producer's own files.

**The provenance floor is a literal a human sets** (#32): `PROVENANCE_FLOOR` in
`catalogue_release.sh`, passed to `item_validate.py --expect-provenance` on a full release, is the
minimum number of items that must carry a non-null `nge:` value. It is never derived from the
build (an expectation that comes from the data cannot be contradicted by it) and has no env
override. It is 0 until the first release that publishes real provenance, and is flipped to the
built count in the same commit as that release's NEWS entry — because from then on an all-null
catalogue is a broken reader, not the forward-only state, and every presence check passes it.

`transition_vector.gpkg` is the only GeoPackage this repo **writes** rather than copies, which is
why `01_stage.R` pins `OGR_CURRENT_DATE` (`scripts/fp_gpkg.R`): without it that asset's published
`file:checksum` would churn on every rebuild while every other asset's stayed stable. Its file and
layer names are deliberately year-free so QGIS `path|layername=` styles survive a change of span.

Loss/gain/net are computed from the transition layer during staging, so published figures trace
directly to the model.

**Class labels ship inside the COGs, as a GDAL Raster Attribute Table** (#34/#35), and as
`classification:classes` on every raster asset — both generated from one `data/raw/classes.json`
that `01_stage.R` ferries from `drift::dft_class_table("io-lulc")`, so the two surfaces cannot
disagree. GDAL cannot embed *category names* in a GeoTIFF on any version; only a RAT embeds, and
only from **GDAL 3.12+**, which is why step 03 is Python (`rasterio.shutil.copy`, a `CreateCopy`)
rather than terra — terra links GDAL 3.8.5 and pushes the RAT back out to a `.aux.xml` sidecar.
A sidecar is not an option here: `catalogue_release.sh` excludes `*.aux.xml` from the sync and
geoserv's titiler sets `CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif,.TIF,.tiff"`, so it could never
fetch one. The transition raster's 81 `from -> to` combinations are coloured by destination class
with the no-change diagonal held back, because no-change is ~91% of valid cells.

## Catalog registration

**Repo-owned since #14** — `catalogue_release.sh` registers over SSH with `pypgstac`, which the
server build installs on the host. The API is deliberately read-only (transactions extension off,
`POST` returns 405), so writes go through `pypgstac` rather than the API. Host is
`${GEOSERV_HOST:-root@geopro}` — the tailnet node name, because the reserved IP changes on a
droplet rebuild.

Registration is an **upsert**: nothing is deleted implicitly, and there is no window where the
collection serves zero items. An item dropped from a build therefore stays live until an explicit
`item_unregister.sh`; the release reports those as orphans and refuses to publish past them
without `--allow-retract`.

**Every full release is a tag** (#19). `catalogue_release.sh` refuses unless HEAD is exactly at a
`vX.Y.Z` tag, the tracked tree is clean, and `NEWS.md`'s top entry names that version; it then
stamps `collection.json` with the STAC Version Extension (`scripts/collection_version.py`)
*before* the validation gate, and step 5 fails the release unless the API serves that version
back. The stamp is release-time, not build-time, on purpose: a version means "the published
catalogue is in this state", the rebuild precedes the tag in every real flow (a build-time stamp
would be the previous tag), and `git describe` on a tagless clone would otherwise publish a
fallback. `item_create.py` never writes a version; `item_validate.py` accepts an unstamped build
and a stamped release but refuses half a stamp. `--only` never publishes the collection, so it
never stamps, and verifies the live version did not move; step 5 also reads the bucket's
`collection.json`, because rtj's reload-from-S3 is harmless only while bucket and API agree. Never
register `collection.json` outside the release — a rebuilt one carries no version. Tags are cut by
hand on the `NEWS.md` commit, as `stac_uav_bc` does; there is no `DESCRIPTION`, so
`/gh-pr-merge`'s bump path does not apply here (tell it to skip its steps 6–9 at merge).

**A published null is invisible from the API.** pgstac stores an item property whose value is
`null` (the row shows the key with `jsonb_typeof` null), and the API omits it on output, while
every non-null value and every asset field round-trips byte-for-byte. Measured 2026-09-02 on the
first `--only` release (#36): all 11 `nge:` provenance properties, published null, came back
absent. So a consumer cannot distinguish "published null" from "never published", and any guard
that needs the distinction must read the row, not the API. The `--only` read-back treats a
build-null / served-absent pair as equal for this reason. If #17's null-means-something contract
is to reach API consumers, the value has to be a non-null sentinel.

The bucket and the server itself are still managed in
[`rtj`](https://github.com/NewGraphEnvironment/rtj), whose `stac_register-all.sh` can reload this
collection **from S3** — harmless, because the release syncs the JSON before registering it, so
bucket and API always agree.

**Bucket versioning is Suspended — there is no rollback.** Every guard in the publish path exists
because of that: a `PARTIAL_STAGE` marker on any skipped group, an item-count floor in
`item_validate.py`, and a pre-sync comparison against the live collection that refuses a build
missing any live item.

## Visibility

**Public** (`.claude/visibility` = public). Keep it that way: no internal-only conventions below the
marker, and no references to private sibling collections or infrastructure detail in tracked files.

<!-- BEGIN SOUL CONVENTIONS — DO NOT EDIT BELOW THIS LINE -->


# Code Check Conventions

Structured checklist for reviewing diffs before commit. Used by `/code-check`.
Add new checks here when a bug class is discovered — they compound over time.

## Shell Scripts

### A guard must not fail toward "skip"
- When a check decides whether to do something consequential (cut a tag, send a
  mail, run a migration), work out which way it fails when the command inside it
  errors. If the error path and the "nothing to do" path look the same, the
  guard is indistinguishable from a working one right up until it silently eats
  the action.
- `IF=$(some-cmd ...)` inside `[ -z "$IF" ]` is the usual shape: the command
  aborts, stdout is empty, and empty reads as "nothing changed". **Assign first,
  test the exit status, then test the value.**
  ```bash
  if OUT=$(git diff --name-only "$A".."$B" -- . "${EXCL[@]}" 2>/dev/null); then
    [ -z "$OUT" ] && NOTHING_CHANGED=1     # only trust emptiness on success
  fi
  ```
- Caught 2026-08-12 in soul's `gh-pr-merge` release gate: the diff aborted, the
  empty output read as "nothing shipped", and a branch of five commits of real
  package changes was classified as needing no release.
- **Test a guard against both known answers before shipping it.** One case that
  should fire and one that should not. The draft above returned the same value
  for both, which reading the code did not reveal.

### An empty result set is not a pass — a loop over nothing exits 0
- The same class one level up, and pointed the worse direction. Iterating a
  result set makes "there was nothing to check" and "everything checked out"
  produce **identical** output: the body never runs, nothing prints, exit 0.
  Where a mis-fired guard silently skips an action, this silently makes an
  affirmative claim of success.
  ```bash
  RUN_IDS=$(gh run list ... | jq '... | .databaseId')   # empty when nothing dispatched
  for RUN_ID in $RUN_IDS; do gh run watch "$RUN_ID" --exit-status; done
  # -> zero iterations, exit 0, caller reports "all green"
  ```
- **Poll for the expected results to exist, then branch on empty explicitly.**
  Absence of evidence has to be reported as absence, not as evidence.
- Caught 2026-08-26 in gq: GitHub never dispatched PR #56's workflows —
  `gh pr checks` said "no checks reported" and the check-runs API returned
  `total_count: 0`. The watch loop exited 0 having watched nothing. The same
  workflows had fired correctly for PR #54 an hour earlier, so this is a
  GitHub-side dispatch miss that can hit any repo at any time. Fixed in
  `gh-pr-merge` step 10; verified against both a SHA with runs and a SHA without.
- Generalizes past CI: any "verify N things" loop where the list is *computed*
  — files matched by a glob, rows returned by a query, hosts resolved from an
  inventory. If zero is a possible answer, zero needs its own branch.
- **The mirror mistake: a boolean exit status collapses several distinct
  outcomes into "not success".** `gh run watch --exit-status` is non-zero for
  cancelled and skipped as well as failed, so a run GitHub *cancelled* gets
  reported as a failure and sends someone to read a log that does not exist.
  This is the safe direction — a false alarm rather than a false pass — but it
  is still wrong, and crying wolf is how a guard stops being read.
  ```bash
  gh run watch "$RUN_ID" --interval 30 >/dev/null 2>&1
  case "$(gh run view "$RUN_ID" --json conclusion -q .conclusion)" in
    success)           ;;
    cancelled|skipped) echo "⊘ superseded, not a failure" ;;
    ""|null)           echo "⚠ could not read conclusion" ;;   # gh failed
    *)                 echo "✗ failed" ;;
  esac
  ```
  Prefer branching on the **reported outcome** over a pass/fail exit code
  wherever the tool exposes one. Caught 2026-08-26 immediately after shipping
  the rule above: `r-lib`'s check workflow sets `cancel-in-progress: true`, so a
  second push to main minutes after a merge legitimately cancels the first run.

### A cross-item consistency check cannot see a defect that hits every item

- A guard that validates items **against each other** — "all records carry the same
  field set", "every partition has the same schema", "no item is missing a key its
  siblings have" — is blind by construction to any defect applied **uniformly**. It
  measures variance, and a uniform loss has none. It passes loudest exactly when the
  whole collection is wrong the same way.
- The tell is a guard with no external reference: nothing it compares against comes
  from outside the set being checked. `expected = max(observed, key=len)` derives the
  expectation from the data, so the data cannot contradict it.
- Caught 2026-09-01 in stac_floodplains_bc#23, before shipping. A new asset was to be
  keyed by its filename stem, `transition_2017_2023` — which was **already** the key of
  the existing transition raster in the same dict. Keying by stem would have overwritten
  the raster in every item. Every downstream check passes: the item still has the
  expected asset count, the uniform-key-set validator sees no variance because all
  items lost the same key, and the release probe samples the single largest asset, which
  is a different one. The raster simply disappears from a published catalogue.
- Pair the consistency check with **one absolute assertion** naming what must exist:
  `assert "transition_2017_2023" in assets and "transition_vector" in assets`. Cheap,
  and it is the only kind of check that survives a uniform defect.
- Same family as *"an empty result set is not a pass"* above: there the set was empty,
  here it is uniformly wrong. Both make "nothing to see" and "all clear" identical.

### A checksum you compute yourself cannot detect corruption that predates it

- Hash-on-write proves an object has not changed **since you hashed it**. It says
  nothing about whether the bytes were right when you hashed them. Verification that
  re-reads the same local file and re-hashes it will agree with itself forever.
- So a corrupt input silently becomes a corrupt *published* artifact carrying a
  checksum that **verifies**, which is worse than no checksum: the field now asserts
  integrity that was never established.
- The gap is upstream of the hash, so guard it there — check the operation that
  produced the bytes. In R specifically, `file.copy()` signals failure by **returning
  `FALSE`**, not by erroring, so an unchecked copy is the classic way a short or absent
  file reaches a hasher. `stopifnot(file.copy(...))`, or the language's equivalent.
- Caught 2026-09-01 in stac_floodplains_bc#23 by review: two `file.copy()` calls fed
  assets straight into checksum computation, and the validator re-hashed the same files.
  A truncated copy would have published bytes plus a checksum confirming them.

### A proxy assertion does not guard the thing it stands for

- When the defect is a **resource** — an allocation, a query count, a number of network
  calls — the natural assertion is a proxy for it: elapsed time. Proxies compress. A
  defect that allocates 243 million cells where the fix allocates sixteen thousand, a
  factor of **14,950**, showed up as 1.0 s against 0.18 s: a factor of 5, and inside CI
  jitter. No threshold separates those, so the test passed on the exact defect it was
  written for.
- Worse, the other assertions in that test passed too, because the defective code
  computed the **right answer** — it just spent absurdly getting there. Correct output is
  not evidence about cost.
- **Assert the quantity that actually differs.** Where it is internal, give it a name and
  observe it, rather than reaching for a wall-clock stand-in:
  ```r
  # name the thing whose size is the invariant
  fly_dem_grid <- function(dem, geom) { ... }

  sizes <- c(); real <- fly_dem_grid
  local_mocked_bindings(fly_dem_grid = function(...) {
    g <- real(...); sizes <<- c(sizes, prod(dim(g)[1:2])); g
  })
  do_the_work()
  expect_lt(max(sizes), bound)          # 14,950x apart, not 5x
  ```
- **A test that observes through a mock must not call the mocked function itself.** The
  baseline computed inside the mocked region records itself and poisons the measurement —
  seen immediately on the first draft of the above. Compute any reference value *before*
  installing the mock.
- Caught 2026-08-29 in fly#9, in a guard written one commit earlier specifically to catch
  that defect, whose commit message asserted it had been verified against a restore.

### git pathspec excludes: use the long form
- `:!path` is short-form magic, and git keeps parsing magic characters after the
  `!`. A path starting with one aborts the whole command:
  `:!_pkgdown.yml` → `fatal: Unimplemented pathspec magic '_'`.
- Use `:(exclude)path`. `:!./path` also works, but the long form says what it means.
- Anything building pathspecs from a file (`.Rbuildignore`, `.gitignore`) will
  eventually meet a leading `_`, `(`, or `^`.

### `sed 1d f1 f2 f3` strips only the FIRST file's header

`sed` treats multiple file arguments as one concatenated stream, so a line-address
script applies once across the whole set rather than per file. Stripping CSV headers
this way — especially via `find … -exec sed 1d {} +`, which batches many files into one
invocation — leaves every header but the first embedded in the data.

It is silent, and it lands rows that parse. Caught 2026-08-30 concatenating 24 paged WFS
responses: 23 stray header rows entered a 223,667-row analysis and showed up only as a
row-count reconciliation failing by exactly 23.

```bash
for f in pages/*.csv; do sed 1d "$f"; done > combined.csv   # per file
awk 'FNR>1' pages/*.csv > combined.csv                      # or FNR, which resets
```

Reconcile the row count against what the source said it would be. That is the check that
catches this, and it costs one line.

### `sed -n '/X/,$d' file` prints nothing at all

`-n` suppresses auto-print, and `d` only deletes — so nothing is ever emitted and the
output is empty. The intent (print up to a marker) needs `sed '/X/,$d'` without `-n`, or
`sed -n '1,/X/p'`.

Fails toward an **empty file**, which downstream reads as "no matches" rather than as a
broken command. Same family as the guards below: the silent direction is the dangerous
one.

### Reading a file line-by-line drops the last line without a trailing newline
- `while IFS= read -r line; do ...; done < file` skips a final line that has no
  newline after it. Use `while IFS= read -r line || [ -n "$line" ]`.

### Empty arrays under `set -u` on bash 3.2
- macOS still ships bash **3.2**, where `"${ARR[@]}"` on an empty array is an
  unbound-variable error under `set -u`. Guard with `[ ${#ARR[@]} -gt 0 ]`
  before expanding. Scripts written and tested on Linux bash 5 hit this only on
  a Mac, and only when the array happens to be empty.

### Quoting
- Variables in double-quoted strings containing single quotes break if value has `'`
- `"echo '${VAR}'"` — if VAR contains `'`, shell syntax breaks
- Use `printf '%s\n' "$VAR" | command` to pipe values safely
- Heredocs: unquoted `<<EOF` expands variables locally, `<<'EOF'` does not — know which you need
- Unquoted heredocs also run **command substitution**: backticks in prose (markdown code spans!) execute and are replaced by their output, usually empty. Writing markdown through an unquoted heredoc silently deletes every `` `word` `` in it — no error, and the damage only shows on re-read. Seen 2026-08-06 writing a memory index line: a markdown code span followed by "gone as a concept" landed as "gone as a concept", subject removed. Any heredoc carrying prose or markdown wants `<<'EOF'`.
  - **The rule collapses the moment you also need interpolation.** `<<'EOF'` is
    the fix for prose and `<<EOF` is the fix for variables, and a heredoc that
    needs both has no safe form — which is exactly when the trap fires, because
    the quoting choice now looks forced rather than careless. Seen again
    2026-08-26 in rfp#186 writing a findings file that had to carry a generated
    project name: `` `normal` `` in a markdown table ran as a command and its
    empty output replaced the word, leaving `| enabled, , **resolves** |`.
    Escaping the backticks individually is not a fix either — you have to get
    every one, and the misses are silent.
  - Fix: keep the heredoc quoted and substitute afterwards, or write the file
    from Python where there is no substitution layer at all:
    ```bash
    cat > out.md <<'EOF'      # prose safe, placeholder left literal
    Project: __NAME__
    EOF
    sed -i '' "s|__NAME__|$NAME|" out.md
    ```
  - Detection is cheap and worth doing whenever prose went through an unquoted
    heredoc: `grep -n ', ,\|(( ))\|  |' file` finds the empty spans a swallowed
    code span leaves behind.
- Pass-through-ssh args: `printf '%q'` escapes per-arg so workload paths with spaces / quotes / metacharacters survive the local-shell → ssh-argv → remote-shell round-trip. Without it, `ssh host 'cmd' "$path"` joins args with spaces on remote and re-parses, losing argument boundaries.
- **A plain `git commit -m "…"` runs command substitution too, and unlike the heredoc cases it
  SUCCEEDS.** The rules above are about forms that fail loudly. This one does not: backticks in a
  double-quoted `-m` string execute, bash prints `something: command not found` to **stderr**, and
  the commit lands anyway with the span replaced by empty output. Seen 2026-09-02 in floodplains:
  a message reading ``prov_keys() now takes a `part` argument`` committed as "now takes a
  argument". The only signal was one stderr line scrolling past above a successful commit.
  - Markdown code spans are exactly what a good commit message is full of — function names,
    arguments, file paths — so the failure targets careful messages, not sloppy ones.
  - Fix is the one already prescribed for multi-line bodies, applied to single-line ones too:
    write the message to a file and `git commit -F`, or use single quotes when the text has no
    apostrophes. `git commit --amend -F msg.txt` repairs it after the fact.
  - Detection, since the commit is already made: `git log -1 --format=%B | grep -n "  \|takes a $"`
    finds the collapsed double spaces an eaten span leaves behind.
- `git commit -m "$(cat <<'EOF' ... EOF)"` chokes on apostrophes in prose bodies in some contexts — the bash parser surfaces an unmatched-quote error even though heredoc bodies should be quote-neutral. Resilient default for multi-line commit messages: write the body to `/tmp/msg.txt` and use `git commit -F /tmp/msg.txt`.
- **The same trap has a silent variant: `Rscript -e` / `python -c` carrying backslash escapes.** The heredoc case above fails loudly, which costs a retry. Passing a regex inline does not: `\\b` reaches the interpreter mangled, so `grepl()` returns 0 matches against text it matches perfectly from a file. Nothing errors. Seen 2026-07-31 in rfp#93 — the 0 read as "my regex is wrong" and nearly triggered a rewrite of working code; the identical regex scored 4 matches the moment it ran from `/tmp/x.R`.
  - Rule: anything carrying a regex, nested quotes or backslashes gets written to a file and run (`Rscript /tmp/x.R`). Inline `-e` is for trivial one-liners only.
  - Diagnostic: when an inline command returns a surprising *result* rather than an error, suspect the quoting layer before the code, and re-run from a file to find out which is wrong. That one step separates a real bug from a shell artifact.

### Merging stderr into stdout corrupts the stdout you are parsing
- `system2(cmd, stdout = TRUE, stderr = TRUE)` (and `2>&1` generally) interleaves
  the two streams **without respecting line boundaries**, so a write on stderr
  can land in the middle of a stdout line. If you are parsing that line, it fails
  — not with a missing value, but with trailing garbage:
  ```
  RFPVALUEMAPS {...,"chain":["finder","surveyor's chain"]}QObject::killTimer: Ti
                                                        ^ parse error here
  ```
- **It only shows up on a long line**, which is what makes it a latent trap: the
  probe worked for a year against a 20-field payload and broke the first time it
  met a 145-field one. Nothing about the change looks related.
- Fix: send stderr to a **file**, keep stdout clean, and read the file back only
  when reporting a failure — so diagnostics are not lost:
  ```r
  err <- tempfile(); on.exit(unlink(err), add = TRUE)
  out <- system2(cmd, args, stdout = TRUE, stderr = err)
  # ... on failure: paste(utils::tail(readLines(err, warn = FALSE), 30), collapse = "\n")
  ```
- Anything chatty on stderr does this — Qt, GDAL, JVM warnings, progress bars.
  Suspect it whenever a subprocess parser fails on *content* rather than on
  absence.
- **And carry the CONTENTS onward, not the path.** The fix above leaves you
  holding a temp file, and the natural next move — attach its path to the result
  and clean it up when the caller returns — destroys the log before the assertion
  that needs it. A probe wrapped in its own helper returns, the file goes, and
  the failure reports `(no stderr captured)` for the one case the file exists to
  explain. Read it immediately and pass the lines:
  ```r
  attr(out, "stderr") <- if (fs::file_exists(err)) readLines(err, warn = FALSE)
                         else character(0)
  ```
  Caught 2026-08-30 in rfp#227, in a helper written that same hour specifically
  to stop losing container diagnostics. It surfaced as an unrelated PyQGIS
  `AttributeError` being invisible — the symptom was "the probe returns
  nothing", which reads as a container that would not start.

### Heredoc precedence in pipelines
- `cmd1 | cmd2 <<EOF` — the heredoc binds to `cmd2` (the rightmost simple command). If you intended `cmd1` to receive it, put `<<EOF` on cmd1 explicitly: `cmd1 <<EOF | cmd2`.
- Symptom when wrong: ssh body silently echoed by tee/cat/etc, ssh side gets empty stdin, exits 0 (or near-0) without doing anything. Caught the hard way 2026-05-01 in cypher_restore-fwapg.sh.

### pipefail with ssh+tee
- `set -eu` does NOT propagate exit codes through pipelines. `ssh ... | tee log` returns tee's exit (always 0 for healthy tee), masking ssh failure.
- Use `set -euo pipefail` for any script that pipes a meaningful command into tee/cat/grep/etc. Or check `${PIPESTATUS[0]}` explicitly.
- Symptom when wrong: task notifications report "exit 0 / completed" while remote work was actually skipped or errored.

### A wrapper's exit 0 is not "the work completed" — gate on in-band error + output mtime
- A wrapper reports its OWN exit, not the inner job's. `caffeinate -s bash -c '...'`, `/usr/bin/time -p …`, and background tasks routinely surface **exit 0 / "completed"** while the wrapped R/Python script hit `Execution halted` partway. The interpreter's error goes to the log, not the wrapper's exit code.
- **Most dangerous in A/B validation:** if the run crashes *before* it (re)writes its output file, a compare step reads the **stale previous output** and reports a false "identical / passed" — a false positive that looks like success.
- Before trusting any run's result, gate on BOTH:
  1. **In-band error markers** — `grep -c "Execution halted\|Error:" "$log"` is 0 (R); the language's equivalent otherwise.
  2. **The output was actually (re)written** — its mtime is newer than a marker touched at run start (`[ output -nt "$marker" ]`), not merely that the file exists.
- Caught the hard way 2026-07 in `floodplains`: a Pass-2 reuse change was declared "12.4×, byte-identical" and **merged to main** — but the run had `Execution halted` before writing, so the A/B compared the unchanged baseline against its own backup. Broke every step-3 run until hotfixed. Same class as the ssh+tee pipefail symptom above, generalized to any wrapped/background job.

### Paths
- Hardcoded absolute paths (`/Users/airvine/...`) break for other users
- Use `REPO_ROOT="$(cd "$(dirname "$0")/<relative>" && pwd)"`
- After moving scripts, verify `../` depth still resolves correctly
- Usage comments should match actual script location

### Diagnose env/PATH problems in the shell that actually runs, not the ambient one
- Get ground truth **before** forming any theory:
  `env -i HOME=$HOME TERM=$TERM bash -lc 'echo $PATH | tr ":" "\n" | nl'`
  (swap in `zsh` to check the other side). Numbering shows ordering and
  duplication in one read.
- **Claude Code runs bash regardless of the user's login shell**, so a PATH
  measured from an agent shell says nothing about the terminal the user sees.
  Establish which shell is interactive (`echo $0`, or the prompt style) before
  opening any rc file.
- **The mutation is usually one level down from the obvious file.** A
  `for file in ~/.{path,exports,aliases,extra}; do source "$file"; done` loop in
  `.bash_profile` hides real `PATH=` assignments in files you never opened. Grep
  every sourced file, not just the rc files.
- Caught 2026-08-19: a 39-entry PATH with 12 duplicates took **three** wrong
  diagnoses — `.zprofile` (which did run `brew shellenv` five times, but the
  interactive shell was bash, so it was irrelevant), then `.bashrc` sourcing
  `.bash_profile`, then tmux inheriting a stale env. The cause was `~/.path`
  hand-prepending what `brew shellenv` already sets, plus three directories that
  no longer existed. One `env -i` run ended it.
- The same mistake closed an infra issue prematurely: MacPorts was removed and
  verified **in bash**, while `.zprofile` kept exporting `/opt/local/bin` on
  every zsh login for months. Verified in one shell, broken in the one that runs.

### Silent Failures
- `|| true` hides real errors — is the failure actually safe to ignore?
- Empty variable before destructive operation (rm, destroy) — add guard: `[ -n "$VAR" ] || exit 1`
- `grep` returning empty silently — downstream commands get empty input

### A preview flag is only safe if it previews

- `--dry-run`, `DRY=1`, `--plan` conventionally mean "show me what would happen".
  **Nothing enforces that.** A flag that skips the *expensive* step while still
  performing the *destructive* one is worse than no flag, because it is exactly
  what people reach for when they are unsure.
- Symptom: you run the preview to check something unrelated, and `git status`
  afterwards shows deletions you never asked for.
- Caught 2026-08-27 in floodplains#44: `run_region.R` prints
  `[DRY] plan + configs written; no pipeline runs` — it skips the pipeline, not
  the config write. A `DRY=1` run to verify an unrelated one-line change deleted a
  watershed group's second-species scenario rows, every literature citation in two
  `flood_scenarios.csv` files, and a `break_points.csv`. 50 deletions from a
  command documented as "plan only".
- Before trusting one, read what it actually gates. If you own it, make the flag
  return **before the first write**, not before the first slow call.
- Cheap audit either way: run `git status` immediately after a dry run.

### A new feature can silently invalidate an unrelated flag's stated rationale

- The rule above is about a flag that lied from the start. This is the one that
  **becomes** a lie: a skip/fast-path flag is documented with a reason that is
  true and sufficient when written, a later feature changes what one of its
  premises implies, and the flag keeps its old comment and its old behaviour.
  Nothing links the two, so nothing flags it — the flag was not touched, and the
  new feature's own tests all pass.
- Shape: `--skip-<expensive step>` justified as *"X is already done and Y still
  resolves"*. The feature adds a **stronger** guarantee that Y no longer implies.
- Caught 2026-09-01 in stac_floodplains_bc#22. `--skip-sync` skipped the S3 upload
  and registered from local JSON, on the stated grounds that "the assets are
  already up and every href still resolves". Adding `file:checksum` made that
  insufficient: href-resolves stopped implying bytes-match, so the flag could
  publish a checksum for objects that were not on S3 — the exact failure the
  feature existed to prevent. Found by review, not by any test.
- Two habits, and the second is the one that generalises:
  - When adding a guarantee, **grep the flags and fast paths that bypass the step
    now producing it**, and re-read each one's stated reason against it.
  - **Upgrade the verification to check the new property, not the old proxy.** The
    release verify compared `Content-Length`; comparing the actual checksum is
    what closed it, and would have caught this without the review.
- Same family as the `--size-only` entry elsewhere in this file: a comment
  explaining why a shortcut is safe is load-bearing, and its premises expire.

### `git add -A` after a generator sweeps its side effects into your commit

- Config regenerators, formatters, codegen, lockfile updaters and "plan" commands
  all rewrite files you did not edit. Staged wholesale, they ride into a commit
  whose message describes something else, and the diff stat is the only warning.
- Stage the paths you actually changed (`git add <path>`), or read
  `git diff --cached --stat` before committing and reconcile every file against
  your intent. **A commit touching six files when you edited one is the signal.**
- Caught 2026-08-27 in floodplains, same session as the dry-run entry above and
  compounding with it: the preview created the unexpected changes and `git add -A`
  committed them — a "one-line config change" of 6 files, 28 insertions and
  **50 deletions**. Reset before it left the branch, but only because the file
  count looked wrong.

### Running a generator is not committing what it generated

- "Verified: the builder runs clean and the new field is present" is a true
  statement about the **generator**. It says nothing about the artifact in the
  repo, because the build happened in a temp dir or in memory and was never
  written back. The commit then carries the input and not the output, and every
  consumer reads the stale artifact.
- It is convincing precisely because real verification happened. The author ran
  the thing, read the output, and confirmed the change — so the natural
  follow-up question ("did you test it?") gets a confident yes.
- Caught 2026-08-28 in rfp#219: four form schema CSVs gained a `site_id` column
  and the PR body recorded a genuine check — `rfp_form_build("viewscape", ...)`
  built clean, 25 fields, `site_id` in both the GeoPackage and the QML. The
  GeoPackages and QMLs a field crew actually deploys were never rebuilt. CI
  caught it only because a drift guard rebuilds every shipped schema and
  byte-compares against the committed artifact.
- Two habits: run the repo's own regeneration script rather than the function
  (`data-raw/*/build_*.R` exists to write the artifacts, not just exercise the
  builder), and check `git status` afterwards — an edit to a generated tree that
  produces no diff is the tell.
- **Keep a guard that compares committed artifacts to their inputs.** Without
  one this is invisible until something downstream reads the artifact, which is
  usually in the field. With one it is a red CI check thirty seconds after push.

### Never silence stderr on a mutating command, and never chain one with `;`

- `cmd_that_moves_things 2>/dev/null; next_command` combines two mistakes that
  cover for each other. The redirect hides the diagnostic, and `;` runs the next
  command regardless — so a mutation that "succeeded" doing the **wrong thing**
  leaves no trace, and the only symptom is an unrelated error one command later.
- Caught 2026-08 archiving a planning directory:
  ```bash
  git mv planning/active $(basename planning/active) 2>/dev/null; mv planning/active "$dest"
  ```
  The `git mv` succeeded — it moved `planning/active` to `./active` at the repo
  root, which is not what was meant. Nothing said so. The failure surfaced as
  `mv: cannot stat 'planning/active'` from the *next* command, which reads like
  the directory was never there.
- Two rules, and the first is the load-bearing one:
  - **`2>/dev/null` belongs on reads, not writes.** A probe that may legitimately
    fail (`grep -q`, `test`, a `gh` call you expect to 404) can be quiet. A
    command that moves, deletes, or writes must be allowed to speak.
  - **Chain mutations with `&&`.** `;` between two steps of one operation says
    "these are unrelated", which is exactly what they are not.
- Same class as the `set -e` / pipefail entries above, but it survives them: `;`
  defeats `set -e` for the preceding command by design, so a script with
  `set -euo pipefail` at the top is not protected.

### `cmd > file` truncates before `cmd` runs — a failed command leaves a poisoned empty file
- The shell creates/truncates the redirect target **before** the command executes. If the command then fails (times out, wrong arg, no network), you're left with a **zero-byte file** — not the absence of a file. `set -euo pipefail` does not save you: the truncation already happened before the command's non-zero exit fires.
- The trap springs on the *next* run when an **existence-only guard** treats that empty file as valid: `[ -f "$f" ] || cmd > "$f"` sees the file, skips regeneration forever, and every downstream reader silently consumes an empty value. For a secret/credential cache this reads as a confusing auth failure (empty header → `403`) with no obvious cause.
- Caught 2026-08 in cyclops#10: `op read "op://..." > ~/.config/newgraph/zotero-api-key` guarded by `[ -f ]` — a timed-out 1Password approval would have written an empty file that the guard then blessed permanently.
- Fix — three parts:
  1. Guard on **non-empty**, not existence: `[ -s "$f" ]`.
  2. Write **atomically** so a partial/failed run lands nothing: `cmd --out-file "$tmp" && chmod … && mv "$tmp" "$f"` (or `cmd > "$tmp" && mv`), with `trap 'rm -f "$tmp"' EXIT`.
  3. Prefer a tool's own `--out-file`/`-o` over `>` where it exists — the value never transits stdout, so `set -x`/`tee`/a pipeline can't capture it.

### Empty is not unset — `VAR=` passes a presence check that `unset` fails
- A command-scoped assignment built from fallbacks, `VAR="${A:-${B:-}}" cmd ...`, sets `VAR` to the **empty string** when neither source is set. That is not the same as leaving it unset, and for a tool that branches on *presence* rather than truthiness it is worse than both.
- Measured 2026-07-31 (rfp#93): rasterio tests `"PROJ_LIB" in os.environ` — a membership test an empty string passes — then calls `set_proj_data_search_path("")`, suppressing its own bundled `proj_data`:
  ```
  PROJ_LIB=   rio warp ... -> Error: Cannot find proj.db
  (unset)     rio warp ... -> EPSG resolves normally
  ```
  It surfaced as a missing-dependency error, not a quoting bug, and only on installs whose PROJ layout the caller could not introspect — so the fallback chain looked like the culprit.
- Same shape wherever presence is the test rather than value: Python `os.environ`, bash `[ -v VAR ]`, R `Sys.getenv(x, unset = NA)`.
- Fix — build the command as an array, add the assignment only when there is a value:
  ```bash
  cmd=("$TOOL")
  if [ -n "${MY_VAR:-}" ]; then cmd=(env "REAL_VAR=$MY_VAR" "${cmd[@]}"); fi
  "${cmd[@]}" ...
  ```
- Do not write `[ -n "$X" ] && arr=(...)` as a bare top-level list: under `set -e` a false test makes the list return non-zero and aborts the script. Use an explicit `if`.

### Parallel writers sharing one output file interleave mid-record
- `xargs -P N ... >> shared_file` (or any fan-out where N processes append to the same fd/path) is only safe while each record fits in a single `write()`. O_APPEND makes individual `write()` calls atomic, but a large record (anything beyond pipe/stdio buffer size, ~64 KB) spans multiple writes — concurrent jobs interleave mid-record and corrupt the file.
- The trap is latent: small records never trip it, so the pattern looks proven until the first large payload arrives. Caught 2026-07-11 in rtj's `stac_register-pypgstac.sh` — 20 parallel `curl | jq -c` jobs appending STAC items to one NDJSON worked for every prior collection (KB-scale items), then 9 MB floodplain items interleaved and produced an orjson decode error ~864 KB into line 1.
- Fix pattern: each parallel job writes its own temp file (unique name, e.g. md5 of the input), concatenate after the fan-out completes:
  ```bash
  cat urls.txt | xargs -P 20 -I {} fetch_one.sh {} "$OUT_DIR"   # each writes $OUT_DIR/<md5>.json
  find "$OUT_DIR" -maxdepth 1 -name '*.json' -exec cat {} + > combined.ndjson
  ```
- **Concatenate with `find -exec … +`, never `cat "$OUT_DIR"/*`.** This fix is what
  creates the file count that then blows `ARG_MAX` — see "`cmd dir/*` dies on
  ARG_MAX at scale" below. The two traps are a matched pair, and writing the glob
  form here is what put the bug into rtj's registration script twice.
- Pair with a count guard — parallel `curl` failures under xargs are also silent: `[ "$(wc -l < combined.ndjson)" -eq "$EXPECTED" ] || exit 1` before any downstream load.

### `mktemp` template needs enough X's, and a failed `mktemp` leaves an empty var
- BSD/macOS `mktemp -d -t <name>` requires the template to contain at least 3 `X`s (`XXXXXX` is the safe default). Without them, mktemp errors to stderr (`too few X's in template`) and **prints nothing to stdout**.
- Pattern: `SCRATCH=$(mktemp -d -t aider-smoke) && cd "$SCRATCH" && <destructive>`. When mktemp fails, `$SCRATCH=""`. `cd ""` is a no-op that **leaves you in the caller's cwd**. The destructive command (`rm`, `git init`, `git add+commit`) then runs in cwd instead of a throwaway tmpdir.
- Caught the hard way 2026-05-13: a Claude smoke test inside the rtj checkout did exactly this, accidentally committed a `demo.R` to the active feature branch, which then rode the squash-merge into rtj/main and had to be cleaned up post-merge.
- Fix patterns:
  - Always use `XXXXXX` (6 X's) in the template: `mktemp -d -t aider-smoke.XXXXXX`.
  - Guard the result: `SCRATCH=$(mktemp -d ...) || exit 1; [ -n "$SCRATCH" ] || exit 1`.
  - Use `set -euo pipefail` so the failed command-substitution kills the script.

### `cmd dir/*` dies on ARG_MAX at scale — and only after the expensive work succeeded

- A glob expands to argv. 98k filenames is roughly 6 MB against a ~2 MB limit, so
  `cat "$DIR"/*.json` fails with `argument list too long` — **after** whatever
  produced those files already succeeded. Silent-after-success: the costly stage
  worked and the cheap one threw it away.
- Caught 2026-07 in rtj#196: it killed a STAC registration following a completed
  80-minute download.
- **Recurred 2026-08-29 in the same script**, because #196 wrote this entry but
  never repaired `rtj/scripts/geoserv/stac_register-pypgstac.sh`, and the
  parallel-writers entry above still prescribed the glob. 102,460 downloaded item
  JSONs concatenated fine with `find`; the load then took 27 seconds. The costly
  stage had already succeeded both times.
- The cost is worse than a wasted download when the script **deletes before it
  loads**: that registration removes the collection in step 2, so failing in step
  4 left a live public API serving zero items until it was repaired by hand. A
  destructive-then-rebuild sequence turns "retry it" into an outage.
- Safe form — `find` batches under the limit itself:
  ```bash
  find "$DIR" -maxdepth 1 -name '*.json' -exec cat {} + > combined.ndjson
  ```
- The trap is latent, and it rides in on the fix for a different one:
  per-file fan-out (see "Parallel writers sharing one output file interleave
  mid-record" above) is correct, and it is exactly what produces the file count
  that later blows argv. Small sets look proven for as long as you test on them.

### A `curl` in a parallel fan-out needs `--max-time`

- Without it, one hung connection pins a worker slot indefinitely. Since a fan-out
  usually prints nothing until it finishes, a wedged pool and a slow pool look
  identical from outside — there is no signal to distinguish "still working" from
  "will never finish".
- Set `--max-time` on every per-URL fetch, and pair any silent multi-minute stage
  with a periodic progress line (a file count is enough). Same reasoning as
  `statement_timeout` on long DB work: the point is to fail loud rather than hang
  quiet.

### BSD vs GNU sed/grep portability (macOS hits this constantly)
- macOS ships BSD `sed`/`grep`. Linux CI/cloud-init hosts ship GNU. Snippets that work on one silently misbehave on the other.
- **`\+` and `\|` are GNU BRE extensions.** On BSD they're treated as literal `+` and `|`, so the regex still "matches" but matches nothing useful — leaving raw input unchanged.
  - Symptom seen 2026-05-28: `sed 's/[^a-z0-9]\+/-/g'` on macOS left spaces in an issue-title slug, producing an invalid git branch name.
  - Fix: use `sed -E` (POSIX ERE) so `+`, `|`, `?`, `(...)` all work without escapes on both flavors. The same regex becomes `sed -E 's/[^a-z0-9]+/-/g'`.
- **`s|pat|repl|` delimiter conflicts with `|` in alternation/replacement on BSD.** Pick a delimiter that does not appear in pattern or replacement (`#`, `,`, `:` are common choices). Compound `s|x|y|; s|^| /||` chains where the trailing `||` looks like an empty delimiter break on BSD sed even when GNU accepts them.
- **Don't parse `ls`.** BSD `ls` emits ANSI colour codes when stdout is a TTY *or* when `CLICOLOR_FORCE` is set in env (often by shell rc files), and the codes leak through pipes. Downstream `grep`/`sed` chokes on the embedded escapes (`[01;31m...[0m`).
  - **A third cause, and the one that bites agents: an alias in the invoking shell.** Measured 2026-08-28 — in an agent Bash call `ls` was aliased to `command ls --color`, so `ls -A dir | grep -v '^\.gitkeep$'` returned `^[[0m^[[00m.gitkeep^[[0m`, the grep failed to filter it, and a directory-empty guard false-failed on a correct tree. The identical command was fine inside a script file, where no alias applies and `ls` resolved to GNU coreutils — so testing it from a script *proves nothing about how it will run inline*. `CLICOLOR_FORCE` was not involved in that instance; check `type ls` before trusting either.
  - Use `find <dir> -maxdepth 1 -mindepth 1 -type d -exec basename {} \;` for directory listings, or `printf '%s\n' <dir>/*/` for a glob, or `for d in <dir>/*/; do basename "$d"; done`.
- **When writing a snippet you expect to ship in a `skills/` SKILL.md or any cloud-init runcmd**: it must be POSIX-portable. Default to `sed -E`, avoid `\+`/`\|`, and don't pipe `ls`.

### `&` binds to the whole `&&` list, so assignments never reach the parent

- `cmd1 && VAR=$(...) && nohup prog > "$VAR.log" & disown` backgrounds the
  **entire list**, not just `nohup`. `VAR` is assigned inside the background
  subshell, so it is empty in the parent — and a following `tail -f "$VAR.log"`
  reads the wrong path or errors while the job runs fine, writing somewhere you
  are not looking.
- The symptom lies about which side failed: the `tail` says
  `No such file or directory`, which reads as "the job never started". It started.
- Fix: assign **before** the list — `VAR=$(...); cmd1 && nohup ... &` — or
  `printf` the resolved path from inside the backgrounded shell so the parent can
  read it from output.
- Hit twice in one floodplains session (2026-08-27) launching detached runs.

### `gh` CLI
- **`gh pr create` resolves branch from CWD, not `--repo`**. Specifying `--repo NewGraphEnvironment/X` does NOT switch branch resolution — the command still reads the current working directory's checked-out branch. To open a PR in repo X, `cd` into X's checkout first, or pass `--head <branch>` explicitly.
- **`gh issue create` / `gh pr create` with heredoc bodies fail on prose containing special shell characters** (apostrophes, dollar signs, backticks). Use `--body-file /tmp/issue.md` instead — every project's `newgraph.md` convention specifies this; codified here for the underlying class. The two are written interchangeably, so the trap applies to both: `gh pr create --body "$(cat <<'EOF' … EOF)"` breaks the parser on a prose apostrophe and bash reports `unexpected EOF while looking for matching '"'`, aborting the whole command before anything runs.
- **A stacked PR is retargeted when its base branch is DELETED, not when the base
  PR merges.** Merge the base and the child still points at a merged branch:
  `gh pr view` reports it `MERGEABLE`/`CLEAN`, so nothing looks wrong, and merging
  it there is a no-op against history that is already on main. Relying on the
  deletion side-effect is worse than it sounds, because the natural cleanup order
  is merge-then-delete and a `--delete-branch` on the base silently rewrites the
  child's base as a side effect of tidying. Retarget explicitly, then re-read the
  state before merging:
  ```bash
  gh pr merge "$BASE_PR" --merge          # no --delete-branch yet
  gh pr edit "$CHILD_PR" --base main      # explicit, not a side effect
  gh pr view "$CHILD_PR" --json mergeable,mergeStateStatus,statusCheckRollup
  ```
  Checks are attached to the head SHA, not the base, so they survive the
  retarget — but confirm rather than assume, since a required check configured
  per-base may not. Seen 2026-08-30 merging rfp#231 then rfp#234.
- **Before you *cut* a branch, verify local is current with origin.** The mirror of the
  rule below, and easier to miss because everything about the working tree looks fine. A
  clean tree and the right branch name say nothing about whether that branch is 19 commits
  behind. A branch cut from a stale base regenerates its content from stale input, and the
  PR either conflicts (loud, cheap) or auto-merges non-overlapping hunks and quietly
  reverts someone's newer edit (silent, expensive). Assert it:
  ```bash
  git fetch -q origin
  [ "$(git rev-list --count HEAD..@{u})" -eq 0 ] || { echo "local behind origin"; exit 1; }
  ```
  Caught 2026-08-28 syncing CLAUDE.md across 25 repos: preconditions checked clean-tree
  and on-default-branch but not up-to-date. `nrp-nutrient-loading-2025` was 19 behind, one
  of those commits having touched the same file, and the PR conflicted. The 24 that merged
  cleanly still had to be proven safe after the fact — by asserting the sync commit changed
  nothing above the CLAUDE.md marker, which is the invariant the operation actually claimed.
- **A per-item loop reports the wrapper's exit, not the items'.** `for r in ...; do
  script "$r"; done` exits 0 whenever the *last* item succeeds, however many failed before
  it. The task notification then says "completed (exit code 0)" over a batch with real
  failures in it. Same family as the wrapped-job trap above, and the fix is the same shape:
  gate on in-band markers. Print a per-item `OK`/`FAIL` line and count the FAILs, or
  accumulate `RC=$((RC+1))` and `exit "$RC"`. Never read a loop's exit as "all items
  succeeded".
- **Distinguish "the action failed" from "the cleanup after it failed".** A wrapper that
  treats any non-zero from `gh pr merge` as *merge failed* will report a false negative
  when the merge succeeded and only `--delete-branch` errored. Two of three failures in the
  same 2026-08-28 run were misreported this way — one had already merged. Re-read the
  authoritative state (`gh pr view --json state`) before acting on a failure report, rather
  than trusting the exit code of the compound command.
- **And the same compound can half-succeed while reporting success.**
  `gh pr merge --delete-branch` deletes the local branch before the remote one, so a local
  delete that fails takes the remote delete with it — and the command still reports the
  merge as done, because it was. Observed 2026-08-31: a **worktree** held the branch, `gh`
  printed `failed to delete local branch ... used by worktree at ...`, and the remote
  branch survived. Nothing else in the output suggested a branch had been left behind.
  Benign in isolation; it matters because a surviving branch reads as unmerged work to the
  next person, and because the `git worktree` advice elsewhere in this file makes the
  trigger routine rather than exotic. Confirm the deletion rather than assuming it, and
  verify the branch is merged before cleaning up by hand:
  ```bash
  gh pr merge "$PR" --merge --delete-branch
  git ls-remote --heads origin "$BRANCH"        # expect empty
  git merge-base --is-ancestor "$BRANCH_SHA" origin/main \
    && git push origin --delete "$BRANCH"
  ```
- **Never send a push's stderr to `/dev/null`.** The rule below assumes you *notice* an
  unpushed branch. Suppressing the push's error removes the only signal that it happened,
  and the very next step in the usual sequence — `git branch -D` after a merge — then turns
  the commit into a dangling object. `git push -q ... 2>/dev/null` is the shape; `-q`
  already silences success, so the redirect can only ever hide a failure. Caught 2026-08-29
  in soul: a suppressed rejection meant `gh pr create` had no branch to open against, the
  cleanup deleted the branch anyway, and the commit survived only via `git reflog`. Keep
  stderr, or test the exit status explicitly:
  ```bash
  git push -u origin "$BRANCH" || { echo "push failed"; exit 1; }
  ```
- **Before `gh pr merge`, verify the branch is fully pushed.** `gh pr merge` merges the REMOTE branch — commits made locally but never pushed are silently excluded, so the PR merges "successfully" while `main` is missing work you know you committed. Check `git status -sb` shows no `ahead N` before merging (or that `git rev-list --count @{u}..HEAD` is 0). Worse: if you then delete the local branch (`--delete-branch`, or a follow-up `git branch -D`), the unpushed commits become **dangling** — recoverable via `git reflog` / `git fsck --lost-found` then `git cherry-pick`, but only if you notice they're missing. Caught twice 2026-07 in `floodplains`: PR #6 merged 1 of 3 branch commits (the drift#34 `changes_only` fix + a CLAUDE.md update were unpushed → stranded as danglers → recovered and re-merged via a follow-up PR); a second branch sat 4-ahead-unpushed at compact time. The same check belongs in the `gh-pr-merge` skill's pre-merge step.

### Process Visibility
- Secrets passed as command-line args are visible in `ps aux`
- Use env files, stdin pipes, or temp files with `chmod 600` instead

## Spatial CLIs (bcdata, ogr, gdal)

### Negative coordinates get parsed as CLI options — every BC bbox hits this
- BC longitudes are all negative, so `--bounds -124.73 49.485 -124.595 49.565` fails with `Error: No such option: -1`. The parser sees a leading `-` and reads it as a flag. Affects click/argparse-based tools generally, not just bcdata.
- Use the **bracketed single-argument form with `=`**: `--bounds="[-124.73, 49.485, -124.595, 49.565]"`. The `=` keeps the value attached to the option, and the brackets keep it one token. A bare comma-joined string (`--bounds "-124.73,49.485,..."`) is not equivalent — it threw an unrelated traceback.
- Same class: any CLI taking negative numbers (elevation offsets, `--nodata -9999`, buffer distances). Reach for `--opt=value` by default rather than discovering it per-tool.

### bcdata: an empty result raises AttributeError, it does not return an empty collection
- A bbox query matching nothing exits non-zero with `AttributeError: You are calling a geospatial method on the GeoDataFrame, but the active geometry column to use has not been set.` — geopandas complaining about an empty frame, several layers below the query.
- The trap: that reads as a broken query, not as "zero features," so a real and meaningful **absence** looks like tooling failure. Don't conclude a layer is unavailable from this error.
- **Prove absence before acting on it.** Re-run the same query against a wider bbox known to contain features; if that returns rows, the empty result is real data. Caught 2026-08-22 establishing that BC's FTEN trail layers are genuinely empty over an entire island — the wider-box control returned 851 features, which is what turned "the query is broken" into "the province has no trails here."
- Wrap counts defensively: `try: json.load(...)` around the parse, and treat the failure as `0 features` only after the wider-box control passes.

## Security

### Secrets in Committed Files
- `.tfvars` must be gitignored (contains tokens, passwords)
- `.tfvars.example` should have all variables with empty/placeholder values
- Sensitive variables need `sensitive = true` in variables.tf

### Firewall Defaults
- `0.0.0.0/0` for SSH is world-open — document if intentional
- If access is gated by Tailscale, say so explicitly

### Credentials
- Passwords with special chars (`'`, `"`, `$`, `!`) break naive shell quoting
- `printf '%q'` escapes values for shell safety
- Temp files for secrets: create with `chmod 600`, delete after use

### Gitleaks pre-commit hook
Configuration patterns and false-positive handling for the `gitleaks` pre-commit hook (kdot's Brewfile ships `gitleaks` + `pre-commit`; cyclops standardizes the hook):
- **`.gitleaks.toml` schema in v8.30+**: top-level table is `[[allowlists]]` (PLURAL, array of tables). Each entry MUST include at least one of `commits` / `paths` / `regexes` / `stopwords`. The singular `[allowlist]` and `fingerprints = [...]` forms shown in older docs fail to validate. Use `paths` + `regexes` together for targeted file-and-content allowlists. Example in `soul/.gitleaks.toml`.
- **PEM marker regex spans multi-line**: gitleaks's `private-key` rule is `(?i)-----BEGIN...PRIVATE KEY-----[\s\S]*-----END...-----`. It matches across comment prefixes, blank lines, and code-fence boundaries. **Commenting out the markers does NOT neutralize the match.** Only fix in content is to omit the literal `-----BEGIN/END...-----` strings entirely and replace with prose ("Paste your private key here, preserving headers" etc.). See the `rtj` cypher `tfvars.example` precedent.
- **`curl-auth-header` rule false-positives on non-auth headers**: matches any `-H "X: Y"` shape, not just credential-bearing headers. Trips on docs with custom CORS or app-specific headers (e.g. `Zotero-Allowed-Request: true`). Fix: targeted `[[allowlists]]` with `paths` + `regexes`. Don't path-allowlist the whole file unless content is entirely safe.
- **`pre-commit install` legacy-hook handling**: running `pre-commit install` on a repo with an existing `.git/hooks/pre-commit` renames it to `.legacy` and keeps invoking it after framework hooks. No breakage, but means hook surface is split between `.pre-commit-config.yaml` and `.git/hooks/pre-commit.legacy`. For full visibility, migrate the legacy check into `.pre-commit-config.yaml` as a `local` hook so the whole hook surface is declared in one place.
- **AWS canonical example keys are allowlisted by default** (`AKIAIOSFODNN7EXAMPLE` etc.) — don't use those in test fixtures expecting a block. Use `ghp_`-shape PAT lookalikes or other non-allowlisted patterns for hook-trigger tests.

### "Public bucket" ≠ listable: GetObject vs ListBucket
- A bucket policy granting only `s3:GetObject` on `bucket/*` makes exact-key fetches public but NOT listing — and dataset discovery (`arrow::open_dataset()`, duckdb globs, STAC `/vsicurl/` directory reads) requires `s3:ListBucket` on the **bucket ARN** (no `/*`; it's a bucket-level action).
- The breakage hides: anyone with ANY ambient AWS credentials lists fine, so "anonymous access works" goes unverified for years. Caught 2026-07-18 (water-temp-bc#23 → rtj#187): anonymous `open_dataset()` had never worked on a bucket whose whole purpose was credential-less querying.
- Review checks: for an open-data bucket, the policy needs BOTH statements (GetObject on `bucket/*`, ListBucket on `bucket`); acceptance-test anonymous access from a credential-stripped environment (`env -u AWS_ACCESS_KEY_ID ... AWS_CONFIG_FILE=/dev/null`). Note ListBucket makes the full key listing publicly enumerable — intended for open data, wrong for mixed-content buckets.

## Spreadsheets

### A stored value is not wrong just because the raw number looks wrong

Before reporting that a spreadsheet value is off by a factor, check the cell's
**number format**. A cell formatted `0.0%` multiplies by 100 for display: stored
`0.028` renders as `2.8%`. Reading raw values with `readxl` and comparing them against
what the column header implies will make correct data look 100x wrong.

- `tidyxl::xlsx_formats(path)$local$numFmt[cell$local_format_id]` gives the format.
- The header text is not the signal. A column headed `(%)` may legitimately store a
  proportion, because the format supplies the percent.

**Why:** this cost a full wrong turn in the fish data submission work — a formula
`AVERAGE(...)/100` was reported as a provincial template defect, a correction notice to
the ministry was drafted, and the "fix" would have shipped `280.0%` where `2.8%` was
meant. Caught only because a human opened the file and looked at it.

### Verify PDF links from the annotations, not the extracted text

`pdftotext` returns anchor text, not the href. A link whose anchor reads "here" leaves
no URL in the text layer, so grepping the text proves nothing either way. Extract the
annotation instead:

```bash
qpdf --qdf --object-streams=disable in.pdf - | strings | grep -oE 'https?://[^ )>]*'
```

`pdftotext` also splits ligatures — "fish" comes out as " sh" — so a grep for any term
containing `fi`, `fl` or `ffi` can report a false absence.

### Extracted PDF text carries corrupted glyphs, and a tolerant parser turns them into wrong numbers

Worse than the ligature case above, because it fails silently with a plausible value
rather than a missing match. Three shapes, all met in one set of 18 camera calibration
reports (fly#32, 2026-08-30):

| what the PDF renders | what it means | what a naive parser does |
|---|---|---|
| `2001Opixel` | 20010 | `gsub("[^0-9.]", "", x)` **deletes** the O and returns 2001 |
| `Pixel Size [<U+F06D>m]` | `[µm]` in a Symbol font | a literal `\[µm\]` misses; a human reading the extract sees `[m]` and takes **metres** |
| `Pixel Size  5.200 m` | 5.200 µm, sign dropped entirely | reads as metres — a factor of 10^6 |

The micron sign is the common one: U+F06D is a **Private Use Area** codepoint emitted by
Word-generated PDFs, so it is neither `µ` (U+00B5) nor `μ` (U+03BC) and matches neither.

Three habits:

- **Anchor on the label, not the unit.** Take the first number on the `Pixel Size` line
  rather than matching a unit that is written three different ways.
- **Never strip non-digits to "clean" a number.** That silently deletes a corrupted
  glyph instead of failing on it. Substitute deliberately (`[Oo]` preceded by a digit
  → `0`) and let an independent check prove the result.
- **Have an independent identity to check against.** These reports state pixel count,
  pixel size *and* image size in mm, so `px × pitch == mm` catches any one of the three
  being wrong — which is what made the O→0 substitution safe rather than reckless. Where
  the document states only two of the three, the check is vacuous; know which rows those
  are rather than counting them as passes.

## R / Package Installation

### Read-back shape must match write-back shape

A script that reads a file, transforms it, and writes it **back to the same path** is
idempotent only if the reader accepts the shape the writer produces. If it reads with
`col_names = FALSE` expecting raw input but writes a parsed frame with headers, the
second run parses its own output as data.

The damage is worst when the file carries a join key. In the fish data pipeline a
pit-tag merge re-derived `rowid` every run and wrote it back; a second run would have
appended the same 53 tags again and renumbered the key joining tags to individual fish,
silently shifting five prior years of records. A type error was the only thing that had
prevented it.

- Guard the merge on a natural key (`anti_join` on the id), not on run count.
- Write back only when there is something new.
- Test by running twice and diffing the file — `cmp` should report no change.

### Moving prose into a code chunk hides it from tools that scan the document

- Tools that scan an R Markdown document for prose — citation detection,
  cross-references, spell-check, word counts — skip code chunks. Making a section
  conditional by moving it into a `results='asis'` chunk therefore removes it from
  everything that was reading it as prose, with no error.
- Caught 2026-08 in `template_permit_fish`: the move hid the section's `[@key]`
  citations from `rbbt::bbt_detect_citations()`, and the next `bbt_write_bib()`
  **overwrote `references.bib` with zero entries** — breaking citations in every
  document sharing that Rmd, not just the one changed. The symptom is `(key?)` in
  the rendered output, far from the edit that caused it.
- Fix for rbbt specifically: pass keys used inside chunks explicitly —
  `bbt_write_bib(path, keys = union(bbt_detect_citations(), "the_key"))`.
- General rule: before moving content into a chunk, name what else was reading it
  as prose.

### `fs::dir_ls(glob = )` matches the FULL path, so a bare filename pattern matches nothing

- `fs::dir_ls(dir, glob = "form_*.gpkg")` returns **zero** for a directory full of
  `form_*.gpkg` files. The glob is tested against the whole path
  (`/Users/.../project/form_pscis.gpkg`), which does not start with `form_`.
- It fails **silently and in the safe-looking direction** — an empty result reads
  as "this project has none", not as "the pattern was wrong". Seen 2026-08-27 in
  rtj#221: a harvest driver found no forms in a project holding four, and a
  second glob (`"*/form_*.gpkg"`) masked it by accidentally matching.
- Use an anchored `regexp` instead, which is matched the same way but says so:
  `fs::dir_ls(dir, regexp = "/form_[^/]+\\.gpkg$", recurse = FALSE, type = "file")`.
- Set `recurse` deliberately while you are there. A recursive search of a Mergin
  project picks up `.mergin/`'s own cache copies and anything under `hold/` —
  stale duplicates that then get processed as if they were live.

### Do not build an exact-match edit from a formatted display

- Reading a file through a pretty-printer and then writing a string replacement
  against what you saw will fail whenever the formatter changed the bytes.
  `sed -n '10,20p' file | sed 's/^/  /'` adds two spaces to every line; a
  subsequent `replace(old, new)` built from that output silently matches nothing.
- The failure looks like the file changed under you, so the instinct is to re-read
  it — through the same formatter — and conclude the text is right and the tool is
  broken. Cost two failed edit rounds in rtj#221 before `repr()` on the raw lines
  showed the real indent was **two** spaces where the padded display implied four.
- Print the bytes you intend to match: `repr()` in Python, `cat -A`, or
  `writeLines()` — never a column-shifted copy.
- Same family as diagnosing PATH in the shell that actually runs: inspect the
  thing you are acting on, not a convenience rendering of it.

### `glue()` trims common leading whitespace
- `glue::glue()` strips the common indentation of its input, so a template whose
  output must preserve exact indentation (XML, YAML, Makefiles, Python) comes
  out subtly wrong — valid-looking, wrongly indented.
- For those blocks use a raw string with a `gsub()` placeholder instead of a
  glue template. Seen in rfp's QML form builder, where the photo widget's XML
  indentation has to survive verbatim.
- Related, and the opposite mistake: glue does **not** re-parse interpolated
  values, so literal `{...}` inside a *value* is safe. Don't rewrite a working
  generator to escape braces that were never a problem — probe it first.

### `f(g(x)) <- v` needs a `g<-`, not an evaluated `g(x)`

- R parses **any** call on the left of `<-` as a replacement function, all the
  way down. `xml2::xml_text(node_for(ml)) <- expr` does not evaluate
  `node_for(ml)` and assign into the result — it looks for `` `node_for<-` ``
  and errors with `could not find function "node_for<-"`.
- It reads as correct because the single-call form is idiomatic and works:
  `xml_text(node) <- v`, `names(x) <- v`, `levels(f) <- v`. Only the *nested*
  form breaks, so the habit is what leads you into it.
- Fix: assign the inner result first.
  ```r
  target <- node_for(ml)       # not xml_text(node_for(ml)) <- expr
  xml2::xml_text(target) <- expr
  ```
- The error names a function nobody wrote, which sends you looking for a missing
  import or a typo rather than at the line's shape. Caught 2026-08-27 in rfp#201
  with `xml2::xml_text(.qgs_preview_node(ml)) <- expr`.
- Applies to every replacement form — `attr<-`, `[[<-`, `dim<-`, `st_crs<-`. If
  the left side has two calls, one of them has to move to its own line.

### `on.exit()` at a script's top level never fires
- `on.exit()` registers a handler on the *current frame*. At the top level of a
  file run with `Rscript`, that frame is the global environment, which never
  exits — so the handler is registered and then simply never called.
- It looks correct, and it is correct inside a function. The failure is silent
  and, when the thing being cleaned up lives outside the repo, invisible to
  `git status`: rfp accumulated six staging directories in `$HOME` before anyone
  noticed, from two different scripts that both looked right.
- Use `withr::defer(cleanup, envir = globalenv())`, which registers a finalizer
  that runs at session end. It prints `Ran 1/1 deferred expressions` — that line
  in script output is the confirmation it worked, not noise.
- Probe rather than assume when checking this: a cleanup target inside
  `tempdir()` is removed by R's own session cleanup regardless, so testing there
  reports success for both the working and broken versions.

### A `data-raw/` script must load the source tree, not the installed package
- `requireNamespace("pkg")` succeeds whenever **any** version is installed, so a
  guard shaped like `if (!requireNamespace("pkg")) pkgload::load_all()` silently
  runs against the installed one. A generation script operates on the source
  tree by definition; reading a different copy of the package to do it is the
  bug.
- The gap is routinely enormous and nobody notices, because nothing errors.
  Measured in rfp: the installed package was **sixteen releases behind** the
  working branch, with a lookup table missing a whole row and an internal
  constant missing three entries.
- It fails quietly in both directions. One script iterated the stale lookup and
  **skipped an item entirely**, reporting 11 where the source had 12. Another
  generated two committed artifacts through a stale scan; those artifacts turned
  out byte-identical when regenerated correctly, but only because the input data
  happened not to exercise the missing entries — the same accident that let the
  original bug ship.
- Fix: `pkgload::load_all(quiet = TRUE)` **unconditionally**, and call functions
  unqualified. `pkg::` and `pkg:::` in a `data-raw/` script reach the installed
  namespace and defeat the point.
- Check for it by asserting a count the script should cover:
  `nrow(registry)` against items processed. A silent skip is invisible otherwise.

### `lintr` also resolves against the installed package, not the source tree
- The same installed-vs-source trap as the `data-raw` case above, in a tool
  where it reads as a code defect rather than a stale dependency.
  `object_usage_linter` resolves a package-level object through the installed
  namespace, so **every internal constant added on the current branch** is
  reported as `no visible binding for global variable`.
- It is convincing because the surrounding constants resolve fine — they are in
  the installed copy. Confirm before "fixing" anything:
  ```r
  exists(".my_new_constant", asNamespace("pkg"))   # FALSE  -> lint artifact
  exists(".an_old_constant", asNamespace("pkg"))   # TRUE
  ```
  If the new one is absent from the installed namespace and the old one is
  present, the warning clears on reinstall and there is nothing to change.
- Corollary for reading a lint report at all: **compare against the baseline
  before treating a count as signal.** Lint the file as it stands at `HEAD`
  (`git show HEAD:R/f.R > /tmp/f.R`) and diff the counts by linter. A file that
  already carried 26 lints in the repo's prevailing style is not a file your
  change made worse.
- And check whether the repo has a `.lintr` at all. Without one, `lint_package()`
  runs the strict defaults, which disagree with tidyverse continuation-indent
  style on essentially every wrapped call — hundreds of hits that are house
  style, not defects.

### Regenerated binaries churn git even when nothing changed
- Formats that embed a creation timestamp or other run-varying metadata produce
  a different file on every rebuild. An unconditional write then puts a binary
  diff in every commit, and a real change becomes invisible among the noise.
- GeoPackage is the live case: `gpkg_contents.last_change` made a ~100 KB file
  churn on each rebuild of an unchanged form.
- **Write to a temp file, compare the things that actually matter, replace only
  on a real difference.** Choose the comparison deliberately — for a GPKG that
  is `PRAGMA table_info` **plus** geometry type **plus** CRS, because CRS lives
  outside the column list and comparing columns alone silently keeps a stale
  projection. Then a file appearing in the diff means something genuinely changed.
- Text artifacts that are byte-stable can just be rewritten every time; the
  guard is only worth it where the format is not.

### A drift guard must cover every input it claims to
- Guards that assert "nothing has been added without a decision" are only worth
  their maintenance if they walk **all** the inputs. One that checks a subset
  gives the same green signal while the uncovered part drifts freely.
- Enumerate the source of truth programmatically rather than listing what you
  remember: walk the registry / schema / directory, diff it against the declared
  set, and fail on anything in neither "handled" nor "deliberately ignored".
- Require a **reason** on every ignored entry. An ignored item without one is a
  backlog note pretending to be a decision, and it gets re-litigated at every
  review.
- Then prove the alarm can fire: feed it a deliberately undeclared input and
  assert it is reported. A guard nobody has seen fail is decoration.
- **Pooling the inputs loses the resolution the guard exists to have.** Walking
  all the sources and then comparing against their **union** is a different
  check from comparing against each — and it passes for exactly the drift that
  matters, an item present in one source and absent from another. The guard
  looks thorough, reads as per-source, and is not.
- The tell is a lookup whose key omits the source: `x %in% all$path` rather than
  `x %in% all$path[all$source == s]`. Ask what the guard would report if one
  source lost an entry the others kept; if the answer is "nothing", it is
  pooled.
- Caught 2026-08-28 in gq#66, inside the fix for that very issue. gq declared a
  layer group that exists in one of two shipped QGIS templates and not the
  other; the registry has no `template` column, so declaring it declared it for
  both. The new drift guard compared paths against the union of both templates
  and reported clean. A reviewer found it, not the guard — which is the point:
  a pooled guard cannot catch its own author.

### A guard that compares against a vendored copy cannot see the copy go stale

A drift guard needs something to compare against. When the real source is
unavailable in CI — a private repo, a licensed dataset, a machine that is not the
build machine — the usual fix is to vendor a witness and compare against that.
It works, and it introduces a failure the guard is structurally blind to: **the
witness itself going stale.**

The guard then reports green for exactly the drift it exists to catch, because
both sides of its comparison are frozen together. Nothing is broken, nothing is
mis-scoped, and no assertion is wrong — the reference is simply a photograph of
the thing being checked.

**The tell is a guard whose comparison never reads the upstream at all.** Ask
what would have to change for it to go red, and if every answer is "someone
re-runs the vendoring script", the guard is measuring the vendoring, not the
drift.

Measured 2026-08-30 in gq. Three artifacts are vendored from a private QGIS
template repo, and **two of the three had silently drifted**:

| artifact | state | how it surfaced |
|---|---|---|
| `themes.csv` | stale for a release | a *different* repo's cross-check, which skips in CI |
| `template_groups.csv` | stale, still | re-running the extractor by hand during issue triage |
| `form_types.csv` | current | the same hand check, which is the only reason this is known |

The second is the instructive one. An issue had been filed saying the suite was
red and the exemptions were stale; the suite was **green**, because the exemption
test compares against the vendored `template_groups.csv` rather than the
templates. The witness had frozen before the upstream change landed, so the guard
could not fire, and the issue's own premise had gone stale in the same motion.

Two things that work, and they are not alternatives:

- **A currency check gated on the source being present** — extract live, compare
  to the committed copy, `skip()` when the source is unavailable. It runs on a
  developer machine and skips in CI, which is worth saying out loud in the test,
  because a skip is not a pass.
- **A date or upstream version stamped beside the witness**, so "when was this
  last true?" is answerable without the source. A guard that cannot run in CI at
  least stops claiming currency it has not checked.

Generalises to any pinned reference: a checked-in golden file, a vendored schema,
a recorded API response, a lockfile treated as documentation. If the copy is the
only thing the test reads, the test is pinned to the copy, not to the world.

### A guard's scope is usually a coincidence, and it will not announce itself

Sibling of the pooled-guard rule above, and the harder one to see. There the
guard compares against the wrong *aggregate*; here it compares against the right
thing over the wrong *set* — a literal list that happens to match the data today.
It reads as a deliberate enumeration because that is exactly what it looks like.

```r
opaque <- c("esri_world_topo")          # the only one themes.csv names today
expect_false(any(df$visible[df$layer_key %in% opaque]))
```

Nothing is wrong with that assertion. The defect is that `opaque` is pinned to
nothing, so the guard silently covers whatever the data currently happens to
contain, and grows blind the moment it grows.

**The tell is a literal set used as a filter.** For every hardcoded list, ask
where the set is *defined* and whether anything fails when the two diverge. If
the answer is "it matches at the moment", the guard's coverage is a coincidence
with an expiry date you do not control.

**Pin the scope against its source of truth**, and keep the list literal where
the membership is a *judgement* — "is this basemap opaque" is not derivable from
a query, and deriving it makes the guard agree with itself by construction:

```r
expect_setequal(c(opaque, overlay), union(g$layer_key[g$source_type == "wms"],
                                          rasters))   # declare-or-fail
```

**Expect it to recur one axis over rather than one level up.** This is what makes
it expensive: each fix is correct and the class reappears somewhere adjacent.
Measured 2026-08-30 in gq#77 — four review rounds, **five** instances, all in one
test file:

| # | scope held by | found by |
|---|---|---|
| 1 | two hardcoded template names vs a set derived from all templates | review |
| 2 | one basemap key vs the four the group actually holds | review |
| 3 | the key list vs `groups.csv`, where the set is defined | review |
| 4 | one group's wms layers vs *every* group's — and the uncovered group draws **above** it | review |
| 5 | the wms axis vs rasters, an axis with exactly one member and no margin | measuring a reviewer's claim that the residual was "definitional" |

Two of those would have shipped an opaque satellite raster over every field map
with a green suite. Three separate "this is now terminal" claims were wrong.

**Terminate it by enumeration, not by assertion.** The recursion stops when you
can name the complete candidate set and show there is no level above its source —
in that case, that `groups.csv` is hand-maintained and no generator writes it. A
residual you can state precisely ("a layer that is neither a wms nor a raster")
is definitional; one you can only call unlikely is instance six.

### Tests that silently do not run

`expect_snapshot()` **skips on CRAN**, and `testthat` treats a non-interactive run
as CRAN by default. A regression net written with it passes locally, reports
`SKIP` in CI, and is silently absent in exactly the run that matters. The failure
is invisible: the suite is green either way.

Seen 2026-08-28 in link#227 — a golden test pinning the output of the most
delicate SQL in the package, written to make a refactor provably
behaviour-preserving, was skipped the moment it ran non-interactively.

Use explicit assertions for anything that is a **regression net**:

```r
# Skips on CRAN — fine for reviewing human-readable output, useless as a guard
expect_snapshot(list(n = nrow(got), ids = sort(got$id)))

# Runs everywhere
expect_identical(nrow(got), 8L)
expect_identical(anyDuplicated(got$id), 0L)
```

If the pinned values come from live data that may legitimately move, say so in a
comment and re-pin deliberately — do not loosen the assertion to make it stop
failing, which converts the guard back into decoration.

Same class, different mechanism: `skip_if_no_db()` and friends are correct for
tests that genuinely need a database, but a suite where the only coverage of a
behaviour sits behind a skip has no coverage of it in CI. When a check matters,
give it a mock-based twin that always runs.

### pak Behavior
- pak stops on first unresolvable package — all subsequent packages are skipped
- Removed CRAN packages (like `leaflet.extras`) must move to GitHub source
- PPPM binaries may lag a few hours behind new CRAN releases

### Reproducibility
- Branch pins (`pkg@branch`) are not reproducible — document why used
- Pinned download URLs (RStudio .deb) go stale — document where to update

### `R CMD build` ships every top-level directory not in `.Rbuildignore`
- Internal coordination directories — `comms/`, `research/`, `planning/`, `dev/` — land in the tarball and therefore in the library of anyone installing from GitHub. `R CMD check` only flags this as a NOTE ("Non-standard files/directories found at top level"), which is easy to scroll past among the notes you have decided to live with.
- `.gitignore` does **not** cover this. A locally-gitignored file (e.g. `.aider.chat.history.md`) is still picked up by `R CMD build`.
- The gap appears over time rather than at scaffold: found 2026-07-31 in rfp, where `planning`, `.claude`, `CLAUDE.md` and `dev` were all excluded but `comms` and `research` — added later — were not. 10 files of cross-repo coordination notes were shipping.
- This matters most for the three-layer repo split (see `newgraph.md`): `comms/` is internal-by-definition, so a public-flipped package that ships it leaks exactly what the flip was meant to purge.
- Audit every R repo at once:
  ```bash
  for d in ~/Projects/repo/*/; do
    [ -f "$d/DESCRIPTION" ] || continue
    for sub in comms research planning dev; do
      if [ -d "$d/$sub" ] && ! grep -qE "^\^${sub}\\\$" "$d/.Rbuildignore" 2>/dev/null; then
        echo "$(basename "$d") ships $sub/"
      fi
    done
  done
  ```
  Run 2026-07-31: 20 hits across 16 repos. `comms/` in `link`, `fish_passage_template_reporting`, `neexdzii_kwa_benthic_2025`; `research/` in `link`; the rest `planning/` or `dev/`.
- Verify a fix against the tarball, not the config — the `.Rbuildignore` regex is easy to get subtly wrong:
  ```bash
  R CMD build . >/dev/null && tar tzf pkg_*.tar.gz | grep -c '^pkg/comms/'   # expect 0
  ```

### `R CMD build` ships the `.git` FILE when you build from a worktree

The rule above covers directories someone added. This is the one nobody added:
in a checkout made by `git worktree add`, `.git` is a **file** holding
`gitdir: /absolute/path/to/the/developer/machine`, and it ships.

R excludes version-control entries with an `isdir`-gated rule:

```r
isdir   <- dir.exists(allfiles)                                  # .build_packages
exclude <- exclude | (isdir & (bases %in% c("check", "chm", .vc_dir_names)))
```

A worktree's `.git` is not a directory, so the gate is false and nothing else
matches it. `.gitignore`, `.gitattributes` and `.gitmodules` are safe — they sit
in `.hidden_file_exclusions`, which is **not** `isdir`-gated. `.git` is the only
version-control name with a legitimate file form and no ungated rule, so it is
the whole exposure. Fix is one anchored line, which touches neither `.github` nor
`.gitignore`:

```
^\.git$
```

**This reaches every repo here, because `code-check.md` prescribes
worktree-per-session.** Measured 2026-08-31 in gq#76: `gq/.git` present in the
tarball, absent after the line. Sweep the R repos — any package built from a
worktree has been shipping a developer path.

Two things generalise past R:

- **Ask which *layout* a guard runs in, not only what it asserts.** The guard
  that would have caught this tested `dir.exists(".git")` — false in a worktree —
  so in the checkout layout these conventions prescribe, it silently skipped.
  Fixing the skip made it run there for the first time and it failed immediately
  on something real. A guard that cannot run is not a weaker guard, it is an
  absent one. Same family as the escape-hatch rule below, one level out: there
  the lookup is wrong, here the whole test never executes.
- **A fix that is invisible in the layout CI runs needs pinning.** Removing
  `^\.git$` changes nothing in a `.git`-*directory* checkout — which is what
  `actions/checkout` produces — because R excludes it anyway there. So the line
  protecting the tarball was itself unguarded. Assert the property directly
  (`expect_true(rbuildignore_excluded(".git", patterns))`), since it is a fact
  about the pattern file rather than about this checkout.

### `.Rbuildignore` has no comment syntax — every line is a live regex

`tools:::inRbuildignore` loops over every non-empty line and ORs `grepl()` of it
against the file list. It strips nothing and skips nothing, so a `# explanatory
note` is a pattern. One containing `.*` or a leading `^` silently drops files
from the tarball, and nothing reports it.

Caught 2026-08-31 in gq#76, in prose added to that file the same day. Measured
benign there (all five lines compiled, none matched any of 226 shipped paths) and
removed regardless. Keep the rationale in the guard or the commit message.

Generalises to any line-oriented config whose reader does not implement comments
— check before assuming `#` is inert, because the failure is silent and the file
*looks* documented.

### A premise check satisfied by the happy path's own structure is decoration

A guard that samples something — a path sweep, a file list, a query result —
wants a premise asserting it actually looked. The obvious premise is usually
satisfied by structure the sample carries either way, so it passes for the broken
case and the correct one alike.

Measured 2026-08-31 in gq#76. A sweep was fixed to include directories, and the
premise added beside it was:

```r
expect_true(any(dir.exists(file.path(root, paths))))   # cannot fail
```

`paths` always contains the top-level shipped entries, six of which are
directories, so `any(dir.exists(...))` is TRUE whether or not the sweep recursed
into nested ones. It could not detect the regression it was added for. The
premise has to name the property the fix supplies:

```r
nested <- paths[grepl("/", paths, fixed = TRUE) & dir.exists(file.path(root, paths))]
expect_gt(length(nested), 0)                            # 0 before, 13 after
```

**Test the premise the same way as the assertion: restore the defect and watch
the premise fail.** A count threshold is the usual offender — 206 clears
`> 100` as comfortably as 218 does, so it discriminates nothing.

### Base name shadowing in formal args
- Avoid `names`, `length`, `data`, `c`, `t`, `T`, `F`, etc. as formal argument names. R's function-lookup fallback often rescues `names(x)` calls inside a function whose arg is also called `names` — but it's a confusing read, breaks under refactors, and generates a real "could not find function" error when the lookup heuristic misses (e.g. inside lapply/vapply/match.fun chains). Prefer descriptive alternatives: `label_names`, `n`, `df`, etc.
- Caught in mc#33 round 1 — `mc_label_ensure(names)` worked by luck when calling `names(existing)` to read a named-vector's names; renamed to `label_names` for safety.

### Cross-function consistency for label/string normalization
- When two functions in the same package both decide whether a string is a "system value" (or any normalized form), they MUST use the same comparison. Mismatches are silent bugs that surface only on edge cases.
- mc#33 example: `mc_label_ensure` used `toupper(nm) %in% sys` (case-insensitive system-label skip), but `resolve_label_names` used `nm %in% sys` (case-sensitive). Result: `add = "inbox"` with `create_missing = TRUE` was silently broken — ensure skipped creation, resolve couldn't match. Fix: both use `toupper(nm) %in% sys` and the resolver normalizes its return to the canonical case.
- Generalized check: when reviewing a diff that adds normalization (case, whitespace, prefix-trim) on one side of an interaction, grep for the other side and align them.

### Cache keys must cover every output-affecting input
- A file cache keyed by fewer inputs than the write depends on returns silently wrong data — the worst failure class: no error, plausible-looking output. Enumerate every parameter that changes the written artifact and put each in the key (or its hash). The safe failure direction is over-keying (spurious refetch), never under-keying.
- drift#25 example: `dft_stac_fetch()` cached STAC rasters as `<source>/<year>.nc` — no AOI in the key. A second watershed silently received the first watershed's raster masked to its own extent (~3% overlap looked plausible enough to almost ship). Fix: filename gains a hash over AOI geometry + `res`/`crs`/`dt`/`aggregation`/`resampling`/`stac_url`/`collection`/`asset`.
- Hash *resolved* values, not raw args: defaults filled from config (`%||%`) must resolve before hashing, or `f(x)` and `f(x, url = <same-as-default>)` key differently for identical output.
- R hashing gotchas (`rlang::hash()` serializes, so type and attributes matter):
  - sf geometry: hash WKB (`sf::st_as_binary(sf::st_geometry(x), endian = "little")`), not the sfc object — sfc carries a PROJ-generated CRS WKT that drifts across PROJ versions (spurious cache misses), and hashing a whole sf data.frame leaks attribute columns into the key. Pass the CRS string as a separate key member.
  - Coerce numeric types: `10L` and `10` hash differently — `as.numeric()` before hashing.
- Check the cache's `force`/refresh escape hatch actually overwrites: drift#25's `force = TRUE` errored on the existing file ("File already exists"), broken exactly when needed. Prefer the writer's explicit `overwrite = TRUE` arg over a bare `unlink()` — unlink fails silently on Windows under an open file handle.

### terra: operator dispatch and edge cases in package code
- **SpatRaster `%in%` is not dispatched when terra is *imported* (only when *attached*).** Inside a package (terra in `Imports`, used via `::`), `some_raster %in% vec` falls through to base `match()` and errors with `'match' requires vector arguments`. A `library(terra)` smoke test passes (attaching installs the S4 method), so the bug hides until package context. Use `terra::subst(x, from, to, others = ...)` or `terra::classify()` for code-set membership/masking instead of the `%in%` operator. Same trap for any operator terra defines via S4 that base also defines as an ordinary function. (drift#34)
- **`terra::freq()` errors on an all-NA raster** (`replacement has length zero`) rather than returning a 0-row table. Any path that can yield an all-NA layer (an impossible filter, everything masked out) must guard: `f <- tryCatch(terra::freq(r), error = function(e) NULL)`, then treat `NULL`/0 rows as "no values". Don't assume the empty case gives `nrow(freq(r)) == 0`. (drift#34)
- **`terra::minmax()` reports *cached* statistics, not computed ones.** It defaults to `compute = FALSE` and returns `Inf`/`-Inf` for any raster whose min/max have never been calculated — which is every file-backed raster until something touches it. A guard written on top of it therefore fires on real data:
  ```r
  r <- terra::rast("a_richly_varied_image.png")
  terra::hasMinMax(r)              # FALSE FALSE FALSE FALSE
  terra::minmax(r)                 # min Inf ... / max -Inf ...
  terra::minmax(r, compute = TRUE) # min 0 0 0 0 / max 11 18 18 255
  ```
- The trap is that it *appears* to work, because plenty of upstream operations compute min/max as a side effect — `terra::crop()` does, so anything arriving via `maptiles::get_tiles(crop = TRUE)` has them. Correct by accident, through an internal that is not a contract. Pass `compute = TRUE`, and test the guard against a **file-backed** fixture: one built by `rast(vals = ...)` is in memory, has statistics cached, and cannot reach this. (gq#57, 2026-08 — a flat-tile detector called every file-backed raster flat, and the whole fixture set shared the one property that hid it.)

### terra: `extract()` returns no row for ground beyond the raster, and counts cells by centre

- Two traps in one call, and both make a partial result look complete.
- **Ground past the raster's *extent* yields no row at all**, not an `NA` row. So measuring
  coverage as the non-`NA` share of what came back reports a footprint hanging half off the
  data as fully covered. A raster cropped to an AOI is exactly this shape — no `NA`
  interior, it simply stops — which is how most people obtain one, so this is the common
  case rather than the exotic one. Measured in fly#9: every frame reported coverage `1`
  while the sampled elevation was wrong by 83 m.
- **`extract()` takes a cell when its *centre* falls inside the polygon.** So a denominator
  computed from the polygon's *area* in cell units is a different measurement from the
  numerator, low by roughly `2/k` for a polygon `k` cells across. On a raster with no
  missing data at all and room to spare, that reported 91% coverage at 900 m cells.
  Count the denominator the same way — cells on a grid aligned to the raster's own via
  `terra::align()` — or use `exact = TRUE` and accept it being ~23x slower.
- Do the alignment **per feature**, not once over their union: the union's bounding box
  spans the whole set, so one outlying feature sizes the grid to the *gap*. Two points
  700 km apart went to 243 million cells against 16 thousand counted separately.
  `terra::extend()` has the same failure — it sizes to the union of raster and features.
- Fine test rasters hide all of this. A 30 m grid makes the `2/k` error invisible, and a
  fixture whose CRS matches the data leaves every reprojection branch unexecuted. Test at
  two resolutions, with anisotropic cells, and in a geographic CRS.

### A `...` constructor may discard trailing arguments based on the class of the first one

- A constructor that takes `...` is free to branch on **what its first argument
  is** and build the result from that alone. Everything you passed after it is
  then dropped — silently, with no warning and no error, because from the
  constructor's point of view nothing went wrong.
- The live case is `sf::st_sf()`, whose attribute frame is chosen by a chain
  ending:
  ```r
  df = if (inherits(x, c("tbl_df", "tbl"))) x
       else if (length(x) == 1) data.frame(row.names = row.names)
       else if (!sfc_last && inherits(x, "data.frame")) x
       else if (sfc_last  && inherits(x, "data.frame")) x[-all_sfc_columns]
       else if (inherits(x[[1]], c("tbl_df", "tbl"))) x[[1]]     # <-- keeps ONLY arg 1
       else cbind(data.frame(row.names = row.names), as.data.frame(x[-all_sfc_columns], ...))
  ```
  So `st_sf(df, a = , b = , geometry = )` keeps `a` and `b`, and
  `st_sf(tbl, a = , b = , geometry = )` throws them away. **Same call, same
  data, different class — different columns out.**
- **The failure is invisible for as long as your fixtures share one class.** In
  fly#35 four columns recording how each airphoto footprint had been sized never
  reached a single caller of the package's own documented data source, because
  `bcdata::collect()` returns a tibble and every fixture in the package read back
  as plain `sf, data.frame`. Two releases shipped that way with a green suite:
  geometry and every downstream number stayed correct, and only the audit trail
  went missing, so nothing errored and nothing looked wrong.
- **Fix: build the frame first, then hand the constructor one argument.** The
  columns are then inside the argument the branch keeps, whichever branch it is,
  and the caller's class is untouched:
  ```r
  attrs <- sf::st_drop_geometry(x)
  attrs$a <- a
  attrs$b <- b
  result <- sf::st_sf(attrs, geometry = g)      # not st_sf(x, a =, b =, geometry =)
  ```
  Coercing instead — `st_sf(as.data.frame(st_drop_geometry(x)), a =, ...)` — also
  restores the columns, but downgrades a tibble caller's class as a side effect.
  Prefer the version that changes one thing.
- **Test by sweeping the class axis, not by adding cases along it.** Assert
  identical names *and values* across plain / tibble / grouped / vendor-classed
  shapes of the same data. Read the tibble honestly (`st_read(as_tibble = TRUE)`)
  rather than overwriting `class()`, and assert that premise inline so a future
  upstream change fails by naming the real cause.
- **Do not over-state what survives.** `sf::st_transform()` moves `sf` to the
  front of the class vector, so `bcdc_sf, sf, ...` returns `sf, bcdc_sf, ...`.
  The class *set* is carried; the order is not. An
  `expect_identical(class(out), class(in))` written from three shapes that all
  lead with `sf` passes, and then fails on the one real caller you wrote it for.
- Swept 2026-08-29 across all 61 repos in `~/Projects/repo` — 1500 `.R` files and
  389 purled `.Rmd` chunks, parsed with R rather than grepped, looking for
  `st_sf()` with a non-literal first positional argument plus trailing column
  arguments. **`fly` was the only instance.** A regex misses this: the original
  defect was a multi-line call. Validate any such scanner against both known
  answers before believing a clean result — the pre-fix file must be flagged and
  the fixed one must not, or "no hits" is indistinguishable from a broken scan.
- Generalizes past `sf`. Ask it of anything taking `...`: *does this constructor
  decide what to keep by looking at the first argument?* Same shape in any
  language where a variadic builder dispatches on an argument's type.

### terra: `mask()` is `touches = TRUE`, so two "clip to the polygon" routines disagree by a cell ring

Swapping one polygon clip for another looks like a refactor and is a **methodology
change**. `terra::mask()` defaults to `touches = TRUE` — every cell the polygon
touches is kept — while most other clips rasterize at **cell centre**:
`terra::rasterize()` without `touches`, `gdalcubes::filter_geom()`, and
`gdal_rasterize` without `-at`. Nothing errors, nothing warns, and the values
agree exactly where both have data. Only the *footprint* moves.

```r
mask(r, v)                  # 150 cells   <- the default
mask(r, v, touches = FALSE) # 122 cells
# true polygon area: 123.4 cells
```

The magnitude is a perimeter-to-area ratio, so it is worst exactly where these
clips get used — thin corridors, floodplains, riparian buffers. Measured
2026-09-01 in drift#47 on a 3.3 km reach: **−15.5%** of the analysed footprint
(49,244 → 41,608 cells) from a change whose entire stated purpose was to remove a
redundant step. Against a parity tolerance of ±1 ha on 943 ha, that is 30–150×.

- **Do not describe a clip without naming its rule.** drift's roxygen said "cells
  whose centre falls outside become `NA`" for a `terra::mask()` call, and was
  wrong for two releases. Anyone reasoning about boundary hectares from that doc
  was off by a ring.
- **An axis-aligned fixture cannot catch this.** A rectangle on a cell boundary
  makes both rules agree, so the test passes for nothing. Use a polygon with
  fractional coordinates and no edge parallel to the grid, and assert the premise
  beside the property — `expect_gt(touch, centre)` — so a future terra default
  change fails by naming the real cause.
- **To swap in a cell-centre clip without moving the footprint**, buffer the
  polygon by `>= res * sqrt(2)/2` first: if a polygon intersects a cell square,
  that cell's centre is within a half-diagonal of it, so the buffered
  cell-centre footprint is a guaranteed superset of `touches = TRUE`. Then keep
  the `mask()` to trim back, and the output is byte-identical.

Generalises past terra: whenever two libraries both offer "clip raster to
polygon", assume they disagree at the boundary until measured. Count the cells.

### terra: `sources()` on a derived raster is `""` or a random temp path, never the input

- A raster that came out of `crop()`, `project()`, `mask()`, or arithmetic is **derived**, so it
  has no source file. `terra::sources()` returns `""` when the result fits in memory — and a
  **random per-process temp path** when terra spills to disk:
  ```r
  sources(rast(file))                      #> /…/dem.tif
  sources(crop(...))                       #> ""    inMemory TRUE
  sources(project(...))                    #> ""    inMemory TRUE
  terraOptions(todisk = TRUE); sources(crop(...))
                                           #> /private/tmp/RtmpFcjh9X/spat_ad2f168560ce_44335_Sskvi….tif
  ```
- The reach for it is provenance — *"what file did this raster come from?"* — and both branches
  answer wrongly. The empty branch is survivable: it reads as absent and a fallback fires. **The
  disk branch is the dangerous one**, because a temp path is a plausible-looking string that
  differs on every run and every machine, so it silently destroys byte-stability in whatever
  record it lands in, and nothing flags a value that *looks* like a path.
- Worse, which branch you get depends on **size**: small AOIs stay in memory and large ones spill.
  So a fixture proves the empty case and production hits the poisoned one.
- If a function crops or reprojects before returning, `sources()` cannot answer this **at all** —
  do not reach for it. Record the resolver plus the raster's measurable geometry (`crs`, `res`,
  `ncell`, `ext`), or have the package expose what it resolved (`attr(out, "source") <- source`).
- Caught 2026-09-01 in floodplains#33: `flooded::fl_dem_aoi()` builds its MRDEM-30 URL inside its
  body, so `formals()` does not expose it either. `sources()` looked like the way to measure the
  output instead of restating the input — the right instinct, applied to an object that cannot
  carry the answer.

### `$` on a list partial-matches, so a longer sibling key answers for a missing one

- `x$foo` on a list returns `x$foo_bar` when `foo` is absent and `foo_bar` is the only key with
  that prefix. `[[` does not — it matches exactly. This is base R behaviour on **lists**, not a
  quirk of any package, and it fires on anything parsed from JSON or YAML.
- It fails toward a **confident wrong answer**, and the damage lands on the `is.null()` guard
  rather than on the read:
  ```r
  x <- list(link_log_note = "no log table in source schema")
  is.null(x$link_log)     # FALSE  <- the NOTE answered
  is.null(x[["link_log"]])# TRUE
  ```
  So "the row is absent, explain why" becomes "the row is present" and the code then reports every
  field of it missing — an error message pointing nowhere near the cause.
- The sibling-key shape is common precisely where it hurts: `x`/`x_note`, `id`/`ids`,
  `item_ids`/`item_ids_complete`, `path`/`pathname`, `count`/`counts`. Two of those were live in
  one 80-line file (floodplains#33, 2026-09-01), and the first cost a failure three checks away
  from its cause.
- **Rule: read parsed documents with `[[`.** Reserve `$` for objects whose key set you control and
  that have no prefix pairs — and even then it is a habit worth not having, because the key set is
  controlled until someone adds `_note`.
- Where the convention matters, pin it with a **premise assertion** so it cannot be tidied away by
  someone who does not know why:
  ```r
  expect_true(is.null(x[["link_log"]]) && !is.null(x$link_log))   # why this file uses `[[`
  ```
- `warnPartialMatchDollar = TRUE` surfaces it globally and is worth setting while debugging a
  "this field is present when it should not be" symptom. It is off by default, so nothing tells
  you otherwise.


### sf: `st_join(largest = TRUE)` ignores the join predicate
- `sf::st_join(x, y, join = predicate, largest = TRUE)` does **not** use `predicate` to decide matches — with `largest = TRUE`, sf runs `st_intersection(x, y)` and keeps the feature of greatest overlap area, so matching is *always* intersection-based regardless of what `join =` is set to. A function that exposes a configurable predicate AND a largest-overlap mode therefore silently mis-attributes when both are combined: pass `st_within` expecting containment, get anything that merely *overlaps*. Verify against sf source, not the argument list — the `join` arg is accepted and ignored, not rejected. Fix: abort when a non-default predicate is combined with the largest-overlap mode, rather than honouring one and dropping the other. (drift#42)
- Corollary: `largest = TRUE` also drops zero-area geometries from consideration — so a predicate join against **point** or **line** overlays cannot use largest mode at all (no area to compare). Point/line attribution must go through the plain (`largest = FALSE`) predicate path.

### sf: name validation must account for the geometry column
- The active geometry column is a named entry in `names(x)`, but its name is **not fixed** — `"geometry"` from `sf::st_read()` of some sources, `"geom"` from a GeoPackage/PostGIS layer, `"geometry"` or `"_ogr_geometry_"` elsewhere. Code that validates user-supplied column names with `cols %in% names(x)` will happily accept the geometry column, then break downstream (`st_join` drops `y`'s geometry, so a requested "attribute" column silently never appears; a 0-row short-circuit path may instead attach a stray empty sfc). A same-name collision check across two sf objects also misses this when the two layers name their geometry differently. Guard explicitly with `attr(x, "sf_column")` — reject it from the caller-supplied column set. (drift#42)

### sf: `st_intersection()` / `st_difference()` return a GEOMETRYCOLLECTION that QGIS will not draw
- Intersecting or differencing two polygon layers yields a `GEOMETRYCOLLECTION` wherever the inputs *also* touch along a line or at a point. The polygonal part is real and `st_area()` reports it correctly, so every numeric check passes — but QGIS renders the feature as nothing, and it reads to the user as "one row with no geometry".
- The failure is silent in exactly the wrong direction: written to a GeoPackage the layer reports its `geometry_type` as `Geometry Collection` and its area as correct. Nothing errors. It surfaces only when someone opens it.
- Whether it fires depends on the geometry, not the code, so the same call can be clean on one input and a collection on the next. Do not conclude from one working case that a path is safe.
- Fix: `sf::st_collection_extract(g, "POLYGON")` then cast to a single type before writing. Areas are unchanged — the discarded fragments have zero area.
- **Assert it on anything you hand over**, not just the layer you expect to be interesting: no `GEOMETRYCOLLECTION` in `st_geometry_type()`, and `sum(st_is_empty())` is 0, across *every* layer in the file. Caught 2026-08-31 in floodplains only because the user opened the deliverable and asked why a layer looked empty.

### A per-tenant key looks global whenever your test data has one tenant
- `code-check-infra.md` records this for database joins (link's `id_segment`, unique per watershed group, cartesian against a multi-tenant table). The same mechanism appears well outside Postgres — in vector attribute tables, exported layers, and anything numbered per group during generation — and the reason it survives review is always the same: **the data that would expose it is the data nobody tested on.**
- If N-1 of your areas have exactly one tenant, a per-tenant key is *observably* unique in all of them. Verifying uniqueness on one of those and generalising is not carelessness; it is a correct observation about an unrepresentative sample.
- Caught 2026-08-31 in floodplains: `patch_id` is numbered within each sub-basin. Every whole-watershed-group area has one sub-basin, so `patch_id` was globally unique in all five that had been run. The only subset area (13 sub-basins) had 2032 rows and 1973 distinct ids. Grouping on it alone mis-apportioned by 6%.
- **The tell is a contradictory pass.** That run reported "weights sum to 1 per patch" and "0 unbridged patches" *and* a 6% shortfall — three results that cannot all be true. A reconciliation check that disagrees with its own component checks is pointing at a key, not at arithmetic.
- Before keying on an id you did not generate, ask what it is unique *within*, and prefer the composite (`(patch_id, name_basin)`) even where the current data makes the extra column redundant.

### sf: reproject the polygon to get a lat/lon bbox, never transform the projected bbox corners
- To hand a geographic (EPSG:4326) bounding box to a bbox-filtered query (WFS/OGC features, `?bbox=`), reproject the whole AOI **geometry** then take its bbox: `sf::st_bbox(sf::st_transform(aoi, 4326))`. Do **not** compute the bbox in the projected CRS and transform its two corner points — a projected rectangle's edges bow under reprojection, so the corner-transformed box is skewed and generally too short on one axis. The pre-filter then silently under-covers the true extent: features inside the AOI but outside the shrunken box are never fetched, and a downstream clip can only *remove*, never recover them. Symptom: counts a few percent low near the north/south extremes of an area, with no error. A native-CRS bbox filter (e.g. ogr2ogr `-spat <bounds> -spat_srs EPSG:3005`) is unaffected — only the reproject-the-corners step is the bug. (rfp#12)

### A database driver's value is not a base R type — and it fails twice

A column fetched through DBI does not arrive as the base type its SQL type suggests. RPostgres
returns `text[]` as class **`pq__text`**, for which `is.list()` is **FALSE**, `length()` is **1**,
and the single element is the **raw Postgres array literal** — `"{BT,CH,CO}"`, braces and all.

That shape defeats a type-dispatching coercion twice over, and the second failure is the dangerous
one:

```r
x <- row$species                    # class pq__text
is.list(x)                          # FALSE  -> the list branch is skipped
length(x)                           # 1      -> the vector branch is skipped
                                    # falls through unchanged
jsonlite::toJSON(x)                 # Error: No method asJSON S3 class: pq__text
x[[1]]                              # "{BT,CH,CO}"  <- unwrapping is NOT enough
jsonlite::toJSON(I(as.character(x[[1]])))
                                    # ["{BT,CH,CO}"] <- valid JSON, wrong value, NO error
```

- **First it errors**, which is survivable. **Then the obvious fix stops the error and emits a
  plausible wrong value** — one brace-wrapped string where an array was meant. Nothing downstream
  can tell. The literal needs parsing, splitting on *unquoted* commas: an element containing a
  comma is double-quoted, and a naive `strsplit` corrupts it silently.
- **Subsetting drops the class.** `row$col[i]` returns a plain character; `as.list(row[1, ])`
  preserves `pq__text`. So a probe written the first way exercises a **different branch** than the
  code it is meant to be testing, and reports a pass the production path does not earn. Measure on
  the exact expression the caller uses, and assert the class as a premise.
- **No hand-built fixture contains one.** This is the fixture-cannot-reach-the-failure-mode rule
  arriving through a *type* rather than through data: a guard can be thorough, exercised against
  input built to break it, and still never construct a driver value. Build the driver shapes
  explicitly — `structure(list("{A,B}"), class = "pq__text")` needs no database.

Caught 2026-09-01 in floodplains#33: it would have aborted a pipeline step on its first real run,
after the expensive work had completed. It reached `main` because the database was wrongly believed
to be down (see `code-check-infra.md`, "The database is down is usually the probe"), so the only
code path that touches a driver value was never executed.

Generalises past Postgres arrays — `blob`, `json`/`jsonb`, `hstore`, `numeric` via `bit64`,
and every driver's own vector classes. **Whenever a DBI row crosses into a serializer, print
`class()` of each column once and write the coercion against what you see**, not against the SQL
type. And give the serializer a guard that names the offending *path*: jsonlite reports the class
with no location, which in a nested document is a scavenger hunt.

### arrow dplyr backend: no grouped slice — bridge to duckdb
- arrow's dplyr backend errors on grouped `slice_max`/`slice_min` (`arrow_not_supported("Slicing grouped data")`). The working pattern for any "latest per group" over parquet/S3: `arrow::open_dataset(...) |> dplyr::filter(...) |> arrow::to_duckdb() |> dplyr::group_by(...) |> dplyr::slice_max(...)`.
- The `to_duckdb()` bridge is also a return-type contract: helpers that return the lazy query should keep the bridge even when they no longer need it internally, or downstream callers using grouped verbs break. (water-temp-bc#17, #23)

### as.POSIXct.Date silently ignores tz=
- `as.POSIXct(x, tz = "UTC")` on a `Date` ignores `tz` and converts in the system local zone — west of UTC this shifts date boundaries by the local offset and silently drops edge data. Force UTC via `as.POSIXct(format(x), tz = "UTC")` when accepting Date inputs; widen Date upper bounds to `< next-day-midnight` so the whole calendar day is included. (water-temp-bc#17)

### as.POSIXct on character infers ONE format for the whole vector
- `as.POSIXct(x)` on a character vector picks a single format by finding the first candidate that parses **every** element — and `strptime` **ignores trailing characters**. So one coarse value silently truncates the entire column, and nothing warns:
  ```r
  as.POSIXct(c("2026-08-15 18:33:46", "2026-08-15 18:34:20", "2026-08-16"))
  #> all three at 00:00:00   <- the times are gone
  ```
  One minute-precision value does the same to its neighbours' seconds. Order-independent, and the values are not `NA` afterwards, so an `is.na()` guard on the result cannot see it.
- Same family as the `Date` case above, and worse: that one shifts by a known offset, this one destroys information.
- Fix: match each value's **shape** with an anchored regex, then parse it with the format that shape implies — per element, not per vector. Anchoring at both ends is what turns trailing junk into an error instead of a silent truncation.
- `tryCatch` around the whole call is not a fix either. `as.POSIXct.character` **throws** on an unrecognised string rather than returning `NA`, so a catch-all handler that blanks the vector then makes the "which value failed?" report name element one — usually a perfectly good timestamp. Compute the failing set per element inside the error path.
- Caught 2026-08-24 in crate#9. Three bugs in one parse (this, a dropped `+02` offset, and the misleading error), all silent, all with the suite green at 171 passing.

### An offset regex must be anchored to a time, or a date looks like a zone
- Refusing or stripping a trailing UTC offset with something like `[+-][0-9]{2}(:?[0-9]{2})?$` also matches the end of a plain ISO date: `"2026-08-15"` ends in `-15`, which reads as a −15 hour zone. Require the offset to follow `HH:MM[:SS[.fff]]`.
- The mirror mistake is requiring four offset digits. `±hh` is valid ISO 8601 and is what Postgres emits for whole-hour zones; a two-digit-offset value then falls through the guard, gets stripped as trailing junk, and the instant moves by hours with nothing reported.

### A reader that accepts a UTC offset may not be applying it

- The rule above is about parsing an offset correctly. This is the case where the
  parse never happens: the value is accepted, no error is raised, and the offset is
  **silently discarded**. GDAL does this with a GeoPackage `DATETIME` — it returns
  the wall-clock digits, which the caller then reads in the machine's zone.
- So the same file yields a different instant on every machine. Measured 2026-09-01
  on `trap`, writing one value and reading it back under three zones:

  ```
  stored                      TZ=America/Vancouver   TZ=UTC       TZ=Asia/Tokyo
  2026-07-21T14:04:28Z        14:04:28Z              14:04:28Z    14:04:28Z
  2026-07-21T14:04:28-07      21:04:28Z              14:04:28Z    05:04:28Z
  2026-07-21T14:04:28+05:30   21:04:28Z              14:04:28Z    05:04:28Z
  ```

  **The tell is that the two offsets give identical answers.** Only the `Z` row is a
  fact about the file; the other two are facts about the reader.
- **The test that let it through asserted `-07` on a `-07` machine**, where a
  wholly-ignored offset and a correctly-applied one produce the same number. The
  coincidence was written into the fixture by choosing an offset equal to the local
  one, so no amount of running it locally could have found it — CI on a UTC runner
  did. Same family as "a fixture set that cannot reach the failure mode", with the
  blind spot supplied by the machine rather than by the data.
- Two things follow, and the second is the general one:
  - **Refuse what you cannot read.** Where every real value carries `Z`, accepting an
    offset buys nothing and costs a silent multi-hour error. Refusing it with its own
    message — a missing zone and an untrusted zone are different failures — is
    strictly better than honouring a parse you have not verified.
  - **Test a timezone-sensitive property in more than one zone**, and make one of them
    differ from the developer's. `withr::with_timezone()` costs nothing. The property
    worth asserting is *the instant is the same in every zone*, which a single-zone
    test structurally cannot check.
- Generalises past GDAL to anything that returns a naive local timestamp from a
  zone-bearing source: some JDBC drivers, `datetime.fromisoformat` before 3.11 on
  certain shapes, spreadsheet readers. If a library hands back a value with no zone
  attached, assume the zone was dropped rather than applied, and prove otherwise.

### `paste0()` treats a zero-length argument as `""`
- `paste0(character(0), "x")` returns `"x"` — length **one**, not zero. So a composite key built from an empty data frame yields one phantom row rather than none:
  ```r
  paste0(df$a, "\x1f", df$b)   # nrow(df) == 0  ->  "\x1f"
  ```
- Downstream that reads as a real record. Caught 2026-08-24 in trap#14: an empty annotation table produced one key, which the join then reported as "an annotation matching no session". Guard with an explicit `if (!nrow(x)) return(character(0))`.
- Same shape for any vectorised builder fed a possibly-empty frame — `sprintf()`, `file.path()`, `interaction()`.

### A zero-length value in a row-builder drops the whole record, group and all

- Third member of the zero-length family above, and the one that removes evidence
  rather than corrupting it. A tibble/data.frame constructor recycles its columns:
  give one of them a zero-length value and you get **zero rows**, not one row with
  a blank. Inside a `map_dfr()`/`bind_rows()` over groups, that group then vanishes
  from the result entirely.
  ```r
  covered_area <- as.numeric(sf::st_area(covered))   # empty geometry -> numeric(0)
  dplyr::tibble(group = grp, covered_km2 = covered_area / 1e6)   # 0 rows
  ```
- The output looks *correct*, just shorter. Nothing is wrong on the page, no NA
  appears, and the absent group reads as "not in the input" rather than "could not
  be computed" — so a reviewer comparing group counts is the only way to catch it.
- Caught 2026-08-28 in fly#30: a coverage table silently omitted a photo-year whose
  frames all had unresolvable footprints, instead of reporting that it covered
  nothing.
- Fix by folding to a scalar at the boundary — `sum()` over `st_area()` is both the
  zero-length guard (`sum(numeric(0))` is `0`) and the fix for the mirror bug, where
  a multi-feature result silently emits several rows instead of one.

### Inserting a helper between a roxygen block and its function rebinds `@export`

- roxygen2 attaches a block to **whatever object follows it**. Add a helper directly
  above the function the block documents and the docs, `@examples` and `@export` all
  bind to the helper. The real function loses its export, and roxygen writes an `.Rd`
  for an internal helper.
- `devtools::test()` will not catch it. `load_all()` exports everything regardless of
  NAMESPACE, so the suite stays green at full pass while the package's main function
  is no longer exported — it fails only for someone who installs it.
- Caught 2026-08-28 in fly#30: `export(fly_footprint)` disappeared and
  `fly_film_media.Rd` appeared; 120 tests passed throughout. The signal was in
  `devtools::document()` output, not the test run.
- Read what `document()` prints, every time. `Writing '<something unexpected>.Rd'` or
  `Deleting` on a file you did not touch is the tell. Cheap confirmation:
  ```bash
  git diff NAMESPACE            # an export you did not intend to change
  grep -c "^export(" NAMESPACE  # count should not fall
  ```
- Put internal helpers at the top of the file or in their own file. The roxygen block
  must sit immediately above the function it documents, with nothing between.

### A zero-length value in a comparison makes every branch false and silently picks the fallback

- `x == character(0)` is `logical(0)`, so `which()` gives `integer(0)` and
  `if (length(hit))` is FALSE **for every element**. A lookup written this way
  does not error and does not report "not found" — it falls through to whatever
  the else-branch does, usually *create*. The created thing then carries the
  zero-length value as its name or key, and is unnamed rather than absent.
  ```r
  hit <- which(trimws(xml2::xml_attr(groups, "name")) == trimws(group))
  if (length(hit)) return(groups[[hit[[1]]]])   # group = NULL -> never taken
  g <- xml2::xml_add_child(parent, "layer-tree-group")
  xml2::xml_set_attr(g, "name", group)          # sets nothing; attribute absent
  ```
- **The docs are what make it survive.** Because the fallback runs silently and
  produces a plausible object, whatever the roxygen *claims* `NULL` means goes
  unchallenged — and then gets copied into a CLAUDE.md and read as measured
  fact. Caught 2026-08-28 in rfp#213: two exported writers documented
  `group = NULL` as "inserts at the root" and "uses the registry's group"; both
  created an **unnamed** layer-tree group at the end of the tree instead, where
  everything in it draws under the basemaps and is invisible. One of them did it
  once per call.
- Sibling of the `paste0()` entry above: both turn "nothing" into "one thing"
  rather than into an error.
- Fix: test the argument, not the search result — `if (is.null(group)) stop(...)`
  — and make the message list what *is* available, which is also the cheapest
  way to notice the lookup never had a chance.

### open_dataset(unify_schemas = TRUE) requires aligned types
- Cross-prefix/file schema unification only merges what types allow: `timestamp[us, tz=UTC]` will not merge with naked `timestamp[us]`, `Grade: string` not with `Grade: double`. Audit the schemas of every file group BEFORE promising unified reads over a mixed archive; plan a normalization pass otherwise. (water-temp-bc#17)

### duckdb larger-than-memory dedup: shard the work — settings won't save you
- duckdb's **window operator** (QUALIFY row_number ...) does not spill enough to survive big partitions (OOM'd an 8 GB limit on a ~124M-row input). The **arg_max/struct-payload hash aggregate** cannot spill its state either (observed OOM with an empty temp dir). `preserve_insertion_order = false` and fewer threads help but do not fix it.
- **In-memory duckdb connections never offload to disk at all** — `SET temp_directory` on `dbConnect(duckdb())` is a no-op for operator spill. File-backed (`dbdir = <file>`) is required for any spilling.
- The structure that works at any scale: **hash-shard by a column inside the group key** (e.g. `hash(STATION_NUMBER) % K = k`, K = `ceiling(input_rows / shard_rows)`), one aggregation pass per shard, each writing its own ordered output file. A key never crosses shards, so dedup stays exact; memory scales 1/K. Extra passes cost scan time only — per-pass aggregate state is what OOMs, so when in doubt shard smaller. (water-temp-bc#23)
- **Local runs at the same duckdb `memory_limit`/`threads` do NOT validate a constrained runner.** 10M-row shards passed a Mac at the exact 4 GB / 2-thread settings but OOM'd the real 7 GB GHA runner (partition 46 squeaked through in 94s, 47 died 15s in) — abundant physical RAM masks how tight duckdb's accounting runs at its internal limit. Only the real runner is the real test; size shards with margin (water-temp-bc ships 6M), and treat a near-timeout/near-limit pass as a failure to fix, not a pass. (water-temp-bc#23 run 29675228557, fixed in PR #25)

### `nzchar(NA)` is TRUE — non-empty checks silently pass NA
- `nzchar(NA)` returns `TRUE`, so the natural "is this cell filled in" test — `all(nzchar(trimws(x)))` — waves through a column full of `NA`. `trimws(NA)` is `NA`, and `nzchar()` of that is `TRUE` unless you pass `keepNA = TRUE`.
- Use an explicit guard: `filled <- function(x) !is.na(x) & nzchar(trimws(x))`. Same trap in reverse for `read.csv()`, which yields `""` for an empty field but `NA` for a literal `NA` — so a file can fail one check and pass the other for the same visual blank.
- Bites hardest in validators, where the whole point is catching a half-authored row. (link#233, 2026-08: a dictionary contract test asserting every row carried a description would have passed on an entirely NA column.)

### Test fixtures must mirror production column TYPES, not just shapes
- A fixture-green suite can hide type bugs that only real data exposes: water-temp-bc#23's fixtures had `Grade` as string when production has double, so a `coalesce(Grade, '')` sentinel inside the dedup ordering passed all 27 tests and broke on first contact with real data.
- When writing fixtures for a pipeline over an existing dataset, print the real schema (`arrow::open_dataset(...)$schema`) and copy the types verbatim. Any type-sensitive expression (coalesce sentinels, casts, comparisons) is only tested if the fixture types match.

### CSV whitespace: `trim_ws` and `strip.white` do not do what the name suggests

- `readr::read_csv()` defaults to **`trim_ws = TRUE`** and silently strips leading
  and trailing whitespace. Where whitespace is *meaningful* — a QGIS layer name
  deliberately prefixed with a space so it sorts first — a trimmed value binds to
  nothing, with no error. Use base `utils::read.csv()`, or pass
  `trim_ws = FALSE`.
- `read.csv(strip.white = TRUE)` applies **only to unquoted fields**, and
  `write.csv()` quotes every character column. So a round-trip guard that
  compares `read.csv()` against `read.csv(strip.white = TRUE)` is *structurally
  incapable of failing* — both readers return the same thing, and the check
  passes for nothing.
- The second point is the trap: the guard looks right, runs green, and proves
  nothing. Probing for the real failure mode is what surfaces the `readr` one.
  Caught 2026-08 in rfp#174, where five leading-space layer names were at stake.

### `R CMD check` rejects a filename containing a space

- "checking for portable file names" fails on any file in the built package
  whose name has a space. It is an ERROR, not a NOTE, so CI goes red.
- Bites when shipped files are named after human-readable strings — layer names,
  form labels, report titles. 40 of 50 in one case, one of which *began* with a
  space.
- Fix: derive a slug for the filename and keep the real name in an index CSV
  beside it. Resolve through the index, never by reconstructing a path from the
  display string.

### Do not edit files a long test run is reading

- `devtools::test()` (and most runners) load each test file **when they reach
  it**, not at launch. A 30-minute run therefore reads whatever is on disk at
  that moment, so edits made while it runs are half-applied and the result
  describes a tree that never existed.
- The tell is a **changing pass count** across runs of "the same" tree —
  3490, then 3496, then 3500. A moving denominator means the input was moving.
- Cost 2026-08 in rfp#178: two full Docker suites (~1 hour) both reported
  `FAIL 1`, and the failure was a test written *during* the run, executing
  against source from *before* the fix that made it pass. It was nearly reported
  as a regression.
- **Commit before a long run.** While it runs, do work that touches nothing it
  reads — issue bodies, PR text, planning. And when a long run fails, get the
  `file:line` before forming any theory: a mid-flight edit and a real regression
  look identical in a summary line.

## General

### Two agent sessions must not share one git working tree — give each a worktree

- A git working tree has exactly **one** checked-out branch. When two concurrent Claude sessions operate in the same directory, either can `git checkout` out from under the other **mid-edit**. The victim's uncommitted work stays on disk but is now sitting on the *other* session's branch — so a later `git add`/`commit` silently lands it on the wrong branch, and a `--delete-branch` merge can strand it entirely.
- Symptoms: an `Edit` fails with "File does not exist" for a file you just wrote (their branch doesn't have it); `git branch --show-current` returns a branch you never created; your new files show as untracked on someone else's feature branch; `planning/active/` suddenly empty.
- Caught three times in one session (2026-07, floodplains): twice mid-implementation, and once while running a `--public-clean` scrub — the scrub committed to a parallel session's feature branch instead of `main`, which would have flipped the repo public with an **un-scrubbed `main`**. That third one is the dangerous class: the safety work (`.claude/visibility`, stripped internal conventions) sat on a branch nobody was about to merge.
- **Prevention:** one worktree per session — `git worktree add ../<repo>-<task> -b <branch>`. Each session gets its own directory and its own checked-out branch; no contention.
  - **`git worktree add <path> <branch>` fails when that branch is already
    checked out**, and the primary clone almost always has the default branch
    checked out. So the obvious isolating command — `git worktree add $SP/x main`
    — aborts precisely when you reach for it. Chained as
    `git worktree add … ; cd "$SP/x" && …`, the failure falls through: `cd` errors,
    the shell stays in the caller's cwd, and every later command runs **in the
    shared checkout** — the contention the worktree existed to prevent. Use
    `-b <new-branch>` (or `--detach`) so the worktree never asks for a branch
    someone holds, and chain with `&&` so an abort cannot fall through.
    Seen 2026-08-28 appending the rule directly above this one.
- **Detection (cheap; do it before any commit, merge, or visibility flip):** assert the branch is what you think it is, not just that the tree is clean.
  ```bash
  [ "$(git branch --show-current)" = "$EXPECTED_BRANCH" ] || { echo "WRONG BRANCH"; exit 1; }
  ```
- **Recovery:** back up the touched files first (`cp` to a scratch dir, `git diff > x.diff`), confirm the other branch's changes don't overlap yours (`git diff --name-only main..their-branch`), then `git checkout <your-branch>` — uncommitted changes carry across cleanly when there is no overlap. Commit **and push** immediately; an unpushed branch is what gets stranded. If you already committed onto their branch, restore their pointer with `git branch -f <their-branch> <their-last-sha>` (your commit stays reachable via reflog).
- **Recovery when their branch is already pushed, with an open PR:** do **not** rewrite it — `git branch -f` plus a force-push into a PR another session is working in trades your problem for theirs. Cherry-pick forward instead, through a throwaway worktree so their checkout is never disturbed:
  ```bash
  git worktree add -q /tmp/repo-main main
  git -C /tmp/repo-main cherry-pick <your-sha>
  git -C /tmp/repo-main push origin main
  git worktree remove /tmp/repo-main
  ```
  Their PR now carries a commit whose content is already on main. That is harmless — git sees identical changes on both sides and merges cleanly — and verifiable before you rely on it: `git diff origin/main -- <the-file>` on their branch should be empty. The cost is one duplicated commit message in the log, which is cheaper than a contested force-push.
- **The moment to use a worktree is when you are about to touch a second repo**, not after something goes wrong. Observed 2026-08-26 in gq#57: a fix in the primary repo needed a matching change in `soul`, and `soul`'s shared checkout had meanwhile been switched to a parallel session's feature branch. The commit landed in their open PR silently — `git push` reported success, because it was a perfectly valid push to a branch nobody had said was wrong.
- **The mirror case is worse, because the success message means the opposite of what it looks like.** `git push -u origin main` pushes the *local ref named `main`* — not `HEAD`. If a parallel session moved the checkout onto their branch, your commit is on **their** branch, local `main` has not moved, and the push prints **`Everything up-to-date`**. That is indistinguishable from "already pushed", so the natural reading is that the work is safely on origin when nothing was sent at all. Observed 2026-08-31 in rtj: a memory-audit commit reported a clean push and was not on `origin/main`.
  - **Verify the artifact, not the push output.** `git cat-file -e origin/main:<a file you wrote>` answers the question the exit code does not. A push that says "up-to-date" when you have just committed is a contradiction worth one command.
  - Prefer `git push origin HEAD` when you mean "publish what I am on", and read `git status -sb` for the branch name **before** committing, not after the push looks odd.

### Adopting Existing Config

When importing config from one location into a canonical one (legacy `~/.bash_profile` → dotfiles repo, old script's env → repo, another project's `settings.json` → soul):

- **Verify every referenced path/binary exists.** Dead PATH exports, missing interpreters, stale env vars should be cut, not codified.
  Shell paths: `for p in $(echo "$PATH" | tr ':' ' '); do [ -d "$p" ] || echo "DEAD: $p"; done`
- **Ask before dropping a reference** — it may be something the user forgot to reinstall on this machine, not something to delete.
- **Curated subset, not verbatim copy.** The diff should reflect what you verified, not the whole source.

### Test the cold/create path of idempotent code, not just the warm no-op
- Idempotent provisioning code (a resolver-file writer, a config installer, a "create unless present" block) has two paths: the **cold** path that actually creates/writes, and the **warm** path that detects "already present" and skips. They exercise almost-disjoint code.
- Testing only on a host where the artifact already exists hits **only the warm no-op** — which cannot catch any cold-path bug: missing-directory, a derivation that returns empty, a pipefail abort before the write, wrong permissions, a flush that never runs. The warm path's job is literally to do nothing, so a green warm test proves almost nothing about onboarding.
- Every fresh host runs the **cold** path — that's the one onboarding depends on. Test it deliberately: back up + remove the artifact, run cold, assert it was created correctly, then re-run to confirm the warm no-op. (Caught 2026-06-23 on rtj#75: the resolver-writer's first test plan only ran the warm path on a host that already had `/etc/resolver/<suffix>`; a Plan-agent review flagged that the cold path — the one every new host takes — was untested. Fixed by `sudo rm`-ing the file and running cold before close.)
- Generalizes beyond shell: any "ensure X exists / converge to desired state" operation — Terraform resources, migrations, package installs — wants the from-absent path tested, not just the already-converged re-run.

### A valid response is not a correct one — services fail in the shape of success
- An external service can answer **HTTP 200 with a structurally perfect payload that is not the thing you asked for**: a placeholder image, an empty-but-well-formed JSON envelope, a "your trial expired" page served as the resource. Every cheap assertion passes — status code, content type, dimensions, CRS, band count, schema — because the shape is right and only the *meaning* is wrong.
- This defeats the guard you already wrote. A fetch wrapper that returns `NULL` on failure never fires, because nothing failed. So the absence of an error is not evidence, and neither is a green suite: the artifact has to be **looked at**, or compared against something that knows what it should contain.
- Measured 2026-08 in gq#57: Carto made their basemaps key-only and began serving an "API KEY REQUIRED" watermark image. It rendered through a vignette build, `R CMD check`, and a pkgdown deploy onto the public web, watermark and all. Found by a human asking how good the maps were, which meant opening the PNG.
- **Do not reach for a content detector without measuring whether one can work.** The obvious fix — score the pixels, sniff the body — is often provably impossible, and shipping it is worse than shipping nothing because it *looks* like a check. Same measurement: the *watermarked* tile had **fewer** dark pixels (0.0068) than the *clean* one (0.0073), because the watermark is a small share of content and ordinary detail swamps it. No threshold separates them.
- What does work:
  - **Prefer providers/endpoints that cannot enter the degraded state** (keyless where key-only is the failure; a pinned version where "latest" can drift).
  - **Detect the degenerate cases that are actually separable**, and only those. A single-colour image, a zero-row response, an empty archive — cheap, and no false negatives on the case you can measure.
  - **A canary that runs on a human's machine**, not in CI, asserting the live service still returns something real. CI can only tell you the code still runs.
- Note which direction each guard fails in, and prefer warning over discarding when a legitimate input is indistinguishable from a broken one — the cost of an unread warning is far below the cost of destroying valid data.

### An inventory is only complete relative to a boundary — name the boundary
- "I enumerated every call site" is a claim about a **search scope**, not about the world. A `grep -rn` over one repo is complete for that repo and says nothing about the copy of the same snippet living in a docs site, a house skill, a template, a wiki page, or another team's codebase. The enumeration can be flawless and the fix still incomplete.
- The tell is when the thing being changed is a **pattern people copy** rather than a function people call. Anything that has ever been pasted into documentation has an unbounded number of call sites, and the repo boundary is exactly where the search stops being meaningful.
- Ask directly: *what do the downstream users actually read?* Often it is not the API docs. If the answer is a skill file, a README, or an onboarding doc, that file is a call site and belongs in the sweep.
- (gq#57, 2026-08: the provider inventory was complete within gq — 9 lines, 6 files, verified twice. The consumer projects read `soul/skills/cartography`, which shipped its own hand-rolled snippet naming the broken provider and never called gq's function at all. Fixing gq alone would have left every downstream repo pointed at the watermark. Caught by a reviewer asking what consumers read, not by the grep.)

### A defect's magnitude is dataset-specific — measure it where it lands

- Sibling of the rule above, for numbers rather than enumerations. Once a bug is confirmed, the
  natural next question is "how bad is it?" — and the natural next move is to measure on whatever
  fixture is at hand. That number is about **that dataset**, and quoting it about another is a
  guess wearing a measurement's clothes.
- The mechanism: a pipeline usually has several constraints, and a defect only reaches the output
  through the one that binds. Change dataset, change which constraint binds, change the blast
  radius — with no change to the bug.
- Measured 2026-08-31 in `flooded`. A units error inflating a modelled depth by 3.59x was measured
  on the bundled 10 m tile and reported as roughly **2x** the mapped area. On the 30 m production
  watershed the same defect cost **16%** — because there the slope and cost-distance criteria bind
  first and clip most of the error before it reaches the boundary. Both numbers are correct; only
  one of them was about the data anybody cared about.
- **Tell:** you are about to say "so X is roughly N× off" about a dataset you did not measure. The
  fixture is convenient precisely because it is small and well-understood, which is also why it
  does not resemble production.
- The remedy is usually cheap and nobody reaches for it: **re-run the comparison on the real
  input.** In the case above the production inputs were already cached on disk, and the corrected
  run took minutes.
- Corollary worth stating separately, because it changes what a report has to retract: **ratios and
  absolutes do not move together.** In the same measurement, absolute disturbed area fell 16% while
  disturbed-as-percent-of-AOI went 27.51% -> 27.50% — unchanged to two decimals, because the
  over-mapped margin happened to carry the same land-cover mix as the core. Establish which kind of
  claim is affected before telling anyone their published numbers are wrong.

### Do not write to an artifact a human is testing on

- Handing someone a deployed thing to test — a synced project, a staging
  database, a preview build — and then continuing to push changes into it makes
  two writers for one artifact. The tester chases versions, and any client-side
  lock or "another process is running" error that follows is **yours**, not
  theirs to debug.
- It also corrupts the evidence. When the tester reports a problem, you no longer
  know which version they were on, so a symptom cannot be tied to a change.
- Caught 2026-08-26 in rfp#186/#196: three pushes into a live Mergin project
  during a field test, taking it from v1 to v9 while the phone was syncing. The
  app reported "another process is running" and the tester tried removing and
  re-adding the project before the cause was identified as the other writer.
- Rule: **hand over one version and stop.** If a fix is needed mid-test, say so
  and let the tester decide when to take it. Batch changes rather than pushing
  each one. When you must push, say which version you pushed and what changed, so
  a later report can be anchored to it.

### A value nothing reads is wrong silently — get it from the consumer, not from reasoning

- Serialized formats carry fields that are **redundant with a lookup that
  actually happens**: a positional index beside a name, a declared length beside
  a delimiter, a cached count beside the rows. Because the consumer resolves by
  the *other* field, a wrong value here changes nothing observable. It is not
  benign — it is a defect with no failure mode until something new starts reading
  it, and then it fails far from the code that wrote it.
- Your own tests cannot catch this class, and neither can a reviewer: every
  assertion goes through the same name-based lookup the consumer uses, so the
  index is never read on either side.
- **The consumer's own output is the only oracle.** Find an artifact the real
  application wrote, compute your value for the same input, and compare across
  the whole set — not one example, which a plausible off-by-one survives.
- Caught 2026-08-26 in rfp#186: QGIS `<alias index=>` numbering. The obvious
  reading is "position in the table", but the OGR provider excludes **both** the
  geometry column and the integer primary key, so counting `fid` put every alias
  one place out. QGIS resolves an alias by `field` name, so nothing broke and
  nothing could have. Settled by computing indices for a QGIS-authored layer and
  comparing against the aliases QGIS itself wrote — **99/99** — then pinning that
  comparison as a test.
- Review check: for any field you write that your own code never reads back,
  name what does read it and where the ground truth came from. "It seemed
  right" is the whole hazard.
### Measure the output, not the input you handed in
- When you instrument something to find out what it *did*, check that the probe
  reads downstream of the transformation. A probe that reads a value back from
  the same object you populated is not a measurement — it is a round-trip
  through your own assignment, and it agrees with you perfectly.
- The failure is invisible because the number looks like data. It has units, it
  varies when you vary the input, it is stable across repeats — everything a
  real measurement does, except it never consulted the thing that transforms.
- **Tells, in order of usefulness:**
  - The result is *exactly* a constant you can derive from the input — no
    rounding, no jitter. Real ink, real bytes and real timings are messy.
  - The probe reads a field of an object you constructed or configured, rather
    than an artifact the system emitted.
  - Varying something you know matters (a shape, an encoding, a locale) does not
    move the number.
- **Fix: measure at the furthest downstream point you can reach** — the rendered
  primitive, the bytes on the wire, the row as the consumer's own client reads
  it. Prefer a format that is inspectable and exact: an SVG's `<circle r=>`
  beats a rasterised pixel count, and a captured request body beats a mock's
  recorded arguments.
- Caught 2026-08-26 in gq#16, and only by a reviewer. A symbol-size conversion
  was built on "tmap draws 5.08 mm per size unit", measured by reading
  `pointsGrob$size` back off the grob — the value tmap had been *handed*. R's
  graphics engine then applies a per-`pch` factor the grob slot never records, so
  a circle actually draws **3.81 mm**. The fix shipped every symbol 25%
  undersized *while documenting itself as exact*, which is worse than the bug it
  replaced. 5.08 mm is 0.2 inch exactly — the roundness was the tell, and it read
  as elegance instead.
- Sibling of the interop rule below, one step earlier: that one is about whether
  the consumer accepts what you wrote, this one about whether your ruler is
  touching the object at all.

### Percent-encode a URL at construction, not at consumption

- A URL built by string-concatenation from filenames inherits whatever those
  filenames contain. An unencoded space is accepted by lenient clients — browsers,
  `aws-cli` — and rejected by strict ones, so the break is deferred and then
  arrives all at once.
- Caught 2026-07 in stac_dem_bc#25: hrefs carrying literal spaces worked for
  months, then every strict `curl` fetch failed together — 90 items, 0-byte
  fetches. Nothing changed about the hrefs; the consumer changed.
- Encode where the URL is **built**. Encoding at the point of use means every
  future consumer has to remember, and the one that forgets is the one you find
  out about in production.

### A cache written before the work succeeds strands its inputs permanently

- Change-detection caches ("which inputs have I already seen?") must be persisted
  **after** the work they gate succeeds. Rewritten at detection time, any input
  whose processing then fails is marked seen and never built — invisible to every
  future run, because the cache is precisely what future runs consult.
- Caught 2026-02 in stac_dem_bc: 2,107 URLs stranded this way, found only by a
  reconciliation script diffing the cache against actual outputs. Nothing errored
  on any subsequent run; the work simply never happened.
- In CI, committing state at the end of a successful job gives this atomicity for
  free. Elsewhere, write the cache last, or write it atomically alongside the
  output it claims.
- Sibling of "Cache keys must cover every output-affecting input" above: that one
  is about a cache returning the wrong thing, this one about a cache silently
  returning nothing ever again.

### A structure transcribed from an external form or API is a snapshot, not a contract

- Recording an external system's field order — a web form, a report layout, an
  undocumented API response — captures **one instance on one date**. The system is
  free to reorder between revisions, and nothing tells you when it does.
- Where the fields are same-typed (all integers, all strings), a reordering is
  **invisible**: the output stays structurally valid and becomes semantically
  nonsense. No parser complains, because nothing in the pipeline knows what the
  values mean.
- Caught 2026-08 in `template_permit_fish`: a paste-ready answers file built from a
  submitted 2025 permit application encoded the portal's columns as
  `UTM Zone | Northing | Easting`. The 2026 form revision shipped
  `UTM Zone | Easting | Northing`. Pasting in order **transposed easting and
  northing on four of five sites of a submitted permit application**. The same
  revision also replaced the eligibility questions.
- Rules:
  - Record **which instance and what date** the structure came from, beside the
    structure itself.
  - Re-check against a live instance before each use, not once at authoring time.
  - Assert on **magnitude or format, not position**, wherever the types cannot tell
    the fields apart. In UTM Zone 10 an easting is 6 digits and a northing is 7
    digits starting with 6 — an assertion that would have caught this one.
- Same diagnostic family as "a wrapper's exit 0 is not the work completed": the
  output is structurally valid and semantically wrong, so every check that looks
  only at shape passes it.

### A grep that cannot show a failure is not a check

- Filtering a run's output to the lines you expect is not verification. If the
  filter cannot match an error, a failing run and a passing one look identical —
  and the lines immediately before a fatal error are usually exactly the ones you
  were hoping to see.
- Seen 2026-08-29: a driver run was piped through
  `grep -E "greyscale stretch|added"`. It matched the line printed one statement
  before `Error: could not find function`, and the success was reported from that
  match. The work was then completed by hand, which produced the right result and
  hid that the driver had not. A PR claim of "verified end to end" was true of the
  earlier commits and false of that one.
- This is the sibling of *"a wrapper's exit 0 is not the work completing"* below,
  one step earlier: that rule is about trusting the wrong exit status, this one is
  about never seeing the status at all. `cmd | grep ...` reports **grep's** exit,
  so `$?` is 0 whenever the pattern matched, whatever the command did.
- Capture the whole run, gate on it, then look at the part you care about:
  ```bash
  cmd > run.log 2>&1; rc=$?
  errs=$(grep -c 'Execution halted\|^Error\|could not find' run.log)
  [ "$rc" -eq 0 ] && [ "$errs" -eq 0 ] || { tail -30 run.log; exit 1; }
  grep -E "the interesting lines" run.log
  ```

### A round-trip through your own reader proves nothing about interop
- When code writes a format some **other** program consumes — a database table, a config file, an export another tool imports — a test that writes then reads it back with your own reader validates only that you are self-consistent. It cannot detect that the real consumer rejects what you wrote.
- Symptom when wrong: every test green, the artifact byte-perfect on inspection, and the feature silently does nothing in production. Failures on the consumer's side are often **silent by design** — a lookup that matches nothing returns "no result", not an error.
- Get the real consumer into the loop, even if awkward: run it in a container, shell out to its CLI, gate the test on the tool being installed and skip otherwise. Then keep a cheap structural assertion alongside for CI, so the invariant is still guarded when the heavy test skips.
- Best ground truth is **the consumer's own output**: have it write the artifact once, then diff yours against it. That surfaces required fields no documentation mentions.
- (rfp#17, 2026-08: `layer_styles` rows were written with `f_table_schema` NULL. QGIS looks a style up with an equality match passing `""`, and `NULL = ''` is never true in SQL, so every row was invisible — `loadDefaultStyle()` returned FALSE, layers drew with default symbols, nothing logged. The rows round-tripped perfectly through DBI, so the whole suite was green. Found only by asking QGIS in a container, then bisecting against a row QGIS wrote itself.)

### A reference generated by feeding your artifact to the consumer is circular

- The interop rule above says to get the real consumer's own output as ground
  truth. The trap is *how* you get it. Ask the consumer to **load your artifact
  and save it back** and it hands you your own artifact with its blessing — so
  every later comparison against that reference passes by construction, however
  wrong the artifact is. It looks like the strongest possible evidence, because
  the consumer really did produce the file.
- The tell is a generation step of the shape `load(ours) -> save()`. Ground truth
  has to be **constructed from the consumer's own API**, from inputs that are not
  your artifact, so the consumer decides the shape rather than echoing it.
  ```python
  # circular: hands back what it was given
  layer.loadNamedStyle('/data/ours.qml'); layer.saveNamedStyle('/data/ref.qml')

  # ground truth: the consumer builds it
  layer.setRenderer(QgsHillshadeRenderer(prov, 1, 315.0, 45.0))
  layer.saveNamedStyle('/data/ref.qml')
  ```
- Same shape outside XML: a schema "validated" by exporting your own rows and
  re-importing them, a golden file regenerated by the code under test, a fixture
  built by serialising the object you are about to assert on.
- Caught 2026-08-30 in rfp#227. The repo already carried a note that a style file
  *it had exported* was useless as evidence about that consumer's behaviour — and
  the obvious way to author the new references would have reintroduced exactly
  that, through a helper that already existed and did the wrong one of the two.
- Pairs with the fixture rule below: a reference that cannot disagree with you is
  the fixture-set problem in its purest form, since **no** input can reach the
  failure mode.

### Mocking the transport means the request is never built
- A network client mocked at its HTTP boundary — `local_mocked_bindings(.do_http = ...)`, `responses`, `nock`, a stubbed `fetch` — gives excellent coverage of *response* handling and **zero** coverage of the request. Status codes, retries, backoff, parse errors, partial bodies: all testable. Method, headers, content type, and body encoding: never exercised, because no test that stubs the transport constructs one.
- The gap is invisible in the usual way. The suite is green, the code reads correctly, and the first real call fails with a status that looks like the *server's* problem — a 400 or a 406 reads as a bad query or a rate limit long before it reads as "we sent the wrong content type".
- Sibling of the interop rule above, one level lower: that one is about what a consumer reads from your artifact, this one is about whether the request ever reaches the consumer at all.
- Fix pattern: make the wire format a **pure function** and assert it offline — `build_body(query)` returning a string, tested for its prefix, for a round-trip back through the decoder to the original input, and for no unescaped metacharacters surviving. Cheap, no network, and it guards the exact thing the mocks cannot.
- Verify the real encoding once against the live service and record the result, because the wrong choice is often the more obvious-looking API. (rfp#168, 2026-08: `curl::handle_setform()` reads like the way to send a form and sends `multipart/form-data`; the Overpass API answered **400** on every endpoint, having answered **406** to a raw body. Only `data=` url-encoded via `postfields` returns **200**. 130 tests passed while this was broken, and more of the same kind would not have helped.)

### A fixture set that cannot reach the failure mode is not validation
- Hand-picked fixtures test the cases you thought of. If every one of them is structurally incapable of triggering the bug class you are fixing, a green run means nothing — and it is *more* dangerous than no test, because it licenses the claim "validated".
- Before declaring a fix verified, ask what the fixtures have in common and whether that shared property is the very thing the bug depends on. If it is, the set has a hole no amount of additions to it will close.
- **A fixture that matches the code's happy path makes whole branches unexecuted.** Not
  merely untested — never run. A single test raster in the same CRS as the data makes
  every reprojection an identity, so a units error there is invisible to a full suite;
  fly#9 shipped one that reported coverage of `1.4e-10` on a geographic raster while 200+
  tests passed. Ask which branches your fixture *cannot enter*, and vary the fixture along
  exactly those axes — CRS, resolution, extent, spread — rather than adding more cases
  along the axis it already covers.
- Prefer a **global structural invariant** over more examples. Properties like antisymmetry, transitivity, "every node reaches a terminal", or a conservation total sweep the whole domain and cannot be gamed by fixture choice.
- (link#227 / fresh#214, 2026-08: a watershed drainage-closure fix was declared validated on 8 hydrology fixtures. All 8 compared groups with *differing* stream codes — the bug only manifests between groups sharing one code, so the set could not have caught it. The very next case tried, the Fraser, dropped the group the entire basin drains through. What actually earned the claim was a transitivity sweep: 0 violations across 3,537 triples, plus 0 cycles and every group reaching an outlet.)

### A negative-case fixture rots when the positive set grows
- A test asserting "X is refused" has to pick a concrete X that nothing supplies. The moment someone adds support for that exact X — a new shipped resource, a new registry row, a new supported format — the assertion breaks, and it breaks in a way that reads as *the feature is wrong* rather than *the fixture is stale*.
- The failure is loud, which is lucky. The dangerous variant is the same change landing where the test would still pass: a refusal test whose chosen X quietly becomes supported and whose assertion is on something looser than the refusal itself now passes for nothing.
- Fix by **asserting the premise beside the assertion**, in the same test:
  ```r
  unshipped <- "EPSG:32609"
  expect_false(nzchar(system.file("extdata", "srs",
    paste0(gsub(":", "_", unshipped), ".xml"), package = "rfp")))   # <- the premise
  expect_error(add_layer(qgs, crs = unshipped), "cannot be copied") # <- the property
  ```
  Then a future addition to the shipped set fails on the premise line, naming the real cause, instead of on the behaviour line, blaming the code under test.
- The same shape applies to any "this input is unsupported" test: unsupported file extensions, unregistered layer types, unknown enum values. Ask what would have to become true for the chosen input to stop being unsupported, then assert it is still false.
- (rfp#139, 2026-08: shipping an `EPSG_4326.xml` `<srs>` block so a tracking layer could carry a CRS no template used made that CRS resolvable from a package resolver's third tier — breaking a raster test that had picked EPSG:4326 precisely because nothing supplied it. The behaviour was correct in both directions; only the fixture's premise had expired.)

### A guard's escape hatches are where it goes to die — read them first
- Every guard grows two things that can silently disable it: an **exemption
  list** ("these are allowed to fail the rule") and a **lookup** ("find the
  thing I am checking"). Both fail toward *pass*, and both read as diligence on
  the page. When reviewing a guard, read those two before reading the
  assertion — the assertion is the part that is usually already right.
- **An exemption list that covers every input makes the assertion unreachable.**
  It is not a weakened guard; it is a guard that cannot go red, and it looks
  more careful than the correct version because it is longer.
  ```r
  legend_exempt <- c(
    lake    = "drawn and legended",     # <- every one of these is a REASON
    wetland = "drawn and legended",     #    to remove the entry, not to keep it
    ...                                 #    all 9 drawn layers listed
  )
  missing <- setdiff(drawn, c(legended, names(legend_exempt)))   # always empty
  ```
  **Tell:** an exemption whose reason says the rule *is* satisfied. "Drawn and
  legended" is not a reason to exempt something from a drawn-must-be-legended
  check — it is the check passing. An exemption is only ever for an input the
  rule should genuinely not apply to, and `character(0)` is a normal and healthy
  state that deserves a comment saying so.
- **A lookup that matches a container rather than the artifact reports success
  and then dies — or worse, checks the wrong thing.** Test for the *file*, never
  for a directory of the right name:
  ```r
  for (up in c("..", "../..", "../../..")) {
    if (dir.exists(file.path(up, "vignettes"))) return(...)   # matched SOME vignettes/
  }
  ```
  Under `R CMD check` that walked out of the package into the temp tree, matched
  an unrelated `vignettes/`, and blew up in `readLines()`. Had a same-named file
  existed there it would have silently checked a stranger's copy.
- Both caught 2026-08-26 in gq#61, in the same 100-line test file, written by
  someone who had just added the "fixture that cannot reach the failure mode"
  rule below. Neither was visible by reading; the first surfaced by restoring
  the bug, the second only under `R CMD check` — `devtools::test()` passed it
  because the source tree happens to have the directory where it looked.
- **Corollary on where you verify.** A guard that reads repo layout behaves
  differently under `devtools::test()`, `R CMD check`, and an installed package.
  Green in the one you run locally says nothing about the one CI runs. Run both
  before believing it.

### Do not branch on a value only some code paths populate

A variable that one route fills in and another leaves `NA` is not a safe thing to test.
The condition reads as a property of the row — "has this been sized", "is this
non-square" — but it is really a property of *which route ran first*, so every branch
downstream inherits an ordering dependency nobody wrote down.

The failure is total and silent for the affected rows: the condition is uniformly false
for a whole class of input, so the branch is never taken, no warning fires, and the
reporting columns say the work happened.

**Tell: the value is assigned in more than one place, and at least one of them is
conditional.** Ask what it holds for a row that has taken none of those paths yet — if
the answer is `NA`, anything branching on it before every path has run is testing
arrival order.

Measured 2026-08-30 in fly#32, where the same `NA`-by-construction fact broke **three
separate conditions** in one function over three review rounds, each found inside the
previous round's fix:

| round | condition | consequence |
|---|---|---|
| 1 | `sized <- !is.na(half_side)` | fine for the old single route |
| 2 | `corrected <- sized & !by_gsd` | the two are disjoint, so the DEM route was unreachable for every row it existed to serve — 24/24 empty, silently |
| 3 | `non_square <- abs(half_cross - half_along) > tol` | computed before the DEM route fills those values, so DEM-sized frames were never rotated; and the answer depended on **what else was in the batch** |

The fix is not a better condition. It is to branch on something known **before any route
runs** — there, the recording format's aspect ratio rather than the sized half-dimensions.
Derive the predicate from the inputs, not from a work-in-progress.

**Batch dependence is the confirming symptom.** If whether row *i* takes a branch can be
changed by editing row *j*, the predicate is reading shared mutable state. Test it: run
one row alone and in company, and compare.

Related to the proxy rule below — both are conditions that stand in for the property you
actually want — but distinct in remedy. A proxy needs a truer measurement; this needs the
same measurement taken *earlier*.

### A guard that encodes the cause you measured is a proxy for the property you want

You reproduce a bug, measure the state that produced it, and write the guard
against that state. It fixes the case in front of you and leaves every other
state with the same *property* wide open — because the condition you wrote is a
proxy, and the thing it stands for is what actually matters.

The tell is a guard whose condition names a **mechanism** ("has no row in table
X", "the file is older than Y", "the id is one of these two values") where the
requirement is a **capability** ("can be resolved", "is current", "means
something"). Ask: *what property was I actually testing for, and is my condition
equivalent to it or merely correlated with it?* If it is a list of known-bad
states, the list is incomplete and nothing will tell you when.

Measured 2026-08-29 in rfp#218, over four review rounds each of which fixed the
previous round's fix. Carrying geometry across a CRS change had three failure
arms, and the same broken file took a different one depending only on the
**target** CRS:

| arm | what happens | guard that works |
|---|---|---|
| **skipped** | the source CRS will not resolve, the branch is never entered, values carried verbatim | the symptom: `is.na(st_crs(x))` |
| **vacuous** | the transform runs and is an exact identity | a file-level fact the transform cannot see |
| **failed** | it returns `NaN` for every value without raising | a post-condition on the result |

Round 2 post-conditioned the *failed* arm — a check on the result of an
operation it assumed had run and meant something. Round 3 found the *vacuous*
one and enumerated the file-level states it had measured. Round 4 found that
one of those states, "has no `gpkg_spatial_ref_sys` row", was a proxy for
"`st_crs()` can resolve it": a row that **exists and resolves to nothing** passes
the check and corrupts. The skip arm now guards the symptom directly, which
needs no guess about which state caused it.

Two things that generalise:

- **Guard the symptom where you can test it directly**, and reserve enumeration
  for the arm where the symptom is invisible — here, the vacuous transform,
  where everything looks healthy and only a file-level fact discriminates. One
  guard per arm; they are not interchangeable, and a single "better" condition
  covering all three does not exist.
- **Check the fix does not refuse recoverable input.** A garbage `definition`
  under a real EPSG id still resolves through its organisation code and
  transforms correctly. Refusing it would have been a false refusal of live
  field data, which is worse than the bug — so that case is asserted as its own
  test, beside the refusals.

And the fixture rule below applies with teeth here: a fixture pinning one target
CRS reaches **one** of three arms while appearing to cover the behaviour. Where
an input dimension selects which failure you get, that dimension belongs in a
table, with a healthy control at each value so the guard is distinguishable from
one that refuses everything.

### A probe reporting a defect in long-shipped code is usually a broken probe

When an ad-hoc probe says something that has worked in production for months is
broken, the prior belongs on the probe, not on the code. Check the instrument
before you write the finding up — and certainly before it becomes scope.

**The tell is an obviously-correct item in the failure list.** A probe that
reports 13 things missing, and the list contains items you can see with your own
eyes, has not found 13 defects and one false positive; it is wrong about all 13.
Scan the output for something you already know is fine, and if it is in there,
stop reading the finding and read the probe.

Measured 2026-08-29 in rfp#216. An issue flagged a map-theme group as possibly
dangling, and a probe "confirmed" it — 13 theme rows naming groups not in the
layer tree. The probe built each group's path by walking parents to the document
root, which is *itself* an unnamed group node, so every path gained a phantom
leading segment and nothing matched. `bcrestoration Mobile /Basemap` was in the
missing list, which is a group anyone can see in QGIS. Anchored at the right
node, **0** of 25 rows dangled and the whole finding evaporated.

Two habits, both cheap:

- **Print a positive control.** Have the probe assert something you know is true
  before reporting what is false — "these 3 groups resolve" beside "these 13 do
  not". A probe that cannot find the known-good case is not measuring what it
  claims.
- **Reconcile the count against the population.** 13 of 25 rows broken in a
  shipped artifact would mean half a feature has been failing silently. If a
  finding implies a failure rate nobody has noticed, the failure is in the
  measurement far more often than in the world.

The inverse case is real but rarer, and it announces itself differently — a
genuine long-lived defect usually has a *reason* nobody noticed it (a guard that
cannot see it, a code path nothing exercises), and you can name that reason. If
you cannot say why it went unnoticed, you have not found it yet.


#### And a probe reporting that EVERYTHING is broken is the same thing, louder

The sibling case, and it is easier to catch because the failure rate gives it
away: if a check reports *every* case failing while the printed values are
visibly equal, the comparator is wrong, not the world.

In R the usual cause is integer-versus-double, because `length()`, `nrow()` and
`sum()` return integer while a bare literal is double:

```r
identical(length(x), 1)     # FALSE — `length()` is integer, `1` is double
identical(length(x), 1L)    # TRUE
length(x) == 1              # TRUE — `==` coerces, `identical()` does not
```

Measured 2026-09-01 in rfp#242: an attack matrix of 13 shapes printed
`want=1 got=1` on every row and reported **13 of 13 mismatches**, because the
comparison was `identical(got, want)` with `got` from `length()`. Nothing was
wrong with the code under test.

The reconciliation habit from the rule above works here too, pointed the other
way: **a 100% failure rate is as implausible as a 50% one in long-shipped code.**
Before writing up a finding, print one case you know is good and confirm the
probe agrees; if it does not, the probe is the subject.

Same shape outside R wherever equality is type-strict — JavaScript `===` across
number and string, Python between `Decimal` and `float`.

### Restore the bug and confirm the test fails
- The rule above says a fixture that cannot reach the failure mode is worthless. This is the thirty-second check that tells you which kind you just wrote: **put the defect back, run the test, watch it go red.** A test that stays green against the code it was written to reject is decoration, and reading it will not tell you that — every case below looked correct on the page.
- Cheapest form when the fix is inside a package: patch the binding rather than editing the source back and forth. For a data-shaped bug, feed the function the input the fix was about and assert the old answer is gone.
- **In R, patching only `asNamespace()` gives a false green for anything test code calls directly.** `pkgload::load_all()` (so `devtools::test()`, so every local run) creates **two** bindings: the namespace, and an attached `package:<pkg>` on the search path. Test code resolves through the search path and never consults the namespace, so the obvious recipe leaves the test calling the *original* function while reporting success.
  Measured 2026-08-28 in flooded#41, restoring a fully-reverted bug under `test_file()`:
  ```
  unpatched                          FAIL = 0     zeros = 1    (fixed behaviour)
  asNamespace("flooded") patched     FAIL = 0     zeros = 1    <- false green, bug not reached
  + as.environment("package:flooded") FAIL = 3    zeros = 400  <- broken code actually runs
  ```
  Which binding you want depends on who calls:

  | the call under test | patch |
  |---|---|
  | test code -> an exported function | `as.environment("package:<pkg>")` |
  | one package function -> another (internal call path) | `asNamespace("<pkg>")` |
  | either, on testthat >= 3.2.0 | `local_mocked_bindings(f = ..., .package = "<pkg>")` |

  ```r
  for (e in list(asNamespace("pkg"), as.environment("package:pkg"))) {
    unlockBinding("f", e); assign("f", broken_version, e)
  }
  ```
- **Restore the defect from the source that had it, not from memory.** A hand-rewritten
  "previous version" is a *different* program, and the difference is invisible because
  both look like the bug you remember. Measured 2026-08-29 in fly#9: a reconstruction
  used `sum(!is.na(x))` where the original had `length(x)`, and failed **4** tests where
  the real prior code failed **0** — so the reconstruction said "the guard works" about a
  guard that did not. Pull the exact bytes:
  ```bash
  git show <sha>:R/f.R | sed -n '/^my_fn <- function/,/^}/p' > /tmp/prior.R
  ```
  The direction of that error is the dangerous one: a reconstruction is *more* likely to
  fail the tests than the real defect was, because any incidental difference can trip an
  assertion. A green reconstruction proves nothing and a red one proves almost nothing.

- **Do not reason about which environment — print a value that proves the patch took.** One line, before the assertion, whose output can only come from the broken version. That is what turns "I patched it" into "the broken code ran", and it is the same check whether the language is R, Python or JS. Assigning into `globalenv()` also appears to work in R, by *shadowing* the attached copy earlier on the search path — a workaround that happens to produce the right answer for the wrong reason, and silently fails the moment the caller is inside the package.
- Three instances in one PR (gq#52, 2026-08), all written by someone who had just read the fixture rule directly above:
  - A scale-bar test asserting the bar stays within `share` of the frame — threshold hardcoded at **0.75** against a `share` of **0.35**, so a bar at 2.1x the requested size passed. Every width in the fixture also happened to round *down*, so none could overrun even at the right threshold.
  - A clamp test for a bbox padded past ±90 — the box chosen padded the **x** axis, so the latitude clamp it was named for could never fire.
  - An `options(str=)` independence test routed through real registry data whose values stayed distinct at one decimal. With the buggy key restored it still passed; a synthetic `1.32 / 1.34` pair made it fire.
- A fourth, of a different kind, from the entry above: the restoration *harness* can be the thing that is broken. A green run proves nothing until you have evidence the defect was actually executing.
- What they share is the tell: the **assertion** is correct and the **input** cannot reach it. So review the fixture against the bug, not the assertion against the spec — the assertion is the part that reads well and the part that is usually already right.
- Sibling of the interop rule above, at one remove: a test that inspects a structure its consumer would reject is the same failure. In that same PR, 18 tests read a legend object and none passed it to the renderer, which refused it outright.

### Bare `y`, `n`, `on`, `off`, `yes`, `no` are booleans in YAML 1.1
- The YAML 1.1 core schema resolves `y`, `Y`, `n`, `N`, `yes`, `no`, `on`, `off`, `true`, `false` (and their case variants) to **booleans**. Most parsers in wide use — libyaml, PyYAML, R's `yaml` — still do this.
- So a column, key, or field literally named `y` stops being a string the moment it is written unquoted:
  ```yaml
  cols:
    - name: y        # parses as logical TRUE, not "y"
  ```
  Nothing errors. The consumer simply never matches that entry again, and whatever it was supposed to do to it silently does not happen.
- Bites hardest in **schema and config files**, where single-letter names are normal: coordinate columns (`x`, `y`, `z`), flags, short codes. Quote them: `- name: "y"`.
- Caught twice in one file 2026-08-24 (crate#9) — once in a canonical column list and once in a variant's column list. Both found by a guard that asserted every declared name `is.character()`; reading the YAML had not found either.
- Worth an assertion rather than vigilance: after parsing any config that carries user-chosen names, check they are all strings. The failure is invisible otherwise, because the wrong value is a perfectly valid one.

### List the container; do not construct the sibling path
- Probing for a related object by editing a known-good path — swapping a
  directory, appending a suffix, substituting a product name — assumes the
  naming convention is uniform across the whole store. It usually is not, and
  the places it is not are invisible from any single example.
- The failure is a **404, which reads as "that product does not exist"** rather
  than "I guessed the name wrong". So the wrong conclusion arrives looking like
  evidence, and it is the confident kind: a checked path that returned nothing.
- Measured 2026-08-27 in the BC LidarBC objectstore. Swapping `/dem/` for
  `/dsm/` in a tile's URL:
  ```
  2022  dem/bc_082f037_xli1m_utm11_2022.tif
        dsm/bc_082f037_xli1m_utm11_2022.tif        <- same basename, swap works
  2017  dem/bc_082f037_xli1m_utm11_2017.tif
        dsm/bc_082f037_xli1m_utm11_2017_dsm.tif    <- suffixed, swap 404s
  ```
  A probe run against a 2017 tile concluded "there is no surface model and no
  CHM", and that became the central constraint of a project plan — ruling out
  canopy measurement entirely — for weeks. Listing the prefix instead showed
  `dem, dsm, pointcloud` and more immediately, with DSM present in 25 of 38
  mapsheet-years.
- **Enumerate the container** (`?list-type=2&delimiter=/&prefix=…`, `ls`, the
  API's own listing endpoint) and match on the fields that actually identify the
  thing — tile, date, product — rather than on a name you assembled.
- When pairing two families this way, **report the unpaired members**. An item
  with no partner is a real gap, and silently dropping it turns a coverage hole
  into an apparently complete result.

### A verifier built on the writer's own library shares its blind spot
- After rewriting a file, the natural check is to parse both versions and
  compare their structure. That check is worth much less than it looks when
  the same library does both jobs: **anything the library does not model, it
  will neither preserve nor miss.** The comparison comes back identical, and
  the loss is invisible precisely where it matters.
- Live case, 2026-08-27: Python's `ElementTree` **silently drops the
  `<!DOCTYPE>`** when it writes. A `.qgs` carries one. The structural check —
  root tag, layer count, theme count, tree nodes — reported IDENTICAL, because
  `ElementTree` does not need a DOCTYPE to parse either. R's `xml2::write_xml`
  preserves it, which is why the same operation through the package's own
  writer had never shown the problem.
- The prologue is the usual casualty in XML (DOCTYPE, processing
  instructions, comments, namespace prefixes, attribute order), but the shape
  is general: JSON writers drop key order and numeric precision, YAML writers
  drop anchors and comments, image libraries drop EXIF.
- Two habits that catch it:
  - **Diff the bytes at the boundaries**, not just the parsed structure —
    `head -2` and `tail -2` on both files costs nothing and is exactly where
    prologue loss shows.
  - **Check what the real consumer needs**, then assert that specifically. The
    generic "did the structure survive" question cannot ask it for you.
- Sibling of *"A round-trip through your own reader proves nothing about
  interop"* above, one level meaner: there the reader was too generous, here
  the **verifier** is, so the failure survives a check that was written
  specifically to catch it.

### Canonicalize serialized documents before diffing them
- XML and JSON emitters are free to vary attribute order, whitespace, and regenerated ids without changing meaning. Comparing two such documents raw reports differences that are not differences — and the noise scales with document size, so it looks like a real signal.
- Normalize first: C14N for XML (`ET.canonicalize(strip_text=True)` sorts attributes), key-sorted dumps for JSON, and mask any regenerated identifiers (uuids, timestamps, generator version stamps).
- Then narrow the mask deliberately. Every field you normalize away is a field the comparison can no longer catch, so name each one and why — a mask that quietly grows turns a drift guard into decoration.
- (rfp#17, 2026-08: comparing two QGIS templates raw said 5 of 43 shared layers still matched, which read as severe drift and argued for restructuring how styles were stored. Canonicalized — attributes sorted, symbol uuids masked — it was **46 of 47**. The templates had not drifted at all; the difference was attribute order between two QGIS builds. The naive number nearly bought an architecture change nobody needed.)

### A verification command can be shadowed by a shell function or alias
- The shell is initialized from the user's profile, so `diff`, `grep`, `ls`, `cat` and friends may resolve to a wrapper rather than the binary you assume. Measured 2026-08-24 in gq: `diff` was a shell **function** delegating to `git diff`, so `diff -q a b` — a byte-comparison in an idempotency check — died on ``unknown switch `q' `` and the step reported **NOT IDEMPOTENT** for two files that were in fact identical.
- That direction is survivable because it is loud. The dangerous one is a wrapper that exits 0 on a comparison it never performed, which reads as "verified".
- For anything whose output you are about to treat as evidence, bypass the lookup: `command diff`, `\diff`, or a tool with no common wrapper — `cmp -s` for byte-equality, `md5` / `sha256sum` for a value you can print. Printing the digest beats printing a verdict: it stays checkable after the fact.
- `type <cmd>` tells you what you actually have. Worth running the first time a verification step returns something surprising, before believing the surprise.

### A comparison test proves nothing if the fixture makes both sides identical
- A test of the form "configuration A and configuration B produce the same result" is only a test when A and B *can* differ in the data it runs on. When the fixture makes them equivalent, the assertion holds for every implementation — correct or broken — and the green tick is indistinguishable from a real pass.
- Measured 2026-08-27 in flooded#40: a test asserted that grouping a floodplain by `gnis_name` and by `blue_line_key` produced the same union of ground. In the bundled test data those two columns are a **bijection** — 5 groups each, one-to-one — so the two runs were the same run with different labels. The test could not fail. Replaced with a constructed coarsening (merge the 5 fine groups into 2, assert each coarse group equals the union of its members, cell for cell), which is the property that actually mattered and can be broken.
- The tell is that both sides come from the *same* fixture column set. Before writing the assertion, compute the cross-tabulation — `table(a, b)` — and look at it. A diagonal means you have one test, not two.
- Same shape, different dress: comparing two code paths that a small fixture drives down the same branch, or two parameter values that both fall outside a threshold the data never approaches. Check that the fixture reaches the distinction, not just that the code contains it.
- Generally: when a test passes on the first run, ask what edit to the code under test would make it fail. If you cannot name one, the test is documentation, not verification.

### Documentation Staleness
- Moving/renaming scripts: update CLAUDE.md, READMEs, usage comments
- New variables: update .tfvars.example
- New workflows: update relevant README

### Generating from another repo's working tree copies its half-finished edits
- Tooling that reads a *source* repo to generate a *target* file (`claude-md-init` reading `soul/conventions/`, template renderers, codegen from a schema repo) reads the working tree by default. If a second session is mid-edit there, you silently bake uncommitted, possibly-inconsistent state into a commit in the target — and the target's git history then attributes it to you.
- Worse than a stale read, because partial edits are *internally* inconsistent. Cross-references are the tell: a file gaining a section renumbers its siblings, and pointers elsewhere update in a **later** commit. Catch it halfway and you ship a pointer to the wrong section that resolves to plausible, wrong content.
- Caught 2026-08-26 syncing `fly` from `soul`: `karpathy.md` gained a section, shifting "Subagents Are Evidence" from §5 to §6. `planning.md`'s pointer was corrected in soul minutes later, in a separate commit. The sync landed between the two, so `fly` shipped "see `karpathy.md` §5" pointing at the wrong rule. `git pull` in soul reported "Already up to date" both times — the changes were staged, not unpushed, so nothing about the source repo *looked* stale.
- Generate from the committed tree, not the checkout:
  ```bash
  SRC=$(mktemp -d) && git -C /path/to/source archive HEAD <subdir> | tar -x -C "$SRC"
  ```
- Verify the same way after any concurrent-session sync: rebuild from `HEAD` into a temp file and `diff` it against what you committed. Identical means the source was quiet while you read it; a diff is the drift, and it is cheaper to find now than in a downstream repo weeks later.

### A guard must not fail toward "abort" either

- The complement of "A guard must not fail toward *skip*" above. A gate that
  demands perfection from an operation where partial failure is **certain** will
  discard completed work, and it looks like rigour right up until it fires.
- `return 1 if errors else 0` over ~98k network requests is not a safety check, it
  is a coin flip on transient failure. Measured 2026-08-29 in stac_dem_bc: a
  backfill completed all 98,040 items in 16m37s, wrote 91,556 correct ones and
  passed its verify — then exited non-zero on **2** failures (0.002%), which
  skipped the publish and threw the run away.
- Fix in three parts, in this order:
  1. **Retry in-process** before an error can reach the exit code. Transient means
     retryable — every one of the 34 failures in an earlier local run re-fetched
     fine on the next attempt.
  2. **Gate on a rate against a stated tolerance**, not on zero, and test it
     against both known answers: a rate that must pass and one that must fail.
  3. **Persist progress state on the failure path** (`if: always()` in CI). The
     expensive half of that incident was not the failed exit — it was that the
     manifest recording 98,038 successes was only committed by a step that gets
     skipped on failure, so a re-run would have restarted from zero.
- Ask which direction the failure costs more. For a read-mostly bulk job, aborting
  on 0.002% is far worse than proceeding and reporting.

### A progress bar on stderr silently eats your log lines

- Extends "Merging stderr into stdout corrupts the stdout you are parsing" above.
  That entry covers stdout being corrupted; this is the other half — log lines
  **disappearing entirely**.
- `tqdm` (and any `\r`-based progress renderer) writes to stderr and returns the
  carriage. A `logger.warning` interleaved with it is overwritten and never
  appears — not truncated, not garbled, *absent*.
- Cost 2026-08-29: per-item failures in a 98k-item run were logged with
  `logger.warning` alongside a tqdm bar. Both locally and in CI the failing ids
  were unrecoverable from the log; the local ones had to be reconstructed by
  differencing a manifest against the input set, and the CI ones were simply lost.
- Fix: per-item diagnostics go to a **file**, not to a stream a progress bar
  shares. Keep the bar for humans, keep the record for machines.

### A fix to code that writes data is not done until the written data is reconciled

- Changing the writer changes nothing already written. The code is correct, the
  tests pass, the issue closes — and every existing record keeps the defect, often
  for months, because nothing reports the gap.
- Four instances in a single day (2026-08-29, stac_dem_bc), all the same shape:
  - `dsm` assets added to item creation; ~91.5k published items had none.
  - URL encoding fixed in the writer (#25, merged); **90 published items kept
    hrefs that could not be formed into an HTTP request at all** — `curl` returned
    no status. Broken since they were first built.
  - `providers`/`keywords` added to the collection builder; the published
    collection was never regenerated, so it never got them.
  - An ARG_MAX fix written into *this file* while the script it was found in kept
    the bug, and re-fired 13 months later on a bigger collection.
- Worse, the defect can be **self-perpetuating**: that catalogue's monthly job
  fetches the published `collection.json`, appends to it, and writes the same 90
  broken links back out every run.
- What closes it: a reconciliation pass over existing records (rewrite in place,
  do not rebuild — see below), plus a count you can check afterwards. "Fixed in
  the writer" is a half-finished sentence.
- **Rewrite, do not rebuild.** Rebuilding regenerates records through today's code
  path, which is not the path that produced them. In that catalogue 60,324 of
  100,345 records came from a fallback branch emitting a different property set —
  a rebuild would have silently replaced them with differently-shaped output,
  invisible in a single-record spot check. Fetch, edit the one field, write back,
  and diff a sample to prove nothing else moved.

### `system2()` shell-quotes the command but not the arguments

- `system2("git", c("-C", dir, "status"))` breaks the moment `dir` contains a
  space: the command name is quoted, the args are pasted on raw and re-split by
  the shell. Wrap every path or user-derived arg in `shQuote()`.
- It fails in the direction that hides itself. A `git -C "/some path" rev-parse`
  that gets split returns nothing on stdout, so a probe reads it as "not a git
  checkout" and **skips every later check** rather than erroring. The provenance
  guard then reports nothing wrong because it never ran.
- Same family as the stderr-interleaving rule above, and the same fix shape:
  read the exit **status**, not just the output. `stdout = TRUE` discards the
  status, so `length(out) == 0` conflates "the command failed" with "there was
  nothing to report" — check `attr(out, "status")`, or call again with
  `stdout = FALSE` when you only need pass/fail.
- Caught 2026-08-29 in gq#64, and only by testing the guard against a checkout
  deliberately placed at a path containing a space. Reading it proved nothing;
  the two-answer test did.
- **And it *raises* rather than returning a status when the command does not
  exist.** So a skip written after the call cannot be reached, and a machine
  lacking the tool errors the test instead of skipping it — reported as
  `error in running command`, which reads as a broken test rather than a missing
  dependency. `suppressWarnings()` does not catch it; it is an error, not a
  warning. Test for the tool **before** calling it:
  ```r
  skip_if(!nzchar(Sys.which("git")), "git not installed")
  out <- suppressWarnings(system2("git", args, stdout = TRUE, stderr = FALSE))
  expect_null(attr(out, "status"))   # a tool that RAN and failed is a failure
  ```
  Watch for a skip condition that cannot hold: `is.null(attr(out, "status"))`
  means the command exited 0, which means it ran — so ANDing it with "the tool is
  absent from `PATH`" is dead code that reads as careful. Caught 2026-08-31 in
  gq#76, in the fix for a fail-toward-skip written one commit earlier.

### `expect_setequal()` refuses NULL, and `names(character(0))` is NULL

- An exemption list keyed by name — `c(layer_a = "reason", layer_b = "reason")` —
  is normally asserted two ways: the offenders are all exempt, and every
  exemption is still needed. The second calls `names()`.
- Emptying that list, which is the goal every such list documents as its correct
  state, then **errors the test**:
  ```r
  local_exempt <- character(0)     # or c(), or NULL
  names(local_exempt)              # NULL, not character(0)
  expect_setequal(setdiff(names(local_exempt), offenders), character(0))
  #> Error: `object` must be a vector, not `NULL`.
  ```
- Use `stats::setNames(character(0), character(0))`, and say why in a comment —
  it reads as a affectation otherwise and the next person will simplify it back.
- **Do not fix it by deleting the "still needed" assertion.** That assertion is
  the tripwire that makes the list a set of decisions rather than a backlog;
  removing it to make emptying easy discards the reason the list was trustworthy.
- The trap is that this fires at the exact moment of success. The guard works for
  as long as it has entries, and breaks when you finally earn the empty state —
  so it is a bug you cannot meet until the day you are trying to close the issue.

### A writer that rewrites a whole file changes more than the rows you added

- Appending via a library writer usually means read-all, append, write-all. The
  library then imposes its own conventions on **every** line, not just yours:
  Python's `csv.writer` terminates with `\r\n` by default, so a two-row append
  converted an entire CSV to CRLF and every line showed as modified.
- The diff stat is the only warning, and it is easy to skim past — "21
  insertions, 19 deletions" for two added rows. Read the count against your
  intent: if it exceeds what you changed, stop and look before committing.
- Prefer opening in append mode and writing only the new bytes, with the
  terminator stated explicitly (`lineterminator='\n'`). When a full rewrite is
  unavoidable, diff before staging.
- Same family as "`git add -A` after a generator sweeps its side effects into
  your commit", one level lower: there the extra changes come from another tool,
  here from the writer you called yourself.

### One fact derived twice, never reconciled

- The bug shape is a **count taken from one artifact and the things counted
  produced from another**, with a guard comparing the two. It fires on healthy
  input, aborts a run in which nothing was wrong, and — because the guard looks
  like diligence — the fix goes onto the *inputs* rather than the comparison. So
  it comes back.
- Measured 2026-08-30 in stac_dem_bc, three times in one change before anyone
  looked at the mechanism:
  1. a lookup asked about 600 ids and was compared against a page of 10;
  2. a caller-supplied list with a duplicate counted twice and fetched once;
  3. one id resolving to two hrefs counted once and fetched twice.
  Fixes 1 and 2 deduped the inputs (`sort -u`, a set) and left the comparison
  untouched. Of nine counts in that pipeline, **eight were structural** — count
  and counted shared a producer — and every bug landed on the one pair that did
  not.
- **The fix is to derive the expectation from the artifact the consumer actually
  consumes**, so the two cannot drift:
  ```bash
  cut -f2 hrefs.tsv | sort -u > urls.txt     # what the fetch loop iterates
  N_URLS=$(count_lines urls.txt)             # ...so count THAT, not the id list
  [ "$N_FETCHED" -eq "$N_URLS" ] || exit 1
  ```
- Review question that finds it, and it is not "are there more instances":
  **for each guard, name the producer of each side. If they differ, the guard can
  fire on good input.** Ask it once per comparison; it is a five-minute audit and
  it terminates, where hunting instances does not.

### A paginated API's default page size silently truncates a lookup used as a check

- Asking an API about N things and getting its **default page** back is not an
  error and does not look like one. The response is well-formed, the status is
  200, and the missing items read as *absent from the server* rather than as
  *not requested*. A verification built on it reports the subject as broken while
  the subject is fine.
- Measured 2026-08-30 against a pgstac/stac-fastapi API: `POST /search` with 600
  ids and no `limit` returned **10** features; with `limit: 600`, all 600. The
  verifier that shipped therefore failed on every run of more than ten items —
  after the write it was verifying had already succeeded.
- It survived review because the only exercise was **three** items, and 3 < 10.
  A fixture smaller than the default page cannot reach the failure (see "A
  fixture set that cannot reach the failure mode is not validation").
- Rules: **set the page size explicitly on every request you treat as evidence**,
  and assert it in a unit test at a size *larger than any plausible default*.
  Test the body you build, not the response you mock — a transport mock never
  constructs the request.
- Related and worth checking in the same pass: whether the API omits unmatched
  keys silently. If it does, a returned **count** proves nothing and only set
  equality does.

### Counting lines: `wc -l` and `grep -c` fail in opposite directions

- Refines the count guard prescribed above under "Parallel writers sharing one
  output file". `wc -l` counts **newlines**, so a final line with no trailing
  newline is not counted — a caller-supplied list is then short by one and the
  guard aborts a good run.
- The obvious replacement is worse. `grep -c ''` counts that line, and **exits 1
  on an empty file** — so under `set -e` it kills the script on the empty case,
  which is usually the routine one ("nothing to do"). Verified: the statement
  after the assignment never executed.
- `grep -c` also counts **matching lines, not occurrences**. Counting records in
  a compact single-line JSON with `grep -c` returns 1 for a file holding 102,460
  of them — not off by a bit, structurally meaningless.
- Safe helper, checked against all four inputs (empty, unterminated, terminated,
  missing) rather than reasoned about:
  ```bash
  count_lines() {
    local n
    n=$(grep -c '' "$1" 2>/dev/null) || n="${n:-0}"
    printf '%s' "${n:-0}"
  }
  ```
- For records inside a structured file, do not count with a line tool at all —
  parse it.
- The dangerous variant is a count that looks **right**. The `grep -c`-on-JSON
  case above returns 1 for 102,460 records — wrong enough to notice. A CSV whose
  free-text fields carry embedded newlines gives `wc -l` a number a few percent
  high, which survives eyeball review and gets quoted downstream as a record
  count. Observed 2026-07-30: `mdb-export` of an Access table reported 556 lines
  for 517 records (comment fields held the extra newlines), and the inflated
  number reached a provenance table in a README before the parsed count
  contradicted it. If a line count is only a did-this-produce-anything smoke
  test, label it `lines` and let whatever parses the file report the records.

### `local_mocked_bindings(.env = )` is the cleanup environment, not the target

`.package` names the package to mock in; `.env` says what the mock **unwinds with**.
Passing a namespace to `.env` installs the stub correctly and then never removes it,
because a namespace does not exit — so every later test in the run keeps it.

```r
# WRONG: installs correctly, never unwinds. Every later test sees the stub.
local_mocked_bindings(f = stub, .env = asNamespace("pkg"))

# Right: mocks in the package, unwinds with the calling test.
local_mocked_bindings(f = stub, .package = "pkg", .env = parent.frame())
```

It leaks in the direction that reads as **success**: a stub returning `TRUE` makes
assertions pass, so the suite goes green and stays green. Nothing points at the mock.

Bites hardest when the mock lives in a **test helper** rather than in a `test_that()`
block — the helper's own frame exits before the assertions, so `.env` gets reached for,
and the namespace looks like the obvious answer.

Caught 2026-08-30 in fly#38, and only because a later test in the same file asserted a
file existed that the stub had never written. The tell was a *contradiction*:
`expect_true(f(...))` passing while `expect_true(file.exists(out))` failed. If you see a
function report success without its side effect, suspect a live mock before suspecting
the function. Confirm by printing something only the real implementation can produce.

Companion to the restore-the-bug entry above — same family, opposite direction. There
the mock fails to take; here it never lets go.

### Check a threshold against the least favourable case, computed — not a remembered example

A tolerance, timeout, or size limit is only correct relative to the **binding** member of
the population it governs. Reaching for the vivid example instead is how it gets set
wrong, and the test written to guard it inherits the same mistake, so nothing fires.

The tell: the guard's test asserts against the case that is easiest to picture — the
biggest, the most extreme, the one from the bug report. Any threshold clears that one.
Ask which member is **closest to the line**, and compute it over the whole set:

```r
# Wrong: the most eccentric camera, which any tolerance clears
expect_gt(abs(log(1654 / 1063)), tol)              # 0.442

# Right: every shipped row, so none may slip
aspect <- read.csv(system.file("extdata/table.csv", package = "pkg"))$aspect
expect_true(all(abs(log(aspect)) > tol))           # binding case is 0.095
```

Measured 2026-08-30 in fly#38: a stretch tolerance was set to 1.10 against a remembered
0.442, while the binding case was 0.0949 and `log(1.10)` is 0.0953 — **0.4% too loose**,
and it let through exactly the input the tolerance had been widened to catch. One row of
nineteen. Both the threshold and its test were written by someone who had just measured
the right numbers and reached for the wrong one.

State the admissible band, both ends, wherever the threshold is defined. If the band is
narrow, say so — that is a property of the problem worth knowing, not a detail.

### A `case` allowlist matches a substring, not a token

`case " $allowed " in *" $item "*)` reads like set membership and is not: it matches any
contiguous run of the list, so an item whose name spans two entries passes.

```bash
allowed="404 authors index LICENSE"
b="authors index"                       # passes; it is a substring of the list
case " $allowed " in *" $b "*) echo "allowed" ;; esac
```

Fails toward **pass**, and the padding-with-spaces idiom is what makes it look rigorous.
Use an explicit loop:

```bash
is_allowed() { for a in $allowed; do [ "$a" = "$1" ] && return 0; done; return 1; }
```

Same class as the exact-vs-substring rule for snapshot names in `code-check-infra.md`,
generalised: **whenever a guard decides membership, check that a value spanning two
legitimate entries is refused.** Reachability is often low — `R CMD check` rejects a
filename containing a space, for instance — but a guard is only worth its maintenance if
it is trusted, and one that reads stronger than it is will be.

While you are there: strip only the suffix that actually matched. `b="${b%.html}";
b="${b%.md}"` applied unconditionally reduces `index.md.html` to `index`.

Caught 2026-08-31 in fly#42, in the second draft of a guard whose first draft had already
failed the empty-result check above. Two rounds, both invisible by reading, both found by
running the shipped script against inputs built to break it rather than against the one
case it was written for.

### A guard placed mid-operation can be defeated by the operation itself

A precondition check is usually written imagining a clean starting state, then
placed wherever it is convenient to run. If the operation *mutates the thing the
guard inspects*, the guard passes at the start and fails ever after — on every
run, for a reason that has nothing to do with what it was guarding against.

The tell is a guard that fires the first time it meets real work and never
passes again. It reads as "the check found something", which is why it survives
review: a guard that fires looks like a guard that works.

- Measured 2026-08-31 in link: a cross-host parity check refused to proceed
  because both hosts' git trees were dirty. They were dirty *because the run
  writes its own logs into a tracked directory*, and because the snapshot step
  stamps a ledger CSV on each worker. Every real run dirtied itself before
  reaching the check.
- The same check placed **before** the run was correct and useful. Only the
  second placement was wrong, so this is not "drop the check" — it is "a guard
  has a valid window, and the window is part of the guard".

Ask, for any precondition: **does anything between the start of the operation
and this line write to what I am about to inspect?** Logs, caches, lockfiles,
generated config, and ledger/stamp files are the usual culprits, and tracked
log directories are the one people forget because logging feels inert.

Unit tests will not catch it. The fixture supplies a clean state directly, so
it never crosses the code that dirties it — the fixture and the guard agree
about a world the operation has already left. This is the fixture-cannot-reach-
the-failure-mode rule above, arriving through placement rather than data.


### A job that writes into its own tracked output directory poisons every dirty-check

The rule above covers a *guard* defeated by its own operation. The same mechanism
has a second victim that is quieter and worse: a **provenance field** that records
whether the tree was dirty.

A run that writes logs, caches, or reports into a tracked directory is dirty from
its own first write onward. Anything reading `git status` after that gets the
wrong answer, and there are usually two such readers with different consequences:

| reader | consequence | how it surfaces |
|---|---|---|
| a pre-flight gate | refuses to start | loudly, on the next run |
| a provenance stamp written into the output | records "built from a modified tree" | **never** |

The second inverts the field's entire purpose. A `dirty` flag exists to say *this
SHA cannot be trusted*. Set unconditionally, it carries no information — and
readers learn to ignore the column, at which point a genuinely dirty run is
indistinguishable from a clean one.

Measured 2026-08-31 in link, after a fully successful 34-unit run:

```
    host     | n_units | n_dirty
-------------+---------+---------
 cypher-job1 |       9 |       0
 cypher-job2 |       6 |       0
 dispatcher  |      21 |      21     <- every row, and every one false

$ git status --porcelain | wc -l
15                                    # all of them the run's own logs
$ git status --porcelain --untracked-files=no
                                      # empty: zero tracked modifications
```

Only the dispatcher was affected, because the workers reset to origin and shipped
their logs back over the wire rather than writing into their own checkout. So the
defect is invisible on exactly the hosts that are easiest to test, and it survived
four pilot runs.

**Match the predicate to the subject.** Both readers above actually want *does
tracked code differ from what will be deployed*, which untracked outputs cannot
affect:

```bash
git status --porcelain --untracked-files=no -- . ':(exclude)path/to/logs'
```

- **`:(exclude)` long form, never `:!`** — `:!path` keeps parsing magic after the
  `!`, aborts, and an aborted `git status` returns empty, which reads as *clean*.
  Fail-toward-skip on the guard whose job is to stop the run.
- **Decide `--untracked-files=no` deliberately.** It also hides a genuinely new
  uncommitted source file, which *is* invisible to the deploy target and may be
  the thing you wanted caught. Excluding only the output directory keeps that.

**Fixtures cannot reach this.** A test supplies a clean tree directly and never
crosses the code that dirties it. The only thing that finds it is verifying a
*completed real run* against the record it wrote — which is the general lesson:
when a job writes provenance about itself, read that provenance back and check it
against independently-measured ground truth, because the job is the one witness
that cannot contradict itself.

### A search that finds nothing has proven nothing until it has found something

The positive-control rule above catches a probe reporting a **defect** that isn't
there. This is the mirror, and it is worse, because its output is *reassuring*:
a search that cannot match returns empty, empty reads as clean, and a clean
result ends the investigation instead of prompting one.

It is how an audit gets reported as passed without ever having run.

**The common cause is a regex feature the local tool does not have.** BSD tools
(macOS default) and GNU tools disagree, and the disagreement is silent — an
unsupported escape is treated as a literal, matches nothing, and exits 1 like an
honest no-match:

```bash
# macOS: \b is not reliably supported. Matches nothing. Exit 1. Looks clean.
git grep -InE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' -- .

# Same tree, working pattern: 33 distinct addresses across 101 files.
git grep -ohE '([0-9]{1,3}\.){3}[0-9]{1,3}' -- . | sort -u
```

Measured 2026-08-31 in link. The first form was run as a repo audit for exposed
host addresses in a public repo, returned empty, and the result was written into
an issue as *"no IPs in any tracked file"* — an affirmative finding, from a
command that could not have found one. This is the same shape as the
empty-result-set rule near the top of this file, arriving through a regex dialect
rather than through a loop.

**Before trusting an empty search, make it match something.** One line, and it
converts "I found nothing" into "I looked, and here is proof I could see":

```bash
git grep -c 'PATTERN' -- <a file you KNOW contains it>   # must be non-zero
```

If you cannot name a file that should match, construct one in `/tmp` and search
that. A search whose ability to match has never been demonstrated is not
evidence, and reporting it as an audit result is worse than not auditing —
someone will rely on it.

Two habits that make this cheap:

- **Prefer POSIX ERE and explicit character classes over shorthand escapes.**
  `[^0-9]` and `(^|[^0-9])` travel; `\b`, `\d`, `\s`, `\+` and `\|` do not.
- **Reconcile the count against expectation.** "Zero occurrences of an IP address
  in a repo full of orchestration logs" should read as implausible on its face.
  When a result is surprisingly clean, suspect the instrument before the world —
  the same prior the broken-probe rule applies to surprising *failures*.

### A guard nothing corroborates has to count, not match

The "empty result set is not a pass" rule above says a scan finding nothing must
not read as a scan finding nothing wrong. How much that costs depends on what sits
*downstream*: where a second, independent check would disagree later, a missed scan
is survivable. Where the guard is the only opinion, a miss is silent and permanent.

So ask what would notice if the guard matched nothing, and when the answer is
"nothing would", make it **report how much it checked** and compare that against
how much the caller went on to use. `all(grepl(ok, v))` is `TRUE` for
`v = character(0)`; `length(v) < n_consumed` is not.

```r
checked <- scan_the_file(path)          # returns what it saw, not a verdict
if (length(checked) < sum(!is.na(parsed$time))) {
  abort("values were used without being checked")
}
```

Measured 2026-09-01 in trap#18. The Mergin track reader carries `clock_delta`
columns that would disagree if a bad timestamp got through; the GPX reader cannot
— a GPX `<trk>` has no second clock — so its UTC-offset refusal is the only line
of defence. It is written as a count, and that was not theoretical: the xpath it
used needed `xml2::xml_ns_strip()` to see a default-namespaced document at all, and
without that line it found **0 of 600**. The count turned every test in the file
red. A `grepl()` over the empty set would have gone green.

**Then check the direction the count does not cover: too little scanned aborts,
too much scanned aborts for the wrong reason.** The same guard first scanned the
whole file rather than the elements it protects, and refused a real file over a
stray `<trk><time>2024/08/22 09:07:35+00</time>` that `sf` had written and nothing
would ever parse. The abort was correct in outcome and wrong in message: it
reported an ambiguous timezone and buried the actual defect, which was that the
file had no per-point clock at all. Scope a scan to what is actually consumed —
a wider one is not a stricter guard, it is a guard that misdiagnoses.


### A paged API's default `limit` reads as absence

Asking a paged endpoint for "everything" and searching the response finds only
what fits on the first page. The items past it are reported **missing**, which is
a stronger and more actionable claim than "I did not look far enough" — and it
does not error, so nothing distinguishes the two.

Measured 2026-08-31 against a STAC catalogue: a `limit=200` search reported two of
sixteen objects absent from the collection. Paging the whole thing — follow the
`rel="next"` link until it stops — returned 230 items with **every one present**.
Had that finding shipped it would have read as "those surveys were never
catalogued" and sent someone looking for imagery that already existed.

Adjacent to *"Prove absence before acting on it"* above, and worth separating: the
remedy there is a wider query as a control, which does nothing here because the
query was already wide enough. The defect is in the **transport**, not the filter.

- Follow pagination to exhaustion, or ask the API for its own count and assert you
  retrieved it. `numberMatched` is the STAC field; most paged APIs have one, and a
  `None` there is itself a signal that you must page.
- **A negative result from a paged source is not a finding until you have paged
  it.** The positive results are fine — anything you found, you found.
- Same shape for `gh` (`--limit` defaults to 30), `aws s3api list-objects-v2`
  (1000 keys, `NextContinuationToken`), and any `?page=` REST endpoint.

### A structural property is not a performance measurement

Reading a number out of a format — block size, chunk size, page size, record
length — and inferring a *cost* from it skips the layer that usually decides the
cost. Caches, buffers and read-ahead sit between the structure and the wire, and
they are the whole reason the structure is tunable in the first place.

Measured 2026-08-31: a GDAL STACIT source reports 128x128 blocks against the same
COG's native 512x512, and that was written into an issue as "roughly 16x the range
requests", as an argument against adopting it. Counting the actual requests with
`CPL_CURL_VERBOSE` gave **14 against 14**, with bytes fetched within 16 KB and
identical pixels. GDAL's block cache absorbs the difference entirely.

The tell is a ratio derived by arithmetic on two numbers neither of which is a
count of the thing being claimed. It reads as quantitative — it has a factor and
a unit — which is exactly what makes it survive review.

- Count the operation you are claiming: requests, queries, allocations, bytes.
  Most stacks will tell you (`CPL_CURL_VERBOSE`, a query log, `strace -c`).
- Sibling of *"A proxy assertion does not guard the thing it stands for"* above,
  pointed the other way: that one is a **test** asserting a proxy, this is a
  **claim** asserting one. The test fails silently; the claim gets acted on.
- It cost nothing here only because the user pushed back on a number that looked
  unmotivated. Do not rely on that.

### psql does not interpolate `:'var'` inside a dollar-quoted string, and `\quit N` exits 0

Two traps in the same file type, both of which read perfectly and fail at run time.

**Interpolation.** psql substitutes its `-v` variables in the query buffer, but a
dollar-quoted body is a *string literal* to it, so nothing inside `$$ … $$` is
substituted. The natural form dies with a message that points at SQL syntax rather
than at the quoting layer:

```sql
DO $$ DECLARE v text := :'run_uid'; BEGIN ... END $$;
-- ERROR:  syntax error at or near ":"
```

Pass parameters through session settings instead, set outside the block:

```sql
SELECT set_config('app.run_uid', :'run_uid', false) \gset
DO $$ DECLARE v text := current_setting('app.run_uid'); BEGIN ... END $$;
```

**`\quit` takes no exit code.** `\quit 1` warns `extra argument "1" ignored` and
exits **0** (measured, psql 16.10 and 18.3). So a guard written as

```
\echo 'FATAL: …'
\quit 1
```

prints FATAL in red and then reports **success** — fail-toward-pass on precisely the
branch that exists to stop a silent zero-row pass. Raise instead, with
`\set ON_ERROR_STOP on` at the top of the file:

```sql
DO $$ BEGIN RAISE EXCEPTION 'no run_uid supplied'; END $$;
```

Related, same family: a `.sql` file whose checks are all bare `SELECT`s has no exit
status at all — a human reading output is the only verdict. If the script is invoked
by anything, at least one check must `RAISE`.

Caught 2026-09-01 in link#262, in a verify script whose own header advertised that it
"exits non-zero on a real failure".

### A second `trap … EXIT` replaces the first

`trap` registers **one** handler per signal. Registering cleanup for a temp file and
then cleanup for a database schema leaves only the second — the first is silently
discarded, and nothing warns.

```bash
trap 'rm -f "$TMP"' EXIT
trap 'drop_schema' EXIT        # the rm never runs again
```

One handler, both jobs:

```bash
cleanup() { rm -f "$TMP"; [ "$MADE" = 1 ] && drop_schema; }
trap cleanup EXIT
```

**Arm it before the thing it cleans up exists**, guarded by a flag. Registering the
trap *after* the resource is created leaves a window in which `set -euo pipefail` can
exit with no handler installed — and that window is exactly where a failure lands.

The two halves interact, which is how this survives review: adding `ON_ERROR_STOP` to
a psql call can turn a previously exit-0 setup step into an abort *inside* that
window, reopening a leak the early trap was added to close. Both changes individually
right; neither measured against the other. Caught 2026-09-01 in link#262.

### An ordered dispatch makes severity ordering load-bearing, and nothing enforces it

A `CASE`, an `if/elif` chain, or any first-match dispatch that reports a *verdict*
carries an unwritten invariant: every serious arm precedes every advisory one. Adding
an arm is the natural edit; ranking it correctly is a judgement — so the invariant
breaks quietly, and the symptom is a real failure that is never printed.

It recurs one axis over, which is the tell that the class is wrong rather than the
instance. Measured across three rounds on one file (link#262):

| round | edit | result |
|---|---|---|
| 1 | added a NOTE arm under a FAIL | shadowed the FAIL two lines below it |
| 2 | partitioned FAILs above NOTEs, wrote the invariant in a comment | correct, briefly |
| 3 | added a *conditionally* sanctioned state into a FAIL slot | shadowed the same arm again |

The invariant was never "FAILs before NOTEs" but "every arm above the line is
**unconditionally** a failure" — which no comment reliably enforces.

**Accumulate instead of dispatching.** Report every condition that holds:

```sql
coalesce(nullif(concat_ws('; ',
  CASE WHEN <a> THEN 'FAIL: …' END,
  CASE WHEN <b> THEN 'FAIL: …' END,
  CASE WHEN <c> THEN 'NOTE: …' END), ''), 'OK')
```

`concat_ws` skips NULLs, so arm order changes only the order of the joined tokens.

Two checks worth making once you have one:

- **Enumerate how the accumulator itself could drop an arm** — a false condition, a
  NULL-valued condition, an empty-string arm, a NULL separator, a nested `CASE` with
  no `ELSE`. That set is small and finite, which is what makes "this class is closed"
  a measurement rather than a claim.
- **No arm labelled FAIL may exit 0.** Sweep every single-fault state and check the
  label against the exit status; a reported-but-unenforced FAIL trains people to
  ignore the word. Where a condition is deliberately advisory, label it NOTE.

### When a system both records and renders, the rendered copy drifts into fiction

A pipeline that writes a durable record (a log table, a manifest) often also
renders a human-readable summary beside its output — a `.stamp.md`, a README, a
report header. Consumers reach for the **rendered** one, because it is a file
sitting next to the artifact rather than a query against a database they may not
have. So that is the copy that gets published, and the copy nobody checks.

Measured 2026-09-01 across `link` and `floodplains`. Same runs, two artifacts:

```
fresh.log            UTRE 1.04 min   UTRE 1.67 min   FRAN 3.33 min   UFRA 4.12 min
aquatic_network.stamp.md   "Started: 22:42:31  Ended: 22:42:31 (0.0s elapsed)"
```

The sidecar was constructed by calling the open and the close on **one line**, so
the interval it reports is the cost of building the stamp object — not the work.
A 0.0s network build for a 4,877-segment watershed group is not plausible, and
the file states it as fact. It was a candidate field for publication into a STAC
catalogue, where a consumer would have had no way to tell a wrong duration from a
right one.

Two rules, and the second is the one that saves the time:

- **Prefer the record over the rendering** when both exist. The record is written
  by the code doing the work, at the moment it does it; the rendering is assembled
  afterwards by code that has to be *told* what happened. Only one of those can be
  wrong about its own subject.
- **A duration whose start and end are set in the same expression is not a
  measurement.** Grep for it: `finish(start(...))`, `stamp <- close(open(x))`, any
  construction where the two calls cannot have work between them. It reads as
  bookkeeping and produces a number with a unit.

The wider tell: **a rendered artifact that nothing consumes programmatically has
nothing keeping it honest.** Tests assert on the record; the sidecar is prose.
When a downstream repo then starts publishing the sidecar, it inherits every
drift that accumulated while nobody was reading it — which is exactly when it
becomes load-bearing.

Same family as *"Measure the output, not the input you handed in"* above, one
level out: there the probe reads back its own input, here the artifact reports a
quantity it never observed.

### A serializer's default for "no value" is rarely a null, and every wrong answer is silent

Publishing an explicit null — "we looked and there was not one", as distinct from "not
implemented" — depends on the serializer actually emitting one. Library defaults usually
do not, and each wrong answer is a *valid* value that passes every downstream schema
check.

Three measured in one afternoon (stac_floodplains_bc#17), two of them live in the first
draft:

| producer | default behaviour | fix |
|---|---|---|
| `jsonlite::toJSON` / `write_json` | `NA_real_` serialises as the **string** `"NA"` | `na = "null"` |
| `jsonlite::toJSON` / `write_json` | an R `NULL` serialises as `{}` | `null = "null"` |
| GDAL metadata | no null exists; `str(None)` writes the literal `'None'` | see below |

The `{}` one is the nastiest: it survives a JSON round trip, and on the Python side it
passes `is not None`, so a consumer's own guard waves it through. `NA` (logical) and
`NA_character_` happen to emit `null` under the defaults while `NA_real_` does not — so
a probe that tests only one NA type reports the library as fine.

Two habits:

- **Set both arguments and say why at the call site.** They are independent: `na` governs
  `NA`, `null` governs `NULL`, and the two failure modes are different. Check they are
  byte-inert on the existing fields, which makes the change safe as well as necessary.
- **Never build the record with `[[<-` or `modifyList`.** Both **drop** a `NULL` member,
  turning an intended null into an absent key — the one outcome "publish the null"
  exists to prevent. `list(...)` and `c()` keep it.

For a string-only metadata store (GDAL tags, EXIF, HTTP headers) there is no null at all,
so pick the encoding by measuring what the store does with each candidate rather than by
choosing the one that reads best. Measured for GDAL: the **empty string** is treated as
absence on write *and* deletes an existing key, which makes it both the encoding and the
clearing mechanism — the latter mattering because `update_tags()` merges rather than
replaces, so a stale tag otherwise survives a rewrite. `'None'`, `'NA'` and `'null'` all
round-trip as ordinary strings a consumer cannot tell from a real value.

**And check what the key namespace does to your names.** A colon in a GDAL tag key is a
namespace separator: `update_tags(**{"NGE:LINK_RUN_UID": "abc"})` round-trips as key
`NGE` with value `LINK_RUN_UID=abc`. Eleven prefixed fields collapse into one tag holding
whichever was written last — uniform, silent, on every file.

**And the reader may drop the null you did publish.** Getting a real `null` onto the wire is
only half of it: the *serving* layer can omit null-valued keys on output while the store keeps
them. Measured 2026-09-02 on `images.a11s.one` (stac_floodplains_bc#36): on the pgstac row all 11
`nge:` properties are present with `jsonb_typeof` `null`; from `GET /collections/.../items/<id>`
they are absent, while every non-null value and every asset field round-trips byte-for-byte. So
an API consumer cannot distinguish "published null" from "never published" — the whole reason
for publishing the null — and a verify that compares the served document with the built one
reports every null as a defect. Two consequences: a null-means-something contract has to be
checked against the **store**, not the API, or it has to carry a non-null sentinel; and a
read-back guard needs a stated rule for the build-null / served-absent pair, measured against
the real reader rather than reasoned about. Found only because the first single-item release
ran a wholesale document compare and printed exactly the eleven keys.

### A rename emits two signals, and reading only one cannot distinguish it from absence

When code reads a document produced by something else — an upstream JSON contract, a
config, an API response — a renamed or removed key produces **two** observable facts: an
expected key is missing, and an unrecognised sibling is present. The first is ambiguous
with a legitimate absence. The second never is.

Guards are almost always written against the first, because that is the one the reading
code naturally trips over. So an upstream rename degrades to whatever "absent" means —
usually a published null or a default — and stays invisible for as long as nobody
compares the output against the producer's own file.

**The ambiguity is not uniform: it depends on whether the key has a parent whose presence
is itself evidence.** At depth ≥ 2 a missing leaf inside a *present* section is already
unambiguous, because the section being there proves the producer wrote this block. At the
document root, and anywhere the key space is open, there is no such witness.

That is what makes this recur rather than resolve. Fixing the leaf leaves the section;
fixing the section leaves the root. Measured 2026-09-01 in stac_floodplains_bc#17 — three
review rounds, the same defect at three depths, each found inside the previous round's
fix:

| depth | what was renamed | before | after |
|---|---|---|---|
| leaf | `link_log` key absent/renamed | 3 fields published null | stop |
| section | `inputs` → `inputs_v2` | 4 fields published null | stop |
| root | `floodplain` → `floodplain_v2` | 1 field published null | stop |

Two closures, and they are not interchangeable:

- **Where the key set is closed, reject unknown keys.** One `setdiff(names(got), known)`
  at the document root closes that whole axis, and it is the only guard that reads the
  second signal.
- **Where the keys are DATA, pin their shape instead.** A map keyed by scenario id cannot
  use unknown-key rejection — any string is a possible key — so assert the documented
  form (`^[a-z]{2}_ff[0-9]{2}$`). Re-keying `ch_ff04` to `ff04` otherwise nulls every
  field on every item at once, which is precisely the uniform loss a cross-item check
  cannot see.

**Version pins do not substitute.** A `schema_version` field fires only when the producer
*bumps* it, and a rename shipped without a bump is the realistic case for anything still
in flight.

**One direction is worse than a null and belongs in the same sweep.** A scalar check
written as `length(x) != 1` is a proxy that a single-key object satisfies: a leaf becoming
`{"algorithm": "sha256"}` published `"sha256"` as the value. Every other failure here
produces an absence a reader can see; this one produces something that looks like a real
answer and is counted as present. Reject a list outright rather than testing its length.

### Making an optional field mandatory breaks every producer that legitimately left it empty

The rule above is about a *bypass* whose stated reason expires. This is the mirror,
and it reaches further: tightening an assertion on a field — NULL becomes a failure,
a warning becomes an error, a tolerance is removed — is a change to every path that
**writes** that field, and those paths are usually not in the diff.

The tell is a one-line change to a check accompanied by no change to a producer. Ask
directly: *what are all the ways this field gets populated, and does each one still
satisfy the new rule?* Enumerate them by grep, not by memory — the one that bites is
always the path nobody thinks of as a producer, because it is an install script, a
migration, a manual runbook step, or a fallback branch.

Measured 2026-09-01 in link#264. A resolver was fixed so a package's commit SHA
became recordable, and the verifier was tightened to require it on every host. Four
producers existed. Three were fine. The fourth was `scripts/update_hosts.sh`, which
installs with `R CMD INSTALL` of a source tarball — deliberately, to route around
r-lib/pak#658 — and that writes **no `Remote*` fields at all**. So the repo's own
maintenance script silently produced hosts that the new assertion would reject, and
the rejection landed *after* cloud instances had been paid for, because the check ran
post-provision. Found by review, not by any test: every test passed, because the
tests exercised the resolver rather than the install paths feeding it.

Three habits, and the second is the one that keeps being skipped:

- **Grep for the producers before tightening the consumer.** Anything that writes the
  field, sets the env var it reads, or installs the artifact it describes.
- **Move the check as early as the fact is knowable.** A gate that fires after spend
  is a report, not a gate. The same assertion five seconds in costs nothing and the
  failure becomes free.
- **Say what happens to existing records.** Historical rows written under the old rule
  will now fail, and that is usually correct — but it has to be stated, or the first
  person to run the check against last month's data reports it as a regression.

Related and distinct: *"A fix to code that writes data is not done until the written
data is reconciled"* covers the records already on disk. This one covers the *writers*
still running.

### Teaching a build or install step to record provenance is a change to a safety-critical path

The remedy above — make the producer record what it produced — is correct and is
where the next three defects come from. Provenance a build step writes is trusted
absolutely by everything downstream, so a wrong value there is worse than the missing
value it replaced: absence fails loudly, and a confident wrong SHA satisfies every
guard built to catch exactly it.

Three failures, all measured 2026-09-01 in the same ~40-line change, each individually
invisible:

- **The record outlived the thing recorded.** `R CMD INSTALL ... | tail -3` reports
  *tail's* status, and `set -e` does not cross a pipeline, so a failed install exited
  0 and the pin was written for a build that never happened. Quieter still when an
  older version is present: the version probe succeeds and nothing looks wrong.
  Gate the write on the build's own exit status — tempfile plus an explicit check —
  so the record is unreachable unless the work returned 0.
- **The pin was applied to something that had its own identity.** Writing an env
  override for a package that is run from a checkout beat the checkout's git state,
  which would have pinned a dirty-tree flag to a permanent `false`. A flag stuck
  always-TRUE gets noticed and filed; **stuck always-FALSE is the direction nobody
  can notice.** Pin only what has no other identity available.
- **Nothing expires it.** An env pin written once wins forever, so a later install by
  another route leaves the stale value winning — and the guard reading that variable
  is now reading the thing it is meant to be checking. Cross-check the pin against an
  independent source wherever one exists, and fail naming both values.

Also: resolve the identifier **once** for the whole operation, not per target. Six API
calls across a five-minute run put targets on different commits if someone pushes
mid-run, which is precisely the disagreement the provenance was added to detect.

The meta-lesson is worth more than any of the three. All of them arrived in the *fix*
for a defect found in review, and the following round found all five of its findings
inside that one fix. **Review the fixes at least as hard as the original**, and when a
fix expands scope into a new file, treat that file as unreviewed code rather than as
an extension of the change you already checked.

### A claim flagged as under-evidenced gets repaired by widening, and widening is what breaks

The two rules above are about a claim's scope when it is *written*. This is about what
happens to that scope when it is **repaired**, and it is the more expensive failure
because it recurs inside its own fix.

Told that a claim is not supported, the natural repair is to widen the stated
evidential base — "on every run", "from either layer", "across the figures here",
"which run from X to Y" — rather than to narrow the claim. Widening requires a
population. The population gets asserted, from recall of an adjacent document, and the
next round finds it does not hold.

**Tell: the fix adds a quantifier the previous version did not have.** For each one,
name the population, and say whether it is enumerable from the artifact in front of you.
If it is not, you have replaced an under-evidenced claim with an unfalsifiable one.

Measured 2026-09-01 in flooded#52 — a four-paragraph prose diff to a shipped reference
memo took **six review rounds, 36 findings, 14 of them bugs**. Every round's finding was
about a *number*; every round's fix was correct about the number and introduced a new
quantifier. Across rounds 4–6, **every widening broke or was under-justified; every
narrowing held** — including one round-5 fix that correctly narrowed a licence and, in
the same sentence, asserted a fresh absolute ("do not move with the fix at all") that
measurement then falsified.

Root cause is worth naming because it predicts where this happens: the artifact's
figures sat on a ragged dataset × resolution × lineage × clipped/raw grid that no
dataset filled, so "across the figures here" quantified over holes as much as cells. Any
document whose values come from several partial runs has this shape.

**Terminate it by enumeration, not by another round.** The candidate set is closed — it
is every quantifier in the passage — so sweep them mechanically and work each one.
What ended it here was reproducing the old behaviour exactly on current code (the defect
was a constant factor on one term, so setting that term to `4 × 3.5926` returned the
historical cell count to the digit) and measuring every row of the consumer's own table,
which turned an asserted population into a finite measured one.

Then state the residual precisely. "The channel-buffer half of this clause is vacuous,
because the consumer publishes no channel-buffer-derived row" is definitional and ends
the sweep. A residual you can only call unlikely means there is another instance.

### An in-place metadata write can break a format's layout contract, and nothing will say so

Some formats are ordinary containers plus a **layout promise**: the same bytes in the wrong
order are still valid, still readable, still hash-verifiable, and no longer do the one thing
the format exists for. A Cloud-Optimized GeoTIFF is the clear case — its whole advantage is
that a client reads a small header and then fetches only the tiles it needs, which depends on
the main IFD sitting at the *front*.

Writing metadata in place, after the file has been laid out, moves that header to the end.

**The tell is a flag whose name contains `IGNORE`, `FORCE` or `BREAK`.** Those are not warning
suppressors; they are the library telling you what it is about to do and asking you to sign for
it. `rasterio.open(path, "r+", IGNORE_COG_LAYOUT_BREAK="YES")` reads as boilerplate and means
*"yes, invalidate the optimization"*.

Measured 2026-09-01 in stac_floodplains_bc#33, across an entire published catalogue:

| asset | size | main IFD at | must fetch to read the header |
|---|---|---|---|
| classified raster | 602,582 B | 595,868 | **98.9%** |
| transition raster | 1,335,328 B | 1,330,104 | **99.6%** |

So the property was not degraded, it was gone — and the collection existed to be served by a
dynamic tiler that depends on exactly it.

**It survives because every other signal reads green.** The bytes are a valid GeoTIFF. The
published `file:checksum` verifies, because the hash was taken *after* the metadata write and
describes the broken layout faithfully. The files open correctly in a desktop GIS. Only the
layout is wrong, and nothing looks at layout unless something is written to.

Two habits:

- **Order the pipeline so the layout-aware writer goes last.** Tag the input, then convert —
  not convert, then tag. Verify the carry-through rather than assuming it: `terra::writeRaster(filetype = "COG")`
  was measured to preserve arbitrary GDAL tags, a 256-entry colour table and the band
  description, and to produce a valid COG, which is what made the reorder free.
- **Assert the property, not the parse.** `cog_validate()`, or the format's equivalent. A
  schema check cannot see it, and neither can a checksum.

**The fix has a satisfying confirmation, and it is worth looking for.** Afterwards, the
in-place open *fails*: GDAL refuses `r+` on a file that HAS cloud-optimized layout. The same
call succeeded before. So the refusal is a second signal, independent of the validator, and it
doubles as a tripwire if an upstream ever starts handing you already-optimized inputs.

**Corollary — inserting a new party into a path silently narrows every partial guard on it.**
In that same change, a tag-consistency check covered only the namespaced subset of tags. That
was adequate while the writer and the reader were the same library call. Moving the conversion
between them made *"the tags survive the conversion"* a claim nothing checked: had the
converter dropped the unguarded tags, checksums would still verify and the layout validator
would still pass. When you add a step to a pipeline, re-read what each existing guard covers
against the path it now spans — partial coverage that was fine becomes a hole without changing
a line of the guard.

### A check's detect step and its explain step must use the same predicate

A comparison guard usually has two halves: one decides *whether* something is wrong, the other
describes *what*. Written at different times, or loosened in one place for a legitimate reason,
they drift apart — and the failure mode is a guard that fires with nothing to report.

```python
if got != want:                                   # exact
    changed = [... for k in keys if not _same(got[k], want[k])]   # numeric-tolerant
    problems.append(f"{name}: disagree — {'; '.join(changed)}")   # -> "disagree — "
```

`'-738.20'` against a property of `-738.2` enters the block and produces an empty message. The
release fails, the log says nothing, and the reader concludes the guard is broken rather than
the tolerance being in the wrong place.

**Compute the differences first, then gate on them.** One predicate, used once:

```python
changed = [... for k in keys if not _same(got.get(k), want.get(k))]
if changed:
    problems.append(...)
```

Caught 2026-09-01 in stac_floodplains_bc#33, in a guard being *widened* that same hour — the
tolerant comparison was added deliberately, for the real reason that one side is `str(x)` from
Python and the other a JSON number, and it went into only one of the two places. Found by
running the guard against a restored defect, not by reading it: an empty-message failure looks
like a passing guard in a diff.

### A link to a repo-hosted artifact must be *tracked*, not merely present

When the published site **is** the repository — GitHub Pages serving `docs/`, or a
`raw.githubusercontent.com` URL — the question "does this file exist" is the wrong
predicate. The right one is "is it in the repository", because that is what a reader
gets. A file written by a script and never `git add`ed exists for exactly one person:
whoever last ran the script.

The failure is invisible from the inside. The build succeeds, the page renders, the
link opens locally, and it 404s for everybody else. It surfaces only on a fresh clone
or a real visit.

```r
in_git <- repo_path %in% system2("git", "ls-files", stdout = TRUE)
```

Three instances in one project, each with a different cause and the same symptom:

- an interactive map written by a manual script, never committed — the appendix
  linking it 404'd on the published site for months
- 32 generated popup pages whose build script was in no build chain
- photo URLs built from the wrong id column, pointing at directories that had been
  renamed upstream

Note this is the *inverse* of the deploy-predicate case above, where untracked
outputs are noise and `--untracked-files=no` is right. The distinction is whether the
repo is the input to a build or is itself the artifact being served. Both predicates
are correct for their own subject and wrong for the other.

**Corollary — the DOM is not the whole document.** Harvesting `href`/`src` with an
HTML parser misses anything a script tag reconstructs at runtime. A leaflet map
serialises its popups as JSON, so every link inside them is invisible to
`xml2::xml_find_all(doc, "//@href")`. A DOM-only pass over a report with 51 dead links
found 2. Scan the raw text as well, and be permissive about the shape: markup built by
`paste0('<a href =', x, '.html ', 'target="_blank">')` emits `href =…` with a space
and no quotes, which most href patterns skip. In PCRE, lookbehind must be fixed width,
so `(?<=href *= *)` will not compile — match the attribute name and strip it after.

Cheap enough to run on every build, and it belongs there rather than in a checklist: a
check that must be remembered has the same failure mode as the script that had to be
remembered.

### A guard's error message must not recommend a remedy that walks back through it

A guard refuses bad input and, if it is a good one, names the fix. That remedy is
**code the caller will run**, and nothing checks it. So it is the one part of a
guard that can reintroduce the exact defect the guard exists to stop — and it does
so with the guard's own authority behind it.

The shape: the guard tests some **property of the shape** of the input, and the
recommended remedy *coerces to that shape*. Coercion always succeeds, so the
second attempt passes. The caller did as they were told, the error is gone, and
the data is wrong.

Measured 2026-09-01 in fly#37, where `fly_footprint()` silently returned 100 rows
from 20 because `sf::st_coordinates()` yields one row per *vertex* for non-POINT
geometry. The guard refused non-POINT and suggested `sf::st_cast(x, "POINT")`:

```
following the guard's own advice on a POLYGON column
  rows 20 -> 100      guard on result: ACCEPT      duplicated id: 80
```

That is the original bug, reproduced by obeying the error written to prevent it.
On a mixed column the same advice instead moved each polygon to its first ring
vertex — 1,940 m — with the row count unchanged, so nothing looked wrong at all.

**Reordering the guard's clauses does not fix it.** Three review rounds were spent
there: ordering decides *which sentence* carries the advice, and every sentence
carried it. The fix is to make the recommendation conditional on the case where it
is safe, which means computing that rather than reasoning about which types
qualify.

**And compute it per item, not in aggregate.** The obvious condition is a total —
"the coordinate count already equals the feature count" — and a total is blind to
a redistribution that conserves it. One frame digitised twice plus one frame with
no location satisfies it exactly, and taking the offered cast then shifted every
frame's geometry one place against its attributes: **18 of 19 wrong by up to
20.4 km**, row count preserved, no duplicate ids, guard accepting. Prefer a
condition with a closure argument over one with a list of cases — here, excluding
empty features, since a non-empty feature contributes at least one coordinate, so
"no empties" plus "total equals the count" forces exactly one each.

Two checks, and the second is the one that was missing:

- **Run the remedy.** For every input a clause can receive, execute the advice it
  gives and assert the result is what the caller meant. A table of input against
  what-the-advice-does is the whole test.
- **Do not assert the guard's own predicate.** The natural assertion — the remedy
  keeps the row count — is the condition the guard already checks, so it validates
  the guard against itself and passes on the input that breaks it. Measured: the
  row-count assertion passed the case above; a displacement assertion against
  independent ground truth failed it at 20,374 m. Same family as *"a reference
  generated by feeding your artifact to the consumer is circular"*, one level in.

Generalises past geometry to any guard whose message names a fix: an encoding
coercion, a `--force` flag, a schema migration, "re-run with `--fix`". Ask what
the input looks like *after* the suggested fix, and whether the guard would still
object.


# NGE Feature Workflow

For non-trivial issue-driven work, follow this checklist. Each step exists for a reason — skipping leads to rework, broken builds, and avoidable bugs that we've hit repeatedly.

## The Sequence

1. **Start with `/planning-init <N>`** — given an issue number, enters plan mode for codebase exploration, presents a phase breakdown for user approval, then scaffolds branch + PWF baseline with the approved phases. One command replaces the manual issue → explore → plan → branch → scaffold dance.
2. **Write robust tests first** — failing tests that reproduce the issue or document the new behavior. Tests are the contract; they fail until the work makes them pass.
3. **Name with intent** — functions, parameters, internal helpers carry the naming style of the package they live in. Look at existing exports as the guide; consistency over cleverness. For files rather than functions — shell scripts and operational R scripts under `scripts/` or `data-raw/` — the standard is the `noun_verb-detail` pattern in `newgraph.md`, noun first.
4. **Examples that run** — every exported function gets a runnable `@examples` block. Pkgdown renders them; CI executes them. An example that doesn't run is documentation rot.
5. **Code-check before each commit** — `/code-check` on staged diff. Catches what tests miss: edge cases, hard-coded paths, unguarded variables, security issues.
6. **Atomic commits** — each commit bundles code change + checkbox flip in `task_plan.md`. The diff and the progress live in the same commit; `git log -- planning/` tells the full story.
7. **`/planning-archive` when complete** — moves PWF to `archive/YYYY-MM-issue-N-slug/`, creates a fresh `active/`. Then `/gh-pr-push` opens the PR; `/gh-pr-merge` handles the release bookkeeping.

## When to Skip

For one-line typo fixes, version-bump-only PRs, or trivial documentation edits, the full workflow is overhead. Use judgment. The threshold is roughly: **multi-step issue, multi-file change, or anything that requires scoping** → use the workflow.

## Skills That Slot In

- `/planning-init <N>` — start
- `/planning-update` — sync checkboxes mid-session
- `/code-check` — before every commit
- `/planning-archive` — when issue closes
- `/gh-pr-push` — open the PR
- `/gh-pr-merge` — merge with release bookkeeping

## Issue bodies get edited, not appended

When work changes what an issue should say, **edit the body**. Don't add a
comment that corrects it, and retitle when the scope moves.

**Why:** an issue is read as a spec by whoever picks it up. A body saying one
thing with a comment three screens down saying the opposite costs the reader the
reconciliation, every time.

**How to apply:** `gh issue view N --json body -q .body` into a file, revise,
`gh issue edit N --body-file`. Name what changed and why when the correction is
load-bearing — the goal is a body that reads correctly top to bottom, not an
erasure of history. Comments are for genuine commentary: a merge notice, a
cross-repo pointer, a question. Applies to PR bodies too. Commit messages are
immutable history and are never rewritten this way.

**The failure mode that keeps recurring: research findings feel like
commentary.** They are not — they are the spec. If a finding changes what
someone would *build*, it belongs in the body, with the durable version in
`research/` and the body linking to it.

**Bodies drift at the moment work finishes, not while it is in flight.** Four
instances in a single day of rfp work, all of the same shape — the code learned
something and the issue did not:

| drift | what a reader saw |
|---|---|
| premise disproved by measurement | an issue arguing for a fix that was no longer needed |
| a conclusion asserted in the body but never landed in code | body and tree contradicting each other |
| the shape of the work moved during exploration | a spec describing a design nobody built |
| a decision made and shipped, body still listing options A–D | "decision needed" on a decision a year old |

Vigilance does not catch this, because the drift happens exactly when attention
moves to the merge. `/gh-pr-merge` reconciles at that moment — see its step 3b.

## Why This Exists

We've hit snags repeatedly when half-doing this — branches that mix concerns, tests bolted on after, code-check skipped (and then a bug ships in the diff), examples that fail in pkgdown. Each step is small; the cumulative reliability gain is real. The convention is here so it becomes the default expectation, not a thing the user has to remind every session about.


# LLM Behavioral Guidelines

<!-- Source: https://github.com/forrestchang/andrej-karpathy-skills/main/CLAUDE.md -->
<!-- Last synced: 2026-02-06 -->
<!-- These principles are hardcoded locally. We do not curl at deploy time. -->
<!-- Periodically check the source for meaningful updates. -->

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 5. You Have No Clock Between Tool Calls

**Every duration claim comes from `date`, never from how much waiting felt like
it happened.**

Background `sleep` returns immediately from the agent's side, and the number of
times you have polled is not evidence of elapsed time. Two consecutive tool
calls can be 15 seconds apart by the clock while feeling like ten minutes of
waiting.

The failure is stating it out loud before checking. Observed 2026-08: a CI run
was reported to the user as "pending for over an hour — unusually long, probably
a stuck runner", after roughly eight background sleeps. One `date -u` showed the
run was **three minutes old** and entirely normal. The whole diagnosis — stuck
runner, duplicate triggers, something wrong with the workflow — rested on a
duration that had been invented.

**How to apply:** before saying *any* duration — "still running after N
minutes", "this has been X a while", "longer than usual" — run `date -u` and
subtract a real start time. `gh run list --json createdAt` gives it for CI. If a
claim about slowness would change what the user does next, it needs a measured
number or it does not get made.

The same rule covers process state. `ps` and task-status listings have both been
observed wrong; check the artifact (an output file's size, its mtime, the
service's own API) rather than the wrapper.

### The same blind spot picks the wrong waiting tool

Not having a clock also makes a **chain of background sleeps** feel like
waiting when it is not. Observed 2026-08 on the same session as the above:
roughly a dozen `sleep 570; check` background tasks were spawned to wait out a
55-minute test suite and then CI. Two consecutive foreground checks printed the
*same minute* — no wall time had passed between them, because the sleeps run
detached and the polling happened around them rather than after them. Every one
of those tasks was waste, and killing them produced a batch of eleven
exit-code-144 notifications that read like failures.

Pick the instrument by how many answers you need:

| you need | use |
|---|---|
| one notification when a condition becomes true | `Bash(run_in_background)` with an `until` loop that exits |
| one per state change, ending on its own | `Monitor` with a command that emits and then exits |
| a value you must have before the next step | a **foreground** call, so the blocking is explicit |

A repeated `sleep N; grep` is right in none of them. **Tell: if you are about to
spawn a second waiter for the same thing, the first one was the wrong shape.**

A `Monitor` filter must also match the failure states, not just the success
one — silence looks identical to "still running", so a watcher that greps only
for the happy path stays quiet through a crash.

### Don't edit files a long-running suite is still reading

`devtools::test()` and its equivalents load each test file **when they reach it**,
not at launch. A 30-minute run therefore reads whatever is on disk at that moment,
so edits made mid-run are half-applied and the result describes a tree that never
existed.

Cost two full Docker suites (~1 hour) on rfp#178, both reporting `FAIL 1`. The
failure was a test written *during* the run, executing against source from *before*
the fix that made it pass — nearly reported as a regression. **The tell is a moving
denominator:** 3490 passes, then 3496, then 3500, on "the same" tree.

Before a long run, commit. While it runs, do work that touches nothing it reads —
issue bodies, PR text, reading, planning. If an edit cannot wait, kill the run
rather than let it produce a result that has to be re-litigated. And when a long run
fails, get the `file:line` before forming any theory: a mid-flight edit and a real
regression look identical in a summary line.

## 6. Subagents Are Evidence, Not Dependencies

**Spawn on your own judgment. Don't block on one. Don't trust its status. Verify its claims in both directions.**

### Spawning is your call, not the user's

Deciding to spawn a subagent is an engineering judgment, the same kind as choosing
to write a test or run a grep. **Do not ask permission for it.**

The user is usually not positioned to answer. Knowing whether a fan-out beats a
sequential read requires knowing the shape of the work — which you have and they do
not, so the question forces them to guess at a technical call. Under **Always Away**
it is worse than useless: the work stalls until they wake up, for an answer that was
yours to make. *"I wouldn't be in the know enough to know when that is"*
(airvine, 2026-08-27) is the whole problem in one line.

This does not soften §1's asks — *"if uncertain, ask"* and *"if something is unclear,
stop and ask"*. Those are about **what the user wants**: intent, scope, an ambiguous
requirement, a tradeoff only they can weigh. This is about **how you carry it out**.
Ask about intent; decide about mechanism. A question starting "should I use…" is
almost always the second kind, and almost always yours to answer.

#### Standing authorization: the harness bars the Agent tool by default on Opus 5

Sessions on Opus 5 carry a hardcoded instruction from the CLI itself —
*"Do not call the AgentTool unless the user requested it"* — alongside the same
line for workflows and deep-research. It is not a setting anyone here
misconfigured, and it cannot be turned off locally: measured 2026-08-29 in
`claude` v2.1.251, the string is a literal in the bundle, emitted when the
session is on the `opus_5_prompt_bundle` and the server-side flag
`tengu_fennel_godwit` is off. That flag and the replacement text
(`tengu_heron_brook`) are both remote config; nothing in `~/.claude/settings.json`
reaches them.

The symptom is a skill quietly doing less than it says: `/code-check` reporting
*"the subagent rounds did not run — your session instruction bars the Agent
tool"*, which is the review the command exists to perform. It reads as a
configuration problem, so the fix gets looked for in the wrong place.

**The clause is conditional, so this convention is the request.** Invoking a
skill that mandates subagents — `/code-check`'s three rounds, the Plan review in
`planning.md` — **is** the user requesting them. Spawn them. This paragraph is a
standing user instruction, written for exactly that purpose (airvine,
2026-08-29), and CLAUDE.md project instructions override default behaviour by
their own terms.

It authorizes the mandated spawns and nothing wider: the bounds in this section
still hold — two or three concurrent, about five per task, no fan-out from a
child — and a workflow or deep-research run fanning out dozens of agents remains
a spending decision that needs an explicit ask.

**Spawn without asking when:**

- A skill or convention mandates it — `/code-check`'s review rounds, the Plan review
  in `planning.md`. That decision is already made; re-asking it is friction carrying
  no information.
- You want fresh eyes on your own work. The mechanism and the measurements behind it
  are in `code-check/SKILL.md`.
- A sweep over many files will **locate** what matters faster than reading serially.
  The sweep finds candidates; it does not replace the read — `planning.md` is
  explicit that agents sometimes report existing files as absent, so read directly
  whatever you are going to act on.
- Independent items can run concurrently and nothing downstream needs them ordered.

**Do it yourself when:**

- One grep answers it.
- The work depends on conversation context a subagent will not have.
- You would sit idle waiting — spawn and keep working, or do it inline.

**Bounds and defaults you enforce yourself, rather than converting into questions:**

- **Two or three concurrent is the working default, and about five per task** is
  where spend stops being incidental. Concurrency and cumulative total are different
  quantities — `/code-check`'s three rounds plus a Plan review plus an ad-hoc sweep
  never exceeds three at once while spending well past a handful. Bound both.
- Past that total, **say so in your next message.** An escape you grant yourself
  silently is not a bound; it has to land in front of the user, after the fact.
- **Do not let a subagent fan out again.** Intent does not enforce this — the child
  decides what it calls — so use the structure: the `Explore` and `Plan` types are
  defined without the `Agent` tool and *cannot* spawn. `general-purpose` can, so when
  you use it (as `/code-check` does), put "do not spawn subagents" in the prompt. The
  one case on record — a research agent that had spawned 5 children and deadlocked
  for **~3 hours** while still reporting as running (below) — never had a root cause
  established, which is exactly why this bound is structural rather than advisory.
- Unnamed, delivering by file — `planning.md` carries the mechanics.
- **Report after, not before.** Say what you spawned, and relay what it found (per
  `code-check/SKILL.md` — a subagent's report never reaches the user on its own). A
  user can object to a spawn that already happened; they cannot usefully approve one
  that has not.

**What is genuinely the user's call is budget, not mechanism.** A workflow or
deep-research run fanning out dozens of agents is a spending decision and needs an
explicit ask. Two or three reviewers is not — that is just doing the work.

Worth being concrete about the value, because the cost is the visible half and the
benefit is not: on 2026-08-27 two reviewers over one conventions draft returned
**20 findings**, caught **six** false factual claims in it, and killed a section that
would otherwise have shipped contradicting `code-check.md`. None of that review
happens if the spawn waits on a user who is away.

### Don't block

Spawn a background subagent, then keep working on the lowest-risk part of the
task — scaffolding, data files, tests. When findings arrive, treat them as a
review of landed work rather than a precondition for starting it.

If a result genuinely must precede the next step, run it synchronously
(`run_in_background: false`) so the blocking is explicit and visible.

Three observed cases where waiting would have been the expensive choice:

- A research agent spawned 5 children and deadlocked for **~3 hours**, still
  reporting as "running". The user caught it, not the agent.
- A `Plan` agent asked to review a `task_plan.md` *before the baseline commit*
  returned after the issue was implemented, reviewed, merged and tagged.
- The same pattern on a later issue: findings arrived after all four phases had
  shipped. Because the work had not waited, this cost nothing — three findings
  were still new and landed as follow-up commits.

That last one is the shape to aim for. Concurrent review is not a degraded
version of blocking review; it is often better, because the reviewer reads real
code instead of a plan.

### Don't trust status

**Never report an agent as "still running" without evidence.** Agent status and
`TaskList` have both been observed to be wrong — `TaskList` reported "No tasks
found" for an agent that was alive and later replied. Check the output file's
mtime before claiming progress, and say what you checked.

### Verify claims, in both directions

Subagent output is evidence, not verdict. Both failure modes are real:

- **Acting on a wrong finding.** One labelled BLOCKER — "`glue()` will choke on
  the literal braces in this fragment" — was disproved by a 30-second probe,
  because glue does not re-parse interpolated values. Acting on it would have
  meant rewriting a working generator.
- **Dismissing a late review wholesale.** In that same review 2 of 9 findings
  were real, including a dead link. In a later one, a finding that a
  `path|layername=` check would delete KML/GPX layers was correct, and was
  confirmed against 207 real datasources before the fix landed.

The rule that separates them: **cheap probe first, then act.** Reproduce the
claim before you fix it, and before you dismiss it. A finding you cannot
reproduce is a finding you do not yet understand.


## 7. Evidence, Not Impressions

**Measure before you characterise. Presence is not provenance. "Unknowable" is a
claim.**

Six principles that all fail the same way: something *feels* established — because
it is visible, because it is present, because someone said so — and gets offered
with the confidence of a measurement.

### Measure before you characterise

When a decision turns on **what something contains**, open it and count. Do not
describe it from its structure, from an issue's claim about it, or from a tag list.
A heading tells you a thing is *present*, never that it is *populated* — an empty
`<conditionalstyles/>` and one with rules look identical in a list of child names.

Four instances in one rfp session, each corrected by the user's follow-up question
rather than by review: a tradeoff described as three times its real size; an issue's
stale claim repeated as current; an installed version reported as sixteen releases
behind when a parallel session had updated it eighteen minutes earlier; and "nothing
on main addresses this" from a local `main` three commits behind — one `git fetch`
away from the truth.

**A measurement carries the time it was taken.** One made earlier in the same
session is not a current one, least of all for anything another session can change
underneath it. For anything git-backed, `git fetch` first: reading a local clone and
reporting it as the state of the world is the same error with a longer fuse.

**And before hand-rolling a parser for a probe, check whether the code already has
one.** A bespoke parser silently narrows the population it can see, and the result
looks like a measurement rather than a sample — worse than not measuring, because it
carries a number. Measured 10 of 80 with a hand-written matcher; routed through the
package's own resolver it was 14 of 117.

### Presence is not provenance

When something's **presence** is offered as evidence for **how it got there**, find
the fact that actually discriminates. A QGIS project's `3.30.1` stamp was offered as
evidence a desktop had opened it — but the template it was copied from carries that
stamp, so a never-opened project reads the same. What actually proved it was a
tracking key the template does not contain.

The tell: reaching for the *most visible* fact rather than the *discriminating* one,
because the visible fact is consistent with the conclusion. **Consistency is not
support.** Before offering "X shows Y", ask what else would produce X. If anything
would, X is not evidence.

When the user pushes back on an inference, re-derive rather than defend. The
conclusion often survives; the reasoning that reaches it is usually different.

### "It can only be answered by testing" is a claim with an author

An issue or a colleague saying a question needs a field season, a device or a deploy
is stating a claim, not a property of the problem. Spend the cheap probe first.

rfp#186 opened with "three questions decide whether this is viable, and none can be
answered by reading." Two fell in about twenty minutes — one to reading a call
graph, one to re-reading a file already on disk — turning "run a field season, then
decide what to build" into "build it, then confirm one thing."

The claim is usually made by someone who knows the domain, at a moment before they
looked. Not wrong so much as **unexamined**, which is what lets it survive into the
plan. Then **bound what the probe closed**: reading a desktop plugin says nothing
about the mobile app. An over-claimed probe is worse than none.

### A real bug is not necessarily the reported bug

A defect found while investigating a symptom is **evidence, not the answer**. Before
offering it as the cause, check that it produces *exactly* the symptom described,
including the details that sound incidental.

Two confident wrong causes in a row on rfp#196 — a layer missing from a map theme
(a real bug, fixed) and a sub-pixel geometry (a real measurement). Both true;
neither explained the report. The actual cause was draw order, and the user named it
himself. The discriminating fact was in his words all along: *"as soon as I stop
tracking I can't see the track"* rules out both theories in one line.

Finding a genuine defect feels like finding *the* defect — the relief of having an
explanation is what stops the check. Write the reported symptom out and ask whether
the proposed cause produces **all** of it. Say which parts are still unexplained:
"this is a real bug and it may not be your bug" is honest and cheap.

### An enumeration is not a checklist

A probe listing what exists — subkeys present, columns found, files listed — answers
"what is here", never "what do we want". Scope arriving this way looks
evidence-backed, so it survives review.

On rfp#68, "the two Mergin subkeys that exist" became "the settings to verify",
then an item on a field checklist a human had to walk outdoors to complete. Nothing
in the codebase read or wrote `PhotoNaming`. Before a probe's output becomes work,
grep for each item and ask whether anything consumes it. When it duplicates
something already done another way, name the comparison — the existing approach
usually wins for a reason worth stating.


**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.


# Planning Conventions

How Claude manages structured planning for complex tasks using planning-with-files (PWF).

## When to Plan

Use PWF when a task has multiple phases, requires research, or involves more than ~5 tool calls. Triggers:
- User says "let's plan this", "plan mode", "use planning", or invokes `/planning-init`
- Complex issue work begins (multi-step, uncertain approach)
- Claude judges the task warrants structured tracking

Skip planning for single-file edits, quick fixes, or tasks with obvious next steps.

## The Workflow

1. **Explore first** — Enter plan mode (read-only). Read code, trace paths, understand the problem before proposing anything. When the work codifies a pattern that already exists in multiple places (reference implementations across repos), read **every** reference in full, not just the canonical one — variation across references surfaces patches before v0.1 instead of as churn later (soul#52: reading all 4 references preempted 5 of the 7 fixes a dry-run would have found). Don't substitute Explore-agent summaries for direct reads; agents sometimes report existing files as absent.
2. **Plan to files** — Write the plan into 3 files in `planning/active/`:
   - `task_plan.md` — Phases with checkbox tasks
   - `findings.md` — Research, discoveries, technical analysis
   - `progress.md` — Session log with timestamps and commit refs
3. **Plan-review with the Plan agent — concurrently, not as a gate** — Once `task_plan.md` is scaffolded, spawn the Plan subagent (`Agent({subagent_type: "Plan", prompt: "..."}`) and ask it to critically review the task_plan against the issue body + actual codebase. Categorize findings as Blocker / Gap / Ordering / Assumption / Scope / Acceptance. The agent reads files fresh — it catches what you miss when you've been thinking about the design too long. Real example: caught 21 issues including hardcoded literals across 4 files not listed in the plan, untested DB column mismatches, and a baseline-cache-shadow that would have produced a 6-second no-op run.

   **Do not wait for it.** Spawn, then start the lowest-risk phase. Background agents have repeatedly returned late — in one case after the entire issue had shipped — so treating the review as a precondition stalls the work for as long as the agent takes (see `karpathy.md` §6). Fold findings in whenever they land: pre-baseline they edit the plan; mid-implementation they become follow-up commits. A review that arrives after the code is written is not wasted — the reviewer reads real code instead of a plan, which is how one late review still contributed three fixes that no earlier reading had found. If you genuinely cannot proceed without the result, run it with `run_in_background: false` so the blocking is explicit.

   Verify before acting, in both directions. Findings have been confidently wrong (a "BLOCKER" disproved by a 30-second probe) and confidently right about things nobody suspected. Reproduce the claim first.

   **"Both directions" includes the reviewer's conclusions, not just its findings.**
   A review is wrong in the *alarming* direction loudly — a BLOCKER you probe and
   disprove costs one round-trip. It is wrong in the *reassuring* direction
   silently, because nothing prompts you to check a sentence telling you that you
   are finished. Measured 2026-08-30 in gq#77: round 4 fixed its own finding and
   characterised the residual as "definitional". Two commands showed it was not —
   the leftover axis had exactly one member and no margin, the same shape as the
   instance that reviewer had just fixed. Treat *"this is now terminal / complete /
   definitional"* as a claim with an author, exactly like an issue asserting a
   question can only be answered by testing.

   Corollary on when to stop: **convergence is not a reviewer saying you have
   converged.** Across four rounds on that PR, five instances of one defect class
   were found, and three separate "this is terminal now" claims — two of them mine
   — were wrong. What ended it was enumerating the complete candidate set and
   showing nothing sat above its source, not another round.

   **Spawn review agents UNNAMED.** Passing `name` to the `Agent` tool changes what you get: a named spawn becomes a persistent *teammate* that goes **idle** rather than completing, so there is no final report to auto-deliver and its output must be pulled with `SendMessage`. An unnamed spawn is a fire-and-return subagent whose report arrives on its own in the completion notification. Measured 2026-08-25 on one machine, one session, unchanged settings: the unnamed spawn returned in **6.4s**; three named reviewers returned nothing at all, sending only empty idle pings. Pass `name` only for a collaborator you intend to keep messaging, and shut it down when done — it pings indefinitely otherwise.

   That mis-spawn is what produced the silent-delivery failures below, so check `name` before suspecting settings. Teammate mode (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` + `teammateMode`, merged globally from `soul/settings/defaults.json`) shapes what a *named* spawn becomes; it is not by itself why findings go missing, and an unnamed spawn delivers fine with it enabled.

   **Get the findings into a file — but check who is doing the writing.** Message delivery has silently failed twice: one review arrived as idle notifications with no content, and one was routed to a different session on the user's phone, surfacing only because the user mentioned it. From this side an idle ping is indistinguishable from an agent that had nothing to say, so the loss is invisible. A file (`planning/active/review-<N>.md`) survives routing, survives the agent exiting, and is greppable later.

   **The `Plan` and `Explore` agent types have no Write tool, so they cannot write that file.** Both plan reviews on 2026-08-26 (gq#61, gq#40) were instructed to and were structurally unable to; one said so outright — *"I have no Write/Edit tools and am explicitly barred from creating files; an agent instruction can't lift that"* — and returned the full review as reply text instead. Both arrived intact, ~26 findings each. So:

   - **Read-only agent** (`Plan`, `Explore`): ask for the findings **in the reply**, then write them to `planning/active/review-<N>.md` yourself. The file is still the deliverable; you are just the one creating it.
   - **Agent type that can write**: put the file-path instruction in the first prompt, not as a follow-up.

   Asking for a file the agent cannot produce costs a round-trip, and — worse — sets you up to read an absent file as an absent review. Check the agent type's tools before writing the instruction.

   **Review the fixes, not just the code.** The second pass is where the value concentrates, because a fix written under a wrong assumption reproduces the same defect. Measured on gq#52: pass 1 found 13 defects, pass 2 found 7 more — including a blocker sitting *inside the fix* for pass 1's blocker, the same class twice (`lty`, then `fill_alpha`) because completeness was reasoned about rather than computed. Pass 3, scoped narrowly to the file edited most, found no new instances; **convergence is the signal to stop, not a fixed number of rounds.**

   Ask for the **mechanism**, not more instances. Pass 3's best finding was that an invariant was enforced by two lists happening to agree — which is what had produced instances two and three.

   The thing reviewers catch that self-probing does not is **interop**: 18 tests inspected a legend object and none handed it to the renderer, which rejected it outright. Ask the consumer.
4. **Lock naming before the baseline** — If naming feedback surfaces during planning (legacy filename, inconsistency with an existing file family), fold the rename into the convention + task_plan BEFORE the baseline commit, not as a follow-up. Pre-baseline it's free; retrofitting after implementation cascades (soul#52: `build_exec_pdf.R` → `run_pagedown_exec_summary.R` locked in pre-baseline meant zero downstream rework).
5. **Commit the plan** — After Plan-agent review + fixes. This is the baseline.
6. **Work in atomic commits** — Each commit bundles code changes WITH checkbox updates in the planning files. The diff shows both what was done and the checkbox marking it done.
7. **Code check before commit** — Run `/code-check` on staged diffs before committing. Don't mark a task done until the diff passes review.
8. **Archive when complete** — Move `planning/active/` to `planning/archive/` via `/planning-archive`. Write a README.md in the archive directory with a one-paragraph outcome summary and closing commit/PR ref — future sessions scan these to catch up fast. Where the work produced measurements, that README is also the evidence record; see below.

## The archive README is the measurement record

Debugging and benchmarking sessions are systematic investigation: a stated unknown, an
experiment, a number, a conclusion, and usually two or three informative dead ends. That
is SRED evidence, and it scatters — into PR bodies, issue comments, and log files whose
names encode a timestamp and nothing else. In six months the chain *we did not know X,
we measured Y, therefore Z* survives only in a chat transcript.

**The archive README is where that chain lives.** Not a separate run record: the PWF
triple already holds every part of it — the question in `task_plan.md`'s frame, the
method in `progress.md`, the numbers in `findings.md`, the dead ends in its "Errors
Encountered" table. A second document would restate all of it and be half-populated.
The README is the index over them.

So an archive README for work that produced measurements carries two more sections:

```markdown
## Measurement

m1 0.0391 vs cypher 0.0872 min/1k segments — hosts are 2.23x apart.
Moved the provincial estimate 5.0 h -> 4.3 h and changed how work packs across machines.

## Evidence

`data-raw/logs/study_area_run/20260831_19*` — four spins, one defect each.
```

Three rules on those sections:

- **Numbers carry units, and say what changed because of them.** A measurement nobody
  acted on is still worth recording if it turned an assumption into a number — say that
  too. "Confirmed the expected" is a real outcome.
- **Cite a prefix or glob, never a file list.** A list rots the moment a run is re-run;
  a prefix survives. This is why campaign subdirectories exist (`newgraph.md`, "Which
  logs to commit").
- **Keep the wrong turns.** A diagnosis made, retracted on a bad inference, then
  confirmed by measurement *is* the evidence of systematic investigation. Sanitising it
  into a tidy conclusion destroys exactly what makes the record worth keeping.

**The case this does not cover.** Measurement that predates an issue has no PWF to
attach to — `/planning-init` takes an issue number, and exploratory runs often *produce*
the issues rather than follow them. That measurement belongs in the issue or PR it
spawned, with the log directory's own README as the index. Do not build a third system
to close this gap.

## Atomic Commits (Critical)

Every commit that completes a planned task MUST include:
- The code/script changes
- The checkbox update in `task_plan.md` (`- [ ]` -> `- [x]`)
- A progress entry in `progress.md` if meaningful

This creates a git audit trail where `git log -- planning/` tells the full story. Each commit is self-documenting — you can backtrack with git and understand everything that happened.

## File Formats

### task_plan.md

Phases with checkboxes. This is the core tracking file.

```markdown
# Task: <issue title> (#<N>)

<issue body — Problem section if present, otherwise first paragraph>

## Phase 1: [Name]
- [ ] Task description
- [ ] Another task

## Phase 2: [Name]
- [ ] Task description
```

Mark tasks done as they're completed: `- [x] Task description`

### findings.md

Append-only research log. Discoveries, technical analysis, things learned.

```markdown
# Findings

## [Topic]
[What was found, with source/date]

## Errors Encountered

| Error | Resolution |
|-------|------------|
```

### progress.md

Session entries with commit references.

```markdown
# Progress

## Session YYYY-MM-DD
- Completed: [items]
- Commits: [refs]
- Next: [items]
```

<!-- The Reboot Test and the error ledger below are adapted from -->
<!-- OthmanAdi/planning-with-files (MIT). Soul does not install or invoke that -->
<!-- plugin — the useful parts are carried here as text. Adapted 2026-08-26. -->
<!-- Same precedent as the attribution header in karpathy.md. -->

## The Reboot Test

The planning files exist so the work survives an interruption. Whether they
actually do is checkable: at any point mid-task, these five questions must be
answerable from the files alone, without the conversation.

| Question | Answer source |
|----------|---------------|
| Where am I? | Current phase in `task_plan.md` |
| Where am I going? | Remaining phases in `task_plan.md` |
| What's the goal? | The `# Task: <title> (#N)` frame and problem statement at the top of `task_plan.md` |
| What have I learned? | `findings.md` |
| What have I done? | `progress.md` |

If an answer lives only in the session, **write it down and commit it**. Written
is not sufficient: an uncommitted `findings.md` does not move between machines,
and a repo whose `planning/` is gitignored accepts `git add planning/` with exit
0 while tracking nothing — see Directory Structure below.

This is the operational check for the rule that every interruption should be a
resume point: a session death, sleep, or machine swap should cost a re-run at
most, never lost context. That rule states the goal; this tests it.

Run it before any long wait, before compaction, and before switching machines —
the moments that take a session without warning. `/compact-prep` and
`/planning-update` are where it gets run; this section is what it asks.

## Directory Structure

```
planning/
  active/          <- Current work (3 PWF files)
  archive/         <- Completed issues
    YYYY-MM-issue-N-slug/
```

If `planning/` doesn't exist in the repo, run `/planning-init` first.

**`planning/active/` must be tracked, not gitignored.** The atomic-commit rule
above requires each commit to carry its own checkbox flip in `task_plan.md`; an
ignored `active/` drops it silently, so `git log -- planning/` shows archives
appearing fully-formed with no history behind them. In-flight PWF also stops
surviving a move between machines.

The failure is quiet in both directions. `git add planning/` reports nothing and
exits 0 on an ignored path, and files tracked *before* the rule existed keep
being tracked — including through a `git mv` into the ignored directory. So a
repo can look like it is working right up until the first genuinely new PWF file,
which simply never appears in a commit.

Check rather than assume:

```bash
git check-ignore -v planning/active/task_plan.md   # expect no output
```

Found 2026-08-24 in gq, where the rule dated from the scaffold commit and the
#17 files had only survived because they predated their move into that
directory. gq and roli were the only 2 of 32 repos carrying it; roli still does.

## When Something Keeps Failing

Before a second attempt, name the failure class. A **deterministic** failure
returns the same result to the same inputs, so re-running unchanged only spends a
turn — change the inputs or change the approach. A **transient** failure
(network, a provider read, a rate limit, a resource still settling) is the case
where a re-run *is* the attempt: `code-check-infra.md` prescribes exactly that for a
tofu plan that falsely reports a resource deleted. The rule is not "never retry";
it is never retry unchanged while expecting a different answer.

Escalate rather than iterate once the approach itself is in question. Report what
was tried and the exact error, and hand over the commands to run — the user is
assumed to be away, so a question answerable from a phone beats a retry loop they
cannot see. Escalating is not stopping: commit the current state, then move to
the lowest-risk independent part of the plan while the question is outstanding.

Two classes escalate immediately rather than after retries, because further
attempts make them worse:

- **A clamped session.** Once a live credential has been read, later
  system-mutating commands are refused regardless of route — seven consecutive
  refusals across unrelated routes is the documented case (`newgraph.md`,
  "Reading a secret clamps the rest of the session"). Trying more phrasings is
  the failure mode, not the remedy, and `/permissions` does not clear it.
- **Rate limits.** Retrying extends the block (`ci-monitoring.md`).

### Log the errors that cost a retry

An error that took more than one attempt to get past goes in `findings.md`, so
one task does not hit the same wall twice:

```markdown
## Errors Encountered

| Error | Resolution |
|-------|------------|
| `fatal: Unimplemented pathspec magic '_'` | Long-form `:(exclude)path` |
```

That row is also what graduation looks like: it began as one task's blocker and
now lives in `code-check.md` as a general rule about pathspec magic. Most rows
never make that trip and should not — the ledger's job is to stop one task
repeating itself.

When a failure does generalize, it graduates to the convention that owns its
class: `code-check.md` for a bug class in a diff (or `code-check-infra.md` when it
is specific to provisioning), `ci-monitoring.md` for CI
behaviour, the domain convention otherwise.

## Skills

| Skill | When to use |
|-------|-------------|
| `/planning-init` | First time in a repo — creates directory structure |
| `/planning-update` | Mid-session — sync checkboxes and progress |
| `/planning-archive` | Issue complete — archive and create fresh active/ |
