import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'compound_write.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'file_relocation.dart';
import 'foreign_recovery.dart';
import 'mutation_guards.dart';
import 'relocation_notes.dart';
import 'training_records.dart';
import 'training_writes.dart';

/// The profile-wide lock every document access and change takes, the one the
/// old app takes too, and the place where operations a stopped process left
/// half done are finished.
///
/// Finishing happens once, on the first access, and again after an access
/// that failed. Each unfinished operation is finished on its own: one that
/// cannot be is set aside and logged by its owner, and never stops the access
/// that found it. Callers must not reenter [run] from inside its action.
final class RecoveryGate {
  RecoveryGate({
    required this.documents,
    required this.support,
    Future<void> Function(CompoundWriteStep)? compoundHook,
    Future<void> Function(FileRelocationStep)? relocationHook,
  }) : notes = RelocationNotes(
         notes: PendingRepoints(support, documents: documents),
         records: TrainingRecords(documents),
       ),
       relocations = FileRelocations(
         documents: documents,
         support: support,
         testHook: relocationHook,
       ),
       training = TrainingQueueMigration(
         documents: documents,
         support: support,
       ),
       compounds = CompoundWrites(
         documents: documents,
         support: support,
         testHook: compoundHook,
       );

  final Directory documents;
  final Directory support;
  final RelocationNotes notes;
  final CompoundWrites compounds;
  final FileRelocations relocations;
  final TrainingQueueMigration training;

  bool _recovered = false;

  /// Runs [action] under the profile lock, first finishing what a stopped
  /// process left half done if that has not been looked at yet.
  Future<T> run<T>(Future<T> Function() action) async {
    final root = Directory(p.join(documents.path, 'repertoires'));
    await root.create(recursive: true);
    final canonical = await root.resolveSymbolicLinks();
    return withDirectoryLock(
      Directory(p.join(canonical, '.cap-directory-domain')),
      () async {
        if (!_recovered) {
          _recovered = true;
          await _recover();
        }
        try {
          return await action();
        } on Object {
          // A failed access may have left its own operation half done.
          _recovered = false;
          rethrow;
        }
      },
    );
  }

  Future<void> _recover() => lockedForRelocation(
    documents,
    DocumentRef(documents.path),
    [support],
    () async {
      for (final (name, step) in [
        ('the old training queue', training.recover),
        ('older relocation notes', notes.finishOwed),
        ('unfinished edits', compounds.recover),
        ('unfinished moves', relocations.recover),
        ('the old app\'s operations', () => refuseV1Recovery(documents, support)),
      ]) {
        try {
          await step();
        } on Object catch (error) {
          log.w('finish $name', error);
        }
      }
    },
    (detail) => log.w('take the locks to finish unfinished operations', detail),
  );
}
