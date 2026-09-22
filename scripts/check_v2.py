#!/usr/bin/env python3
"""Mechanical checks for lib/v2 and test/v2, from docs/ARCHITECTURE_RENEWAL.md.

Everything here is a number or a pattern, so it fails instead of being argued
about: file and function length, nesting, `part`, `dynamic`, `late`, the
import table, no old-app imports, and file writes only inside storage/.

    python3 scripts/check_v2.py            # exit 1 on any finding
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "lib" / "v2"
TEST = REPO / "test" / "v2"

MAX_FILE_LINES = 600
MAX_FUNCTION_LINES = 50
MAX_NESTING = 3

# What each top-level v2 folder may import from within v2.
# `diagnostics/` is the log facade: everything but pure `chess/` reports
# through it, and it depends on nothing in v2.
ALLOWED = {
    "chess": {"chess"},
    "diagnostics": {"diagnostics"},
    "storage": {"chess", "storage", "diagnostics"},
    "engines": {"chess", "engines", "diagnostics"},
    "net": {"chess", "net", "diagnostics"},
    "ui": {"ui", "diagnostics"},
    "workspace": {"chess", "storage", "engines", "net", "ui", "workspace", "diagnostics"},
    "features": {"chess", "storage", "engines", "net", "ui", "workspace", "features", "diagnostics"},
    "app": {"chess", "storage", "engines", "net", "ui", "workspace", "features", "app", "diagnostics"},
}
# engines/ stays pure Dart so a test can run an engine outside Flutter.
FLUTTER_FREE = {"chess", "engines", "diagnostics"}
IO_ALLOWED = {"storage", "engines", "app"}
# Writers outside storage/: only the engine installer, which writes a binary, not user data.
WRITERS_ALLOWED = {"engines/stockfish_install.dart"}

FUNCTION_START = re.compile(
    r"^(\s*)(?:static\s+)?(?:@\w+\s+)*[\w<>?,\s\[\]()]+\s+_?\w+\s*\([^;]*\)\s*(?:async\*?\s*)?\{\s*$"
)
IMPORT = re.compile(r"^import\s+'([^']+)'")
# Visual values live in ui/theme.dart so the look can change in one place.
# A size written on one line of an `Icon(...)` is caught; one spread over
# several lines is not, which is the limit of a line-by-line check.
LITERAL_STYLE = re.compile(r"Color\(0x|fontSize:|fontFamily:\s*'|Icon\([^)]*\bsize:\s*[\d.]")
WIDGET_IMPORT = re.compile(r"^import 'package:flutter/(?:material|widgets|cupertino)\.dart'")
WRITE_CALL = re.compile(r"\b(writeAsString|writeAsBytes|openWrite|\.create\(|\.delete\(|rename\()")
# A file that builds a `File(` is one that could write outside the store; a
# method that only has File in its name, such as `importFile(`, is not.
FILE_CONSTRUCTOR = re.compile(r"\bFile\(")


def relative_folder(path: Path) -> str:
    return path.relative_to(LIB).parts[0]


def check_imports(path: Path, lines: list[str], findings: list[str]) -> None:
    folder = relative_folder(path)
    is_widget = folder != "app" and any(WIDGET_IMPORT.match(line) for line in lines)
    for n, line in enumerate(lines, 1):
        m = IMPORT.match(line)
        if not m:
            continue
        target = m.group(1)
        where = f"{path.relative_to(REPO)}:{n}"
        if is_widget and (target == "dart:io" or "/net/" in target or target.startswith("../net/")):
            findings.append(f"{where}: a widget file imports {target}; widgets take owners and values")
        if target.startswith("package:chess_auto_prep/") and "/v2/" not in target:
            findings.append(f"{where}: imports the old app ({target})")
        if target.startswith("package:flutter") and folder in FLUTTER_FREE:
            findings.append(f"{where}: {folder}/ must stay free of Flutter")
        if target == "dart:io" and folder not in IO_ALLOWED:
            findings.append(f"{where}: dart:io outside {sorted(IO_ALLOWED)}")
        if target.startswith(("package:", "dart:")):
            continue
        resolved = (path.parent / target).resolve()
        if LIB not in resolved.parents:
            findings.append(f"{where}: imports outside lib/v2 ({target})")
            continue
        other = resolved.relative_to(LIB).parts[0]
        if other not in ALLOWED.get(folder, set()):
            findings.append(f"{where}: {folder}/ may not import {other}/")
        if folder == "features" and other == "features":
            mine = path.relative_to(LIB).parts[1]
            theirs = resolved.relative_to(LIB).parts[1]
            if mine != theirs:
                findings.append(f"{where}: feature {mine} imports feature {theirs}")


def check_functions(path: Path, lines: list[str], findings: list[str]) -> None:
    where = path.relative_to(REPO)
    i = 0
    while i < len(lines):
        m = FUNCTION_START.match(lines[i])
        if not m or lines[i].lstrip().startswith(("if ", "for ", "while ", "switch ", "return ")):
            i += 1
            continue
        # A test file's main() is a list of cases, not a function to read.
        if TEST in path.parents and re.match(r"^void main\(", lines[i]):
            i += 1
            continue
        indent = len(m.group(1))
        depth, deepest, end = 0, 0, i
        for j in range(i, len(lines)):
            depth += lines[j].count("{") - lines[j].count("}")
            deepest = max(deepest, depth)
            if depth == 0:
                end = j
                break
        length = end - i + 1
        if length > MAX_FUNCTION_LINES:
            findings.append(f"{where}:{i + 1}: function is {length} lines (max {MAX_FUNCTION_LINES})")
        # Braces on the function line itself count as depth 1.
        if deepest - 1 > MAX_NESTING and indent <= 2:
            findings.append(f"{where}:{i + 1}: nesting depth {deepest - 1} (max {MAX_NESTING})")
        i = end + 1


def check_file(path: Path, findings: list[str]) -> None:
    lines = path.read_text().splitlines()
    where = path.relative_to(REPO)
    if len(lines) > MAX_FILE_LINES:
        findings.append(f"{where}: {len(lines)} lines (max {MAX_FILE_LINES})")
    is_lib = LIB in path.parents
    folder = relative_folder(path) if is_lib else None
    for n, line in enumerate(lines, 1):
        code = line.split("//")[0]
        if re.match(r"^\s*part\b", code):
            findings.append(f"{where}:{n}: `part` is not allowed")
        if re.search(r"\bdynamic\b", code):
            findings.append(f"{where}:{n}: `dynamic`")
        if is_lib and folder != "ui" and LITERAL_STYLE.search(code):
            findings.append(f"{where}:{n}: literal colour, font or icon size outside ui/ (add a token to ui/theme.dart)")
        if is_lib and re.search(r"\blate\b", code) and "late final" not in code:
            findings.append(f"{where}:{n}: `late` that is not `late final`")
        writer = is_lib and (folder == "storage" or str(path.relative_to(LIB)) in WRITERS_ALLOWED)
        if is_lib and not writer and WRITE_CALL.search(code) and FILE_CONSTRUCTOR.search("".join(lines)):
            findings.append(f"{where}:{n}: file write outside storage/")
    if is_lib:
        check_imports(path, lines, findings)
    check_functions(path, lines, findings)


def main() -> int:
    findings: list[str] = []
    for root in (LIB, TEST):
        for path in sorted(root.rglob("*.dart")):
            check_file(path, findings)
    total = sum(1 for _ in LIB.rglob("*.dart"))
    lib_lines = sum(len(p.read_text().splitlines()) for p in LIB.rglob("*.dart"))
    print(f"lib/v2: {total} files, {lib_lines} lines")
    for finding in findings:
        print(finding)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
