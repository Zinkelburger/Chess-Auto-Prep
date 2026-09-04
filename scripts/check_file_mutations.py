#!/usr/bin/env python3
"""Reject unreviewed direct filesystem mutation in production Dart code."""

from __future__ import annotations

import re
import sys
from pathlib import Path


MUTATION = re.compile(
    r"\.(?:writeAsString|writeAsBytes)(?:Sync)?\s*\("
    r"|\.(?:writeByte|writeFrom|writeString|truncate)(?:Sync)?\s*\("
    r"|\.openWrite\s*\("
    r"|\.(?:delete|deleteSync|rename|renameSync|copy|copySync)\s*\("
)

# Files below are storage adapters or explicitly disposable/reproducible data
# modules. The count is a tripwire: adding another direct mutation in an
# already-approved file still fails until this policy is deliberately reviewed.
APPROVED: dict[str, tuple[int, str]] = {
    "lib/utils/atomic_file.dart": (18, "journaled atomic-write adapter"),
    "lib/services/storage/file_mutation_service.dart": (
        7,
        "root-scoped destructive-operation adapter",
    ),
    "lib/services/storage/io_storage_service.dart": (2, "storage migration adapter"),
    "lib/utils/file_operation_lock.dart": (0, "advisory lock-file adapter"),
    "lib/services/scid/scid_writer.dart": (8, "specialized no-overwrite multi-file export"),
    "lib/services/storage/sqlite_recovery.dart": (1, "SQLite recovery adapter"),
    "lib/services/game_store/game_store_service.dart": (1, "one-time database migration"),
    "lib/debug/agent_driver.dart": (1, "debug screenshot output"),
    "lib/features/bughouse/services/bughouse_bundle.dart": (
        13,
        "reproducible extracted engine bundle",
    ),
    "lib/features/engine_tournament/services/tournament_open_request.dart": (
        3,
        "disposable inter-process request file",
    ),
    "lib/services/engine/stockfish_bundle.dart": (7, "reproducible engine bundle"),
    "lib/services/eval/cdb_snapshot_download.dart": (4, "resumable downloaded snapshot"),
    "lib/services/eval/lichess_eval_controller.dart": (4, "resumable downloaded snapshot"),
    "lib/services/eval/lichess_eval_import.dart": (6, "rebuildable database staging"),
    "lib/services/generation/run_debug_dump.dart": (5, "disposable debug artifacts"),
    "lib/services/generation/pgn_freq_cache.dart": (2, "rebuildable parser cache"),
    "lib/services/study_import/study_import_controller.dart": (1, "disposable download cache"),
}

NON_FILESYSTEM_DELETE = re.compile(r"\b(?:store|db|http)\.delete\s*\(")


def mutation_lines(path: Path) -> list[tuple[int, str]]:
    text = path.read_text(encoding="utf-8")
    if "import 'dart:io'" not in text and "import \"dart:io\"" not in text:
        return []
    found: list[tuple[int, str]] = []
    for number, line in enumerate(text.splitlines(), 1):
        if MUTATION.search(line) and not NON_FILESYSTEM_DELETE.search(line):
            found.append((number, line.strip()))
    return found


def scan(root: Path) -> list[str]:
    violations: list[str] = []
    lib = root / "lib"
    if not lib.is_dir():
        return [f"missing lib directory under {root}"]
    for path in sorted(lib.rglob("*.dart")):
        relative = path.relative_to(root).as_posix()
        hits = mutation_lines(path)
        if not hits:
            continue
        approval = APPROVED.get(relative)
        if approval is None:
            detail = ", ".join(str(line) for line, _ in hits)
            violations.append(f"{relative}:{detail}: direct filesystem mutation")
            continue
        maximum, reason = approval
        if len(hits) > maximum:
            detail = ", ".join(str(line) for line, _ in hits[maximum:])
            violations.append(
                f"{relative}:{detail}: new mutation exceeds reviewed limit "
                f"{maximum} ({reason})"
            )
    return violations


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    violations = scan(root)
    if violations:
        print("file-mutation policy violations:", file=sys.stderr)
        for violation in violations:
            print(f"  {violation}", file=sys.stderr)
        print(
            "Route durable writes through atomic_file.dart and destructive "
            "operations through file_mutation_service.dart.",
            file=sys.stderr,
        )
        return 1
    print("file-mutation policy: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
