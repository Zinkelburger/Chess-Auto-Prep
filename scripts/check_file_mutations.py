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
    "lib/debug/agent_driver.dart": (1, "debug screenshot output"),
    "lib/debug/desktop_self_test.dart": (4, "explicit packaged-app check: optional diagnostic report and disposal of its own temporary profile; rename/delete calls exercise the guarded v2 store"),
    "lib/storage/log_file.dart": (2, "append-only diagnostic log with one rotated generation; never user data"),
    "lib/engines/stockfish_install.dart": (
        5,
        "reproducible engine bundle, v2: support dir, stale stamp delete, "
        ".part write, rename, stamp",
    ),
    "lib/engines/hivemind_install.dart": (
        4,
        "reproducible bughouse engine bundle, v2: verified .part write, "
        "rename into place, removal of its own leftover .part and of an "
        "hour-old one a killed install left",
    ),
    "lib/storage/tournament_inbox.dart": (1, "disposable cross-process request: atomically claim the public name; delete only the private claim, never a newer request"),
    "lib/storage/tournaments.dart": (
        1,
        "v2 tournament commit: remove only its own completed PGN/metadata "
        "recovery journal; trash uses native no-replace relocation",
    ),
    "lib/storage/bughouse_matches.dart": (
        1,
        "v2 bughouse matches: a deleted match's folder is renamed into "
        "bughouse_matches/.trash, the old app's quarantine; writes go "
        "through atomic_write",
    ),
    "lib/storage/generation_trees.dart": (2, "v2 derived search tree: under the Documents lock, unlink (never follow) whatever a crash left at the staging name before writing a new tree; after a tree is kept, remove the chapter's v2- run folders (real directories holding a tree, never links, never v1, never an agent's v2-agent- run) beyond the newest 8 earlier runs"),
    "lib/storage/disk_usage.dart": (1, "v2 Databases storage: on an explicit, confirmed request delete a derived database the app downloads or rebuilds (the master games or a leftover copy of a derived database) with its SQLite sidecars; never user data"),
    "lib/storage/master_games_import.dart": (1, "v2 master games database: SQLite reports it damaged or not a database, so it is renamed aside with its sidecars (never deleted) and a new one started"),
    "lib/storage/settings_store.dart": (2, "v2 preferences: a settings.json that cannot be read is renamed aside into Support/recovery-quarantine, never deleted"),
    "lib/storage/atomic_write.dart": (3, "v2 atomic publication: staged temporary and sweep; replacement/flush use document_file_io"),
    "lib/storage/file_relocation.dart": (1, "v2 journaled file relocation: remove only an empty directory this attempt created and still owns after a refused native rename"),
    "lib/storage/journal_records.dart": (1, "v2 journals under Support: one removal takes away a stopped journal write's staged copy, a following or aside marker whose record is gone, a record with its marker once its operation finished, and an aside marker once its record moved; unreadable records are moved aside"),
    "lib/storage/recovery_files.dart": (2, "v2 staged copies: remove a stopped write's leftover stage, as a link when it is one so its target is never touched; restore a recorded absence (an undone edit's books.json) only where the caller has just read exactly the bytes the operation recorded"),
    "lib/storage/recovery_quarantine.dart": (1, "v2 quarantine: move an unreadable or unfinishable record aside under Support, never delete it"),
    "lib/storage/training_writes.dart": (2, "v2 old training queue under Support: delete finished receipts and the emptied folder; unfinished records are moved aside"),
    "lib/storage/my_games_files.dart": (1, "no filesystem mutation of its own: deleting a person's downloaded games is one call into the guarded PgnDocumentStore.delete, which moves the file into recovery, that the pattern above matches by method name"),
    "lib/storage/pgn_file_store.dart": (1, "no filesystem mutation of its own: one call into FileRelocations.delete that the pattern above matches by method name"),
    "lib/storage/chapter_files.dart": (3, "v2 repertoire listing: one mutation takes away a repertoire folder whose chapters have all been deleted, and only when nothing is left in it; one takes away an import's own dot-prefixed staging folder directly under the root, which the listing never shows, when the import could not finish; one takes away a chapter file a change created a moment ago and could not use, under the profile lock and only while its bytes are still exactly what was created"),
    "lib/storage/backups.dart": (4, "v2 kept versions under Support; creates folders and sets aside unreadable indexes; explicit retention cleanup removes only archived versions beyond the newest 100 and older than 90 days; an owed history merged into its document's newer one leaves an index already copied there and an emptied folder, which are removed"),
    "lib/storage/viewer_drafts.dart": (1, "v2 unsaved viewer edits under Support: the one mutation takes a checkpoint away once its edits were saved or discarded; one edited past or unreadable is moved aside, never deleted"),
    "lib/storage/update_files.dart": (4, "v2 update downloads under the cache folder: stream into a private attempt folder's .part, rename it only once size and SHA-256 match, delete a failed/cancelled or superseded attempt folder (never one an armed helper uses), and remove the helper's one-shot last-error.txt once read; all derived data"),
    "lib/storage/update_install.dart": (5, "v2 update helper hand-off: write the disposable armed marker, reopen marker, helper script and Windows request into the verified payload's private attempt folder; delete the armed marker to cancel"),
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
