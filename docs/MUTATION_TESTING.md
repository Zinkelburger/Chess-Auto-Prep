# Mutation testing

Line coverage answers "did this line run in the suite?". It does not answer the
question you actually care about: **would anything fail if this line were
wrong?** Those come apart badly. When this was first run here, three files at
100% line coverage scored 100%, 78% and 56% — the last one, the trick scoring
helpers (now part of `hole_scoring.dart`),
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
  inside a PGN literal or a doc comment is never touched. Generic type
  arguments are masked too, because `<` and `>` are brackets as often as they
  are comparisons in Dart — mutating the `>` in `List<GameRecord>` only ever
  produces something that will not compile, and those cost a test run each.
  It is not an AST rewrite: a surviving mutant is always real, but the operator
  list is not exhaustive.
- An INVALID mutant is not always a false one. Flipping `||` to `&&` in
  `x == null || x.foo` genuinely breaks Dart's null promotion, so the mutant
  cannot compile and is correctly excluded — the tests never got a say.
- A mutant that hangs is counted as killed (the behaviour changed observably).
- **A score is a sample, not a measurement.** `move_annotation.dart` has 103
  possible mutants; a `--max 24` run tests 24 of them. The same file scored
  100% at `--max 18` and 62% at `--max 24` — both true, and only the second
  told anyone anything. So quote the file, the seed AND the max together, never
  a bare percentage, and do not compare two numbers taken at different `--max`.
  The survivor list is the durable output; the percentage is a rough estimate
  with wide error bars.
- `--seed` makes the mutant selection reproducible. Quote it when you report a
  score, because a different seed samples different mutants.
- The target file is restored in a `finally`. If a run is killed with SIGKILL
  mid-campaign, check `git diff` on the target before trusting the tree.

## Survivors are candidates until confirmed

Running only the target's own test file is what keeps a campaign to seconds a
mutant, and it is also the method's biggest trap: almost nothing here is
covered by its same-named test alone. When this was first run,
`line_extractor.dart` was imported by fifteen other test files, and
`game_filter.dart` by sixteen — so a mutant the paired file misses may be
caught next door, and reporting it as a hole sends someone to write a test
that already exists.

So the cheap pass produces *candidates*, and `--confirm-tests` re-runs only
those against the wider suite. Survivors are few, so the second pass is cheap:

```
scripts/ci.sh with -- python3 scripts/mutation_test.py \
    --target lib/services/game_store/game_store.dart \
    --tests   test/services/game_store/game_store_test.dart \
    --confirm-tests test/services/game_store test/services/storage
```

Anything the wider suite kills is reported as killed and counted that way, with
a line saying the paired file missed it. Without this the score is a lower
bound — treat any number produced without a confirm set as one.

## Adding a target

Append `lib file|test file|confirm tests` to `scripts/mutation_targets.txt`
(the third field may be empty). Prefer modules that already look well tested —
that is where a survivor tells you something you did not already know. Work out
the third field with something like

```
grep -rln "$(basename lib/path/to/file.dart)" test/
```

## A mutant can exhaust memory, not just time

The obvious runaway is a mutant that loops forever, and the timeout catches it.
The one that actually took this machine down on 2026-09-04 was different, and
it is worth knowing before you write another harness.

`swiss.py` has a tuning constant:

```python
_COLOR_SEARCH_WINDOW = 4      # how far _find_partner looks past a colour clash
```

`test_swiss.py` imports it and sizes its fixtures with it, so the tests stay
correct if the window is ever retuned:

```python
bottom = [_state(f"b{i}", balance=-1) for i in range(_COLOR_SEARCH_WINDOW)]
```

That is good test design. It is also a loaded gun: a "widen the boundary"
mutant set the constant to `10**9`, and the *test process* — not the code under
test — tried to build a billion objects. At a measured 624 bytes each that is
582 GB. It reached 30 GB in 162 s before the kernel killed it, and systemd's
default `OOMPolicy=stop` then tore down the whole editor scope with it.

So, when writing or extending a mutation harness:

- **Never mutate a constant into an astronomical value.** `mutation_test.py`'s
  own `int literal n -> n+1` operator is deliberately conservative for this
  reason: `4 -> 5` tests the boundary without arming anything. A hand-written
  mutant list is where `10**9` creeps in.
- **Assume the child can exhaust memory** and cap it. Run the campaign through
  `scripts/ci.sh with --`, which puts it in a memory-capped cgroup; children
  inherit that cap. A bare `python3 my_harness.py` from an agent shell gets
  only the looser desktop-scope cap from `scripts/oom_containment.sh`.
- **Bound anything you capture.** `subprocess.run(capture_output=True)` has no
  ceiling, and a mutant that makes a test log per iteration will fill it.
  `run_tests()` here spools to a file and kills past 64 MB.
- **Grep the test file for names it imports from the target** before mutating
  those names. If a test uses a constant to size an allocation, that constant
  is not safe to widen.
