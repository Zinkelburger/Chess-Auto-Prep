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
    "lib/features/updates/services/app_update_service.dart": (1, "stream only to a private disposable .part file; verified move uses mutation service"),
    "lib/services/storage/schema_guard.dart": (2, "synchronous SQLite snapshot adapter; publish flushed VACUUM backup and remove only failed temporary output"),
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
    "lib/infrastructure/diagnostics/app_log_file.dart": (
        3,
        "append-only rotating diagnostic log; disposable and never user data",
    ),
    "lib/features/bughouse/services/bughouse_bundle.dart": (
        13,
        "reproducible extracted engine bundle",
    ),
    "lib/features/engine_tournament/services/tournament_open_request.dart": (
        3,
        "disposable inter-process request file",
    ),
    "lib/services/engine/stockfish_bundle.dart": (7, "reproducible engine bundle"),
    "lib/v2/storage/log_file.dart": (2, "append-only diagnostic log with one rotated generation; never user data"),
    "lib/v2/engines/stockfish_install.dart": (
        5,
        "reproducible engine bundle, v2: support dir, stale stamp delete, "
        ".part write, rename, stamp",
    ),
    "lib/v2/engines/hivemind_install.dart": (
        4,
        "reproducible bughouse engine bundle, v2: verified .part write, "
        "rename into place, removal of its own leftover .part and of an "
        "hour-old one a killed install left",
    ),
    "lib/v2/storage/bughouse_matches.dart": (
        1,
        "v2 bughouse matches: a deleted match's folder is renamed into "
        "bughouse_matches/.trash, the old app's quarantine; writes go "
        "through atomic_write",
    ),
    "lib/v2/storage/compound_write.dart": (1, "v2 guarded compound inverse: remove only the verified books snapshot when restoring its recorded absence; retained intent and directory flush make recovery retryable"),
    "lib/v2/storage/atomic_write.dart": (4, "v2 atomic publication: staged temporary, rename into place, sweep of interrupted writes"),
    "lib/v2/storage/file_relocation.dart": (1, "v2 journaled file relocation: remove only an empty directory this attempt created and still owns after a refused native rename; preserve committing intent"),
    "lib/v2/storage/pgn_file_store.dart": (1, "no filesystem mutation of its own: one call into FileRelocations.delete that the pattern above matches by method name"),
    "lib/v2/storage/chapter_files.dart": (2, "v2 repertoire listing: one mutation takes away a repertoire folder whose chapters have all been deleted, and only when nothing is left in it; the other takes away an import's own dot-prefixed staging folder directly under the root, which the listing never shows, when the import could not finish"),
    "lib/v2/storage/backups.dart": (2, "v2 kept versions under Support; creates folders, never removes; an unreadable index is renamed aside, not deleted"),
    "lib/v2/storage/relocation_notes.dart": (1, "v2 notes under Support saying which moves still owe their training rows; the one mutation takes a note away once its rows no longer do"),
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
