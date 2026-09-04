# Mutation testing

Line coverage answers "did this line run in the suite?". It does not answer the
question you actually care about: **would anything fail if this line were
wrong?** Those come apart badly. When this was first run here, three files at
100% line coverage scored 100%, 78% and 56% — the last one, `trick_scoring.dart`,
had nearly half its logic executed by the suite and defended by none of it.

`scripts/mutation_test.py` makes a small semantic change to a source file (a
"mutant" — flip `>=` to `>`, drop a `!`, change `+ 1` to `- 1`) and re-runs that
file's tests. A mutant the suite still passes on **survived**: that is a hole,
and it names the exact line.

## Running it

```
scripts/ci.sh with -- python3 scripts/mutation_test.py \
    --target lib/services/generation/tree_prune.dart \
    --tests  test/services/generation/tree_prune_test.dart

scripts/mutation_sweep.sh                 # every pair in mutation_targets.txt
scripts/mutation_sweep.sh --max 30        # more mutants per file
```

Always go through `scripts/ci.sh with --`. A campaign is dozens of `flutter
test` runs; inside one `ci.sh with` they queue for the machine-wide Flutter lock
**once** instead of once each. The sweep script deliberately takes the lock per
target rather than for the whole run, so other agents can interleave.

Only the target's own tests are run, never the full suite — seconds per mutant.

## Reading the result

- **KILLED** — a test failed. The line is defended.
- **SURVIVED** — every test still passed. Nothing asserts this behaviour.
- **INVALID** — the mutant did not compile. Excluded from the score; it is
  evidence about Dart, not about your tests.

Score is `killed / (killed + survived)`. Chase survivors, not the percentage:
some survivors are worth nothing (a mutated `maxDepth = 30` default, a progress
callback's index) and some are worth a lot (`loss >= kBlunderCp ? 'Blunder' :
'Inaccuracy'` surviving means the blunder threshold is asserted nowhere).

## Caveats worth knowing

- Mutations are textual, with string and comment regions masked out, so a `>`
  inside a PGN literal or a doc comment is never touched. It is not an AST
  rewrite: a surviving mutant is always real, but the operator list is not
  exhaustive.
- A mutant that hangs is counted as killed (the behaviour changed observably).
- `--seed` makes the mutant selection reproducible. Quote it when you report a
  score, because a different seed samples different mutants.
- The target file is restored in a `finally`. If a run is killed with SIGKILL
  mid-campaign, check `git diff` on the target before trusting the tree.

## Adding a target

Append a `lib file|test file` pair to `scripts/mutation_targets.txt`. Prefer
modules that already look well tested — that is where a survivor tells you
something you did not already know.
