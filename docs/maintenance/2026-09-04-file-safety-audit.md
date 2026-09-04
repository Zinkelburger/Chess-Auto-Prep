# File safety audit

Date: 2026-09-04

Scope: production Flutter/Dart runtime and first-party repository tools. Generated,
vendored, and test-fixture cleanup code is excluded.

## Verdict

The audited failure modes are remediated in this working tree. Durable writes
now use a locked, journaled atomic replacement path; stale writers use
compare-and-swap; creates and moves refuse replacement; destructive operations
are root-scoped and revalidated while locked; and user-owned files are moved to
an application quarantine instead of being permanently deleted.

CI now rejects new direct filesystem mutations outside the reviewed storage
boundary and a small, documented allowlist. Deterministic tests inject failures
at every replacement transition, exercise rollback and recovery, race
concurrent writers, attempt traversal and symlink escapes, and verify that an
external edit is never overwritten by a stale autosave.

No implementation can promise that data is literally impossible to lose: disk
or filesystem corruption, hostile non-cooperating processes, and loss of the
device remain outside the application's control. The guarantee enforced here
is narrower and testable: for every cooperating application mutation, the old
or new complete value remains available, and an operation never silently
widens its target or overwrites an unexpected value.

## Remediation status

- `AtomicFileWriter` no longer deletes a destination before replacement. Its
  backup-and-swap fallback journals each phase, rolls back on failure, and
  recovers interrupted transactions on the next access.
- `FileOperationLock` serializes mutations in-process and across cooperating
  processes without placing lock artifacts in user directories.
- `FileMutationService` rejects root deletion, out-of-root paths, symbolic-link
  targets and escapes, wrong entity types, and replacement moves. Managed user
  deletions are quarantined under `.chess_auto_prep_trash`.
- `StorageService.writeFile` exposes explicit `createOnly` and
  `expectedContent` policies. Repertoire, chapter, and study read-modify-write
  paths use them so a stale editor reports a conflict and preserves the newer
  disk copy.
- Cross-platform filename validation is enforced in both UI validation and the
  storage boundary.
- Scid export stages and flushes the complete file set, refuses to replace an
  existing database, and removes only files installed by the failed attempt.
- The bughouse database builder retains the previous database until its sibling
  build has committed, vacuumed, closed, and can be atomically installed.
- `scripts/check_file_mutations.py`, invoked by `scripts/ci.sh lint`, makes the
  storage boundary mandatory for future production changes.

Focused Dart tests, analyzer/lint, and Python tool tests pass. The repository's
full Flutter suite currently also contains unrelated failures in concurrent
repertoire-screen, PGN-viewer layout, and generation-config work; those files
were not changed as part of this remediation.

## Required invariant

After success, failure, cancellation, a simulated crash, or a concurrent
attempt, every durable target must be either the verified old version or the
verified new version. It must never be missing, partial, silently overwritten,
or outside its allowed storage root.

## Findings

### Critical: atomic replacement can delete the only good copy

Evidence: `lib/utils/atomic_file.dart:77-82`

When rename-over-existing fails, the helper deletes the destination and retries
the rename. If that second rename fails, the original is gone. The replacement
must instead use a platform-safe replace operation or a backup-and-swap
transaction that rolls back on failure.

### Critical: destructive APIs accept arbitrary absolute paths

Evidence: `lib/services/storage/io_storage_service.dart:47-49,91-97,262-268`

The generic resolver accepts any absolute path. File deletion and recursive
directory deletion enforce no allowed root, entity type, symlink boundary, or
root/self guard. A corrupt path or missed validation can therefore broaden the
operation far beyond the intended app object.

Replace raw destructive string paths with typed `ManagedPath` values minted only
inside declared app roots. Canonicalize at the storage boundary and reject dot
traversal, symlink escape, the root itself, and an unexpected entity type.

### Critical: repertoire names are not consistently filesystem-safe

Evidence: `lib/widgets/repertoire_list_body.dart:496-510,622-642` and
`lib/services/repertoire_creation.dart:47-58`

Create and rename validate emptiness and duplicates but not separators, control
characters, dot segments, reserved Windows names, or trailing dots/spaces. The
name is joined directly into a filesystem path.

Use one cross-platform `FileName` validator for every create/rename flow, and
validate again inside storage rather than trusting the UI.

### High: Scid export deletes all originals before installing replacements

Evidence: `lib/services/scid/scid_writer.dart:124-134`

The three existing database files are deleted first, followed by three
sequential renames. A failure can leave a missing or mixed-generation database.
This needs a journaled multi-file transaction: stage and validate all files,
rotate originals to backups, install all replacements, then commit or roll back
the set.

### High: check-then-create and check-then-rename are racy

Evidence: `lib/features/repertoire/services/chapter_store.dart:54-66` and
`lib/core/study_controller.dart:74-87`

Existence is checked separately from the later mutation. Another task or process
can create or change the target in between. The mutation API must enforce an
explicit `createOnly`, `replaceExisting`, or compare-and-swap policy during the
filesystem operation.

### High: whole-file edits lack a global concurrency guard

Evidence: `lib/core/study_controller.dart:211-232` and
`lib/services/repertoire_service.dart:545-575`

Some components serialize their own calls, but storage has no per-path lock or
expected revision. Independent read-modify-write flows can both succeed and lose
one edit. Serialize by canonical path and require an expected fingerprint for
read-modify-write operations.

### High: deletion failures are swallowed

Evidence: `lib/services/storage/io_storage_service.dart:91-97,262-268`

Deletion logs an error and returns normally. Callers can then refresh UI or
clear memory as though the operation succeeded. Return a typed result or throw a
typed exception; never convert a failed destructive action into apparent
success.

### Medium: persistence logic is duplicated

Examples: bughouse and engine tournament stores, engine registry, tournament
open requests, collection exports, caches, and generated companion files.

Several services use their own fixed `.tmp` write-and-rename sequence. Platform
semantics and concurrency behavior differ. Durable data should use one mutation
service with randomized, exclusively created temporary files. Disposable caches
and reproducible bundles may be explicitly allowlisted with weaker guarantees.

### Medium: an expensive derived database is deleted before rebuild completes

Evidence: `tools/bughouse_db/index.py:178-223`

The current opening book is unlinked before merge, aggregation, `VACUUM`, and
close complete. Build and validate a sibling database, then swap it into place
while retaining the previous version until commit succeeds.

### Medium: direct truncate and append writes bypass the durability contract

Evidence: `lib/core/generation_session_controller.dart:923-931` and
`lib/services/generation/pgn_export.dart:33-40`

A crash or disk-full condition can leave a partial companion or appended PGN.
Every write should first be classified as durable user data, recoverable derived
data, or disposable cache, then use the appropriate policy.

## Recommended architecture

Introduce one capability-scoped `FileMutationService`:

1. A domain operation requests a mutation such as save chapter, rename study,
   or delete tournament.
2. The request contains a `ManagedPath`, data classification, overwrite policy,
   expected revision when applicable, and recovery policy.
3. A transactional backend validates scope, takes a per-path lock, stages data
   in an exclusive randomized sibling file, flushes and validates it, journals
   the transition, swaps with rollback, and returns a typed result.
4. User-data deletion moves the object to app quarantine or the OS trash and
   returns an undo token. Permanent purge happens later under a narrow retention
   policy.

The important design rule is to make unsafe operations unrepresentable. A UI
confirmation proves user intent; it does not prove that the storage operation is
correctly scoped or failure-safe.

## Failure-injection interface

Add a debug-only **Data Safety Lab** that can operate only on a newly created
temporary sandbox. It should show the mutation plan and filesystem tree diff,
allow failure injection after every commit step, restart the backend, and report
whether the invariant held.

Required automated suites:

- Path attacks: `..`, absolute paths, root/self, symlink escape, case-folding
  collisions, reserved names, and trailing spaces/dots.
- Replacement faults: disk full, permission failure, temp creation/write/flush,
  backup failure, every rename point, validation failure, and cleanup failure.
- Concurrency: two creates, two autosaves, stale compare-and-swap, rename versus
  delete, and separate processes.
- Multi-file commit: failure after every Scid transition, followed by recovery;
  the set must be all old or all new.
- Crash recovery: a journal left at each phase must deterministically finish or
  roll back at startup.
- Delete/undo: quarantine, restore, name collision on restore, and retention
  purge.

Add a CI rule that rejects mutating `dart:io` calls outside the filesystem
adapter and explicitly allowlisted disposable-data modules. Every allowlist
entry should state why the data is safe to recreate.

## Suggested implementation sequence

1. Remove delete-before-rename, enforce path/root/type guards, centralize
   filename validation, propagate deletion failures, and quarantine user
   deletes.
2. Add `FileMutationService` with typed paths, explicit policies, per-path
   serialization, typed results, and a journal.
3. Migrate durable call sites and add the direct-I/O CI gate.
4. Add deterministic fault injection, concurrency tests, multi-file rollback,
   and platform coverage on Linux, Windows, and macOS.

## Why this was missed

- The storage interface is generic: raw strings and generic write/delete/move
  methods leave policy to every caller.
- Protections were added incrementally for individual incidents rather than as a
  mandatory trust boundary.
- User documents, expensive derived data, downloaded bundles, and disposable
  caches were not assigned explicit safety classes.
- Tests verify successful output but do not systematically exercise disk
  failures, interruption, traversal, stale writers, or rollback.

This is an architectural gap rather than one developer forgetting one check.
The existing protections are worth keeping, but they need to be enforced by the
storage boundary instead of remaining optional at individual call sites.
