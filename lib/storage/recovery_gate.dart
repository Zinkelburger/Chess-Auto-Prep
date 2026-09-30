import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'compound_write.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'file_relocation.dart';
import 'mutation_guards.dart';
import 'recovery_ledger.dart';
import 'relocation_notes.dart';
import 'training_writes.dart';

/// Why a write an unfinished operation guards is refused; the next write
/// tries again.
const stillFinishing = 'still finishing an earlier edit to this file';

/// What one store command touches, so the gate knows which unfinished
/// operations it must try first and which stand in its way.
sealed class Access {
  const Access(this.paths);

  /// Files or folders, in any spelling of the profile's roots.
  final Iterable<String> paths;
}

/// Touches nothing an operation owes: listings, catalogs, reads of files no
/// operation changes.
final class Anywhere extends Access {
  const Anywhere() : super(const []);
}

/// Reads [paths]: owed operations that change them are tried first, and the
/// read goes ahead either way.
final class Reads extends Access {
  const Reads(super.paths);
}

/// Writes [paths] in place: refused while an owed operation changes one,
/// unless only references are left to that operation.
final class Saves extends Access {
  const Saves(super.paths);
}

/// Records an operation over [paths]: refused while any owed operation
/// changes one, since the new one would plan over the old one's half.
final class Records extends Access {
  const Records(super.paths);
}

/// The journal folders a pass finishes, the last two left by older builds.
const _journals = [
  CompoundWrites.journal,
  FileRelocations.journal,
  RelocationNotes.journal,
  TrainingQueueMigration.journal,
];

/// The profile-wide lock every document access and change takes, the one the
/// old app takes too, and the place where operations a stopped process left
/// half done are finished.
///
/// Each access looks at the names in the journal folders, never their
/// contents, and runs a pass over every journal when one is due
/// ([RecoveryLedger.passDue]): on the first access, when a record nobody
/// here has seen appears, and when an operation left unfinished is due
/// again — at each of the next three accesses, then less often, so a
/// lasting problem stops costing every access. A pass that could not run —
/// a lock another app kept, a step that failed — is tried again after
/// [retryDelay], waiting longer after each lock it could not take. Each
/// unfinished operation is finished on its own: one that cannot be is set
/// aside and logged by its owner, and never stops the access that found it.
///
/// An access that reads or writes a file an owed operation changes tries
/// that operation once more first, so what a failed command left is what
/// the next read sees. Until it is finished, a write there is refused
/// ([Saves], [Records]): it would leave the operation matching neither its
/// before nor its after, and it would be set aside. An operation guards only
/// what it renames or rewrites whole — a move its file or folder, an edit
/// its PGNs — never the training rows or book selectors that follow them.
/// One that has guarded for [escalateAfter] stops guarding the next time a
/// write meets it (`stopGuarding`): one that has not landed is undone and
/// set aside, and one that has lets plain saves pass.
///
/// Callers must not reenter [access] from inside its action.
final class RecoveryGate {
  RecoveryGate({
    required this.documents,
    required this.support,
    Future<void> Function(CompoundWriteStep)? compoundHook,
    Future<void> Function(FileRelocationStep)? relocationHook,
    this.retryDelay = const Duration(seconds: 30),
    this.escalateAfter = const Duration(minutes: 5),
    DateTime Function() clock = DateTime.now,
  }) : _clock = clock,
       notes = RelocationNotes(documents: documents, support: support),
       relocations = FileRelocations(
         documents: documents,
         support: support,
         testHook: relocationHook,
         clock: clock,
       ),
       training = TrainingQueueMigration(
         documents: documents,
         support: support,
       ),
       compounds = CompoundWrites(
         documents: documents,
         support: support,
         testHook: compoundHook,
         clock: clock,
       ),
       ledger = RecoveryLedger.of(support);

  final Directory documents;
  final Directory support;
  final RelocationNotes notes;
  final CompoundWrites compounds;
  final FileRelocations relocations;
  final TrainingQueueMigration training;

  /// What this process owes on the profile, shared by all its gates.
  final RecoveryLedger ledger;

  /// How long after a pass that could not run the next one waits.
  final Duration retryDelay;

  /// How long an owed operation may keep a write waiting.
  final Duration escalateAfter;
  final DateTime Function() _clock;

  /// Runs [action] under the profile lock, first finishing what a stopped
  /// process or a failed command left half done, if a pass is due.
  Future<T> run<T>(Future<T> Function() action) =>
      access(const Anywhere(), action, owed: _never);

  /// Runs [action] under the profile lock: a pass if one is due, then a try
  /// of the owed operations that change [access]'s paths, then [action] —
  /// or [owed] when one still stands in the way of a write.
  Future<T> access<T>(
    Access access,
    Future<T> Function() action, {
    required T Function(String detail) owed,
  }) async {
    final root = Directory(p.join(documents.path, 'repertoires'));
    await root.create(recursive: true);
    final canonical = await root.resolveSymbolicLinks();
    return withDirectoryLock(
      Directory(p.join(canonical, '.cap-directory-domain')),
      () async {
        final listing = await ledger.list(_journals);
        ledger.listed(listing);
        final passed = ledger.passDue(_clock(), listing);
        if (passed) await _pass(listing);
        final paths = {for (final path in access.paths) _canonical(path)};
        // A pass just tried everything; a pass that waits tries nothing.
        if (!passed && access is! Anywhere && !ledger.waiting(_clock())) {
          await _retry(ledger.naming(paths));
        }
        if (access is Saves || access is Records) {
          await _escalate(ledger.naming(paths));
        }
        final guard = switch (access) {
          Anywhere() || Reads() => null,
          Saves() => ledger.naming(paths).where((o) => !o.savesPass),
          Records() => ledger.naming(paths),
        };
        if (guard?.firstOrNull case final owing?) {
          log.w(
            'refuse a write while ${owing.journal}/${owing.id} is unfinished',
            owing.detail,
          );
          return owed(stillFinishing);
        }
        return action();
      },
    );
  }

  /// [path] as the owners' records spell it: under the canonical roots.
  String _canonical(String path) {
    final canonical = p.normalize(p.absolute(path));
    for (final (configured, root) in [
      (documents, compounds.documents),
      (support, compounds.support),
    ]) {
      final from = p.normalize(p.absolute(configured.path));
      if (p.equals(from, canonical) || p.isWithin(from, canonical)) {
        return p.normalize(
          p.join(root.path, p.relative(canonical, from: from)),
        );
      }
    }
    return canonical;
  }

  /// Finishes what a stopped or failed access left half done, and tells the
  /// ledger when the next pass may run.
  Future<void> _pass(Listing listing) async {
    try {
      await lockedForRelocation(
        documents,
        DocumentRef(documents.path),
        [support],
        () async {
          if (await _finishEach()) {
            ledger.passRan(listing);
          } else {
            ledger.passCouldNotRun(_clock(), retryDelay, locked: false);
          }
        },
        (detail) {
          log.w('take the locks to finish unfinished operations', detail);
          // Another app holding a lock may keep it for long: wait longer
          // each time rather than stalling every access on it.
          ledger.passCouldNotRun(_clock(), retryDelay, locked: true);
        },
      );
    } on Object catch (error) {
      log.w('finish unfinished operations', error);
      ledger.passCouldNotRun(_clock(), retryDelay, locked: false);
    }
  }

  /// Whether every step ran. What each step could not finish its owner
  /// reported to the ledger.
  Future<bool> _finishEach() async {
    var ran = true;
    for (final (name, step) in [
      ('the old training queue', training.recover),
      ('older relocation notes', notes.finishOwed),
      ('unfinished edits', compounds.recover),
      ('unfinished moves', relocations.recover),
    ]) {
      try {
        await step();
      } on Object catch (error) {
        ran = false;
        log.w('finish $name', error);
      }
    }
    return ran;
  }

  /// Tries once more the journals of the [owed] operations an access is
  /// about to read or write. Each outcome goes to the ledger; one still
  /// unfinished keeps guarding its paths.
  Future<void> _retry(Iterable<Owed> owed) async {
    final journals = {for (final operation in owed) operation.journal};
    if (journals.isEmpty) return;
    try {
      await lockedForRelocation(
        documents,
        DocumentRef(documents.path),
        [support],
        () => _recover(journals),
        (detail) => log.w('take the locks to finish $journals', detail),
      );
    } on Object catch (error) {
      log.w('finish $journals', error);
    }
  }

  /// Stops the operations among [owed] that have kept writes waiting for
  /// [escalateAfter] guarding what they change, so no write waits on one
  /// forever.
  Future<void> _escalate(Iterable<Owed> owed) async {
    final stops = {
      CompoundWrites.journal: compounds.stopGuarding,
      FileRelocations.journal: relocations.stopGuarding,
    };
    final due = [
      for (final operation in owed)
        if (stops.containsKey(operation.journal) &&
            !operation.savesPass &&
            !_clock().isBefore(operation.since.add(escalateAfter)))
          (operation.journal, operation.id),
    ];
    if (due.isEmpty) return;
    try {
      await lockedForRelocation(
        documents,
        DocumentRef(documents.path),
        [support],
        () async {
          for (final (journal, id) in due) {
            await stops[journal]!(id);
          }
        },
        (detail) => log.w('take the locks to stop guarding $due', detail),
      );
    } on Object catch (error) {
      log.w('stop guarding $due', error);
    }
  }

  Future<void> _recover(Set<String> journals) async {
    for (final (journal, recover) in [
      (CompoundWrites.journal, compounds.recover),
      (FileRelocations.journal, relocations.recover),
    ]) {
      if (!journals.contains(journal)) continue;
      try {
        await recover();
      } on Object catch (error) {
        log.w('finish the records in $journal', error);
      }
    }
  }
}

Never _never(String detail) =>
    throw StateError('An access that changes nothing was refused: $detail');
