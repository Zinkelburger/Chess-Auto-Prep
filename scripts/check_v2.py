#!/usr/bin/env python3
"""Mechanical checks for lib/v2 and test/v2, from docs/ARCHITECTURE_RENEWAL.md.

Everything here is a number or a pattern, so it fails instead of being argued
about: file and function length, nesting, `part`, `dynamic`, `late`, the
import table (one mode never imports another), no old-app imports, file
writes only inside storage/, and a state that listens to its widget's
owner following the widget when it changes.

The length caps are backstops against a god file, not targets: a file or a
function is split when it holds two jobs, never to get under a number.

    python3 scripts/check_v2.py            # exit 1 on any finding
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "lib" / "v2"
TEST = REPO / "test" / "v2"

MAX_FILE_LINES = 1000
MAX_FUNCTION_LINES = 80
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
# net/ holds sockets as well as HTTP clients: the Lichess login listens on
# a loopback port for the browser. Files are still written only in storage/.
IO_ALLOWED = {"storage", "engines", "net", "app"}
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
        # A test file's main() and its group(...) bodies are lists of cases,
        # not functions to read; each test(...) inside is still checked.
        if TEST in path.parents and re.match(r"^(void main\(|\s*group\()", lines[i]):
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


# ---------------------------------------------------------------------------
# Classes. A line-by-line look cannot tell a field from a method or a brace
# in a string from a block, so the class checks read the file with comments
# and string contents blanked, then split each class body into members.


def blank_literals(src: str) -> str:
    """[src] with comments and the insides of string literals turned to
    spaces, newlines kept: braces in them no longer count and every offset
    is still on its line. An interpolation `${...}` is skipped as code."""
    out: list[str] = []
    i = 0
    while i < len(src):
        end = _literal_end(src, i)
        if end is None:
            out.append(src[i])
            i += 1
            continue
        out.append(re.sub(r"[^\n]", " ", src[i:end]))
        i = end
    return "".join(out)


def _literal_end(src: str, i: int) -> int | None:
    """Where the comment or string starting at [i] ends; None when none
    starts there."""
    if src.startswith("//", i):
        end = src.find("\n", i)
        return len(src) if end < 0 else end
    if src.startswith("/*", i):
        end = src.find("*/", i + 2)
        return len(src) if end < 0 else end + 2
    raw = src[i] in "rR" and src[i + 1 : i + 2] in ("'", '"')
    if raw and i > 0 and (src[i - 1].isalnum() or src[i - 1] == "_"):
        return None
    if raw or src[i] in "'\"":
        return _string_end(src, i + 1 if raw else i, raw)
    return None


def _string_end(src: str, i: int, raw: bool) -> int:
    quote = src[i] * 3 if src.startswith(src[i] * 3, i) else src[i]
    i += len(quote)
    while i < len(src) and not src.startswith(quote, i):
        if len(quote) == 1 and src[i] == "\n":
            return i
        if not raw and src[i] == "\\":
            i += 2
        elif not raw and src.startswith("${", i):
            i = _interpolation_end(src, i + 2)
        else:
            i += 1
    return min(len(src), i + len(quote))


def _interpolation_end(src: str, i: int) -> int:
    depth = 0
    while i < len(src):
        end = _literal_end(src, i)
        if end is not None:
            i = end
            continue
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            if depth == 0:
                return i + 1
            depth -= 1
        i += 1
    return i


CLASS = re.compile(
    r"^(?:(?:abstract|final|base|sealed|interface|mixin)\s+)*class\s+(\w+)([^{;]*)\{",
    re.M,
)
ASSIGN = re.compile(r"(?<![=!<>])=(?![=>])")


def dart_classes(clean: str) -> list[tuple[str, str, str, int]]:
    """(name, header, body, line) of each class in blanked source."""
    found = []
    for m in CLASS.finditer(clean):
        depth, i = 1, m.end()
        while i < len(clean) and depth:
            depth += {"{": 1, "}": -1}.get(clean[i], 0)
            i += 1
        line = clean.count("\n", 0, m.start()) + 1
        found.append((m.group(1), m.group(2), clean[m.end() : i - 1], line))
    return found


def flatten(text: str) -> str:
    """[text] with what is inside (), [] and {} blanked, so a search finds
    only its own level: the `=` of a default parameter is not a field's."""
    out, depth = [], 0
    for c in text:
        if c in ")]}":
            depth = max(depth - 1, 0)
        out.append(c if depth == 0 else " ")
        if c in "([{":
            depth += 1
    return "".join(out)


def class_members(body: str) -> list[tuple[str, bool]]:
    """Each member of a class body with whether it ends in a block: a
    method, constructor or getter with a body. A member ending in `;` is a
    field, or a method, getter or constructor without one."""
    members: list[tuple[str, bool]] = []
    current, braces, parens, block = "", 0, 0, False
    for c in body:
        current += c
        if c in "([":
            parens += 1
        elif c in ")]":
            parens -= 1
        elif c == "{":
            if braces == 0 and parens == 0:
                block = not _starts_expression(current[:-1])
            braces += 1
        elif c == "}":
            braces -= 1
            if braces == 0 and parens == 0 and block:
                members.append((current.strip(), True))
                current, block = "", False
        elif c == ";" and braces == 0 and parens == 0:
            members.append((current.strip(), False))
            current = ""
    return members


def _starts_expression(head: str) -> bool:
    """Whether a `{` after [head] opens a value (a map, a set, a closure in
    an initializer) rather than a body. A constructor's `: x = y {` is a
    body: its `=` comes after the colon."""
    head = flatten(head)
    assign = ASSIGN.search(head)
    colon = head.find(":")
    return "=>" in head or (assign is not None and (colon < 0 or assign.start() < colon))




LISTENS_TO_WIDGET = re.compile(r"\bwidget\.[\w.?!]+\s*\.\.?\s*addListener\s*\(")


def check_classes(where: str, source: str, findings: list[str]) -> None:
    for name, header, body, line in dart_classes(blank_literals(source)):
        if re.search(r"\bextends\s+State<", header):
            _check_listening(where, name, header, class_members(body), line, findings)


def _check_listening(where, name, header, members, line, findings) -> None:
    """A state that joins its widget's listenable in initState must leave
    it for the new one when the widget is rebuilt with another, or it
    listens to an owner nobody shows any more."""
    init = [text for text, block in members if block and re.search(r"\binitState\s*\(", text)]
    if not init or not LISTENS_TO_WIDGET.search(init[0]):
        return
    if "ListeningState" in header:
        return
    if any(re.search(r"\bdidUpdateWidget\s*\(", text) for text, _ in members):
        return
    findings.append(
        f"{where}:{line}: {name} listens to widget.… in initState without "
        "ListeningState or didUpdateWidget"
    )


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
        check_classes(str(where), "\n".join(lines), findings)
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
