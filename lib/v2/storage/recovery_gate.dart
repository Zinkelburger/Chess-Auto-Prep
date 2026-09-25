import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_lock.dart';
import 'file_relocation.dart';
import 'mutation_guards.dart';
import 'document_ref.dart';
import 'compound_write.dart';
import 'foreign_recovery.dart';
import 'relocation_notes.dart';
import 'training_records.dart';
import 'training_writes.dart';

/// Recovery and affected access share the supported apps' outer domain lock.
/// The order is domain, Documents, then distinct leaf directories. Callers
/// must not reenter this gate from an action that already holds it.
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
       training = TrainingWrites(documents: documents, support: support),
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
  final TrainingWrites training;

  /// Enqueue/commit callers can defer training drain, but still validate all
  /// recovery metadata and hold the same domain while accepting their command.
  /// The action acquires its own Documents/leaf locks after recovery releases
  /// those locks; it must never reenter this gate.
  Future<T> run<T>(
    Future<T> Function() action, {
    bool recoverTraining = true,
  }) async {
    final root = Directory(p.join(documents.path, 'repertoires'));
    await root.create(recursive: true);
    final canonical = await root.resolveSymbolicLinks();
    return withDirectoryLock(
      Directory(p.join(canonical, '.cap-directory-domain')),
      () async {
        // Never interpret another app's in-flight receipt or let our own
        // recovery rewrite rows while its operation is still unresolved.
        await refuseV1Recovery(documents, support);
        await lockedForRelocation(
          documents,
          DocumentRef(documents.path),
          [support],
          () async {
            // Inspect all protocols before any replay: directory order does
            // not establish which of two pending writers was accepted first.
            final trainingPending = await training.inspect();
            final notesPending = await notes.inspect();
            final compoundPending = await compounds.inspect();
            final relocationPending = await relocations.inspect();
            if (trainingPending &&
                (notesPending || compoundPending || relocationPending)) {
              throw const RecoveryRequired(
                'Training and document recovery are both unfinished. '
                'Their order cannot be established safely.',
              );
            }
            if (recoverTraining) await training.recover();
            await notes.finishOwed();
            await compounds.recover();
            await relocations.recover();
          },
          (detail) => throw RecoveryRequired(detail),
        );
        return action();
      },
    );
  }
}
