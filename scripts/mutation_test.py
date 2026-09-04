#!/usr/bin/env python3
"""Mutation testing for Dart sources.

Line coverage tells you a line ran. It does not tell you whether any assertion
would notice if the line were *wrong*. This does: it makes small semantic
changes to a source file ("mutants") and re-runs that file's tests. A mutant
the tests still pass on ("survived") is a hole — the code is executed but not
defended.

Design notes for this repo:
  * The whole campaign runs inside ONE Flutter-lock acquisition. Invoke it as
        scripts/ci.sh with -- python3 scripts/mutation_test.py …
    so the dozens of test runs queue once, not once each.
  * Only the target's own tests are run, not the full suite — seconds, not
    minutes.
  * Mutations are applied to source text with string and comment regions
    masked out, so a `>` inside a doc comment or a PGN literal is never hit.

Usage:
    python3 scripts/mutation_test.py --target lib/x.dart --tests test/x_test.dart
    python3 scripts/mutation_test.py --target lib/x.dart --tests test/a test/b \
        --max 40 --seed 7 --json report.json
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, asdict
from pathlib import Path

FLUTTER = os.environ.get("FLUTTER") or (
    str(Path.home() / "sdk/flutter/bin/flutter")
    if (Path.home() / "sdk/flutter/bin/flutter").exists()
    else shutil.which("flutter")
)

# --------------------------------------------------------------------------
# Masking: which characters are real code (not string/comment)?
# --------------------------------------------------------------------------


def code_mask(text: str) -> list[bool]:
    """True where the character is live code, False inside strings/comments."""
    mask = [True] * len(text)
    i, n = 0, len(text)
    while i < n:
        two = text[i : i + 2]
        three = text[i : i + 3]
        if two == "//":
            j = text.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                mask[k] = False
            i = j
            continue
        if two == "/*":
            j = text.find("*/", i + 2)
            j = n if j == -1 else j + 2
            for k in range(i, j):
                mask[k] = False
            i = j
            continue
        if three in ("'''", '"""'):
            q = three
            j = text.find(q, i + 3)
            j = n if j == -1 else j + 3
            for k in range(i, j):
                mask[k] = False
            i = j
            continue
        if text[i] in "'\"":
            q = text[i]
            raw = i > 0 and text[i - 1] == "r"
            j = i + 1
            while j < n:
                if text[j] == "\\" and not raw:
                    j += 2
                    continue
                if text[j] == q:
                    j += 1
                    break
                if text[j] == "\n":  # unterminated; bail out safely
                    break
                j += 1
            for k in range(i, min(j, n)):
                mask[k] = False
            i = j
            continue
        i += 1
    return mask


# --------------------------------------------------------------------------
# Mutation operators
# --------------------------------------------------------------------------

# (name, regex, replacement-builder). Regexes are applied to the raw text but
# every match is checked against the code mask before it is accepted.
OPERATORS: list[tuple[str, str, object]] = [
    ("relational >= -> >", r">=", lambda m: ">"),
    ("relational <= -> <", r"<=", lambda m: "<"),
    ("relational > -> >=", r"(?<![>=!<])>(?![>=])", lambda m: ">="),
    ("relational < -> <=", r"(?<![<=!>])<(?![<=])", lambda m: "<="),
    ("equality == -> !=", r"==", lambda m: "!="),
    ("equality != -> ==", r"!=", lambda m: "=="),
    ("logical && -> ||", r"&&", lambda m: "||"),
    ("logical || -> &&", r"\|\|", lambda m: "&&"),
    ("bool true -> false", r"\btrue\b", lambda m: "false"),
    ("bool false -> true", r"\bfalse\b", lambda m: "true"),
    ("isEmpty -> isNotEmpty", r"\.isEmpty\b", lambda m: ".isNotEmpty"),
    ("isNotEmpty -> isEmpty", r"\.isNotEmpty\b", lambda m: ".isEmpty"),
    ("first -> last", r"\.first\b", lambda m: ".last"),
    ("last -> first", r"\.last\b", lambda m: ".first"),
    ("arith + -> -", r"(?<![+\-=<>!])\+(?![+=])", lambda m: "-"),
    ("arith - -> +", r"(?<![+\-=<>!])-(?![-=>])", lambda m: "+"),
    ("int literal n -> n+1", r"(?<![\w.])(\d+)(?![\w.])", lambda m: str(int(m.group(1)) + 1)),
    ("drop negation !x", r"(?<![!=<>])!(?=[A-Za-z_(])", lambda m: ""),
    ("null-aware ?? -> ", r"\?\?", lambda m: "??"),  # placeholder, filtered out below
]
OPERATORS = [op for op in OPERATORS if op[0] != "null-aware ?? -> "]


@dataclass
class Mutant:
    index: int
    operator: str
    line: int
    col: int
    before: str
    after: str
    snippet: str
    status: str = "pending"   # KILLED | SURVIVED | INVALID | TIMEOUT
    seconds: float = 0.0


def line_col(text: str, pos: int) -> tuple[int, int]:
    line = text.count("\n", 0, pos) + 1
    bol = text.rfind("\n", 0, pos) + 1
    return line, pos - bol + 1


def enumerate_mutants(text: str) -> list[Mutant]:
    mask = code_mask(text)
    lines = text.splitlines()
    out: list[Mutant] = []
    for name, pattern, repl in OPERATORS:
        for m in re.finditer(pattern, text):
            s, e = m.start(), m.end()
            if not all(mask[s:e]):
                continue
            ln, col = line_col(text, s)
            src_line = lines[ln - 1] if ln - 1 < len(lines) else ""
            # Never mutate directives or annotations.
            stripped = src_line.strip()
            if stripped.startswith(("import ", "export ", "part ", "library ", "@")):
                continue
            out.append(
                Mutant(
                    index=-1,
                    operator=name,
                    line=ln,
                    col=col,
                    before=m.group(0),
                    after=repl(m),
                    snippet=stripped[:120],
                )
            )
    return out


def apply_mutant(text: str, mut: Mutant) -> str:
    lines = text.split("\n")
    ln = mut.line - 1
    line = lines[ln]
    start = mut.col - 1
    assert line[start : start + len(mut.before)] == mut.before, "mutant offset drifted"
    lines[ln] = line[:start] + mut.after + line[start + len(mut.before) :]
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Running the tests
# --------------------------------------------------------------------------

# A mutant that does not compile is not evidence about the tests, so it is
# excluded from the score. Detect that narrowly: `flutter test` says "Failed to
# load"/"Compilation failed" and runs nothing. A *runtime* error (a range
# error from a mutated loop bound, say) also prints "Error:", but the tests DID
# run and DID fail — that is a kill, not an invalid mutant. Matching "Error:"
# here would silently credit real kills as invalid and understate the score.
COMPILE_ERROR = re.compile(r"(Failed to load|Compilation failed)", re.M)
# Any compact-reporter progress line ("00:02 +12 -1: …") proves tests executed.
TESTS_RAN = re.compile(r"^\d{2}:\d{2} \s*[+~-]\d+", re.M)


# A mutant is deliberately broken code, so a test run under one can misbehave in
# ways a normal run never does: a mutated loop bound that never terminates while
# logging every iteration, an exception printed per frame. `capture_output=True`
# buffers all of that in *this* process with no ceiling. On 2026-09-04 that
# reached 30 GB and the kernel OOM-killed the editor scope the campaign happened
# to be running in, losing several agent sessions at once. So: spool the child's
# output to a file rather than to memory, and kill it the moment it exceeds what
# any real run could produce. A real `flutter test` log here is well under 1 MB.
OUTPUT_CAP = 64 * 1024 * 1024


def run_tests(tests: list[str], timeout: int) -> tuple[str, str]:
    """Return (verdict, output). verdict in pass|fail|compile_error|timeout."""
    cmd = [FLUTTER, "test", "--reporter", "compact", *tests]
    deadline = time.monotonic() + timeout
    aborted = ""
    with tempfile.TemporaryFile() as sink:
        # Own process group: `flutter test` spawns a dart VM and a frontend
        # server, and killing only the direct child leaves those running — the
        # other way a long campaign quietly eats the machine.
        proc = subprocess.Popen(
            cmd, stdout=sink, stderr=subprocess.STDOUT, start_new_session=True
        )
        try:
            while proc.poll() is None:
                if os.fstat(sink.fileno()).st_size > OUTPUT_CAP:
                    aborted = "flood"
                    break
                if time.monotonic() > deadline:
                    aborted = "timeout"
                    break
                time.sleep(0.25)
        finally:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
        if aborted:
            # Both mean the mutant changed observable behaviour: it is killed.
            return "timeout", ""
        sink.seek(0)
        out = sink.read().decode("utf-8", "replace")
    if proc.returncode == 0:
        return "pass", out
    if COMPILE_ERROR.search(out) and not TESTS_RAN.search(out):
        return "compile_error", out
    return "fail", out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True, help="lib/ file to mutate")
    ap.add_argument("--tests", nargs="+", required=True, help="test files/dirs to run")
    ap.add_argument("--max", type=int, default=30, help="max mutants (default 30)")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=0, help="per-run seconds (0 = 6x baseline)")
    ap.add_argument("--json", help="write a machine-readable report here")
    args = ap.parse_args()

    if not FLUTTER:
        print("mutation_test: flutter not found (set FLUTTER=…)", file=sys.stderr)
        return 2

    target = Path(args.target)
    text = target.read_text()

    print(f"── baseline: {' '.join(args.tests)}")
    t0 = time.time()
    verdict, out = run_tests(args.tests, timeout=900)
    baseline = time.time() - t0
    if verdict != "pass":
        print(f"mutation_test: baseline is not green ({verdict}) — fix the tests first.\n")
        print(out[-4000:])
        return 1
    print(f"   baseline green in {baseline:.0f}s")

    timeout = args.timeout or max(60, int(baseline * 6))

    mutants = enumerate_mutants(text)
    rng = random.Random(args.seed)
    rng.shuffle(mutants)
    mutants = mutants[: args.max]
    for i, m in enumerate(mutants):
        m.index = i
    print(f"── {len(mutants)} mutants (seed {args.seed}, timeout {timeout}s each)\n")

    backup = tempfile.NamedTemporaryFile("w", suffix=".dart", delete=False)
    backup.write(text)
    backup.close()

    try:
        for m in mutants:
            mutated = apply_mutant(text, m)
            target.write_text(mutated)
            t0 = time.time()
            verdict, _ = run_tests(args.tests, timeout)
            m.seconds = time.time() - t0
            m.status = {
                "fail": "KILLED",
                "pass": "SURVIVED",
                "compile_error": "INVALID",
                "timeout": "KILLED",
            }[verdict]
            flag = {"KILLED": "  ", "SURVIVED": "!!", "INVALID": " ·"}[m.status]
            print(
                f"{flag} [{m.index + 1:>3}/{len(mutants)}] {m.status:<9} "
                f"{target.name}:{m.line} {m.operator}  ({m.seconds:.0f}s)"
            )
            if m.status == "SURVIVED":
                print(f"       {m.snippet}")
    finally:
        target.write_text(text)
        os.unlink(backup.name)

    valid = [m for m in mutants if m.status != "INVALID"]
    killed = [m for m in valid if m.status == "KILLED"]
    survived = [m for m in valid if m.status == "SURVIVED"]
    score = (100.0 * len(killed) / len(valid)) if valid else 0.0

    print(f"\n── {target}")
    print(f"   mutation score: {len(killed)}/{len(valid)} killed ({score:.0f}%)")
    print(f"   invalid (did not compile): {len(mutants) - len(valid)}")
    if survived:
        print(f"\n   SURVIVORS — executed but not defended:")
        for m in survived:
            print(f"     {target}:{m.line}  {m.operator}")
            print(f"        {m.snippet}")

    if args.json:
        Path(args.json).write_text(
            json.dumps(
                {
                    "target": str(target),
                    "tests": args.tests,
                    "seed": args.seed,
                    "score": score,
                    "killed": len(killed),
                    "valid": len(valid),
                    "mutants": [asdict(m) for m in mutants],
                },
                indent=2,
            )
        )
        print(f"\n   report: {args.json}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
