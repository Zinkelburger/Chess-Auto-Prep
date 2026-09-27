import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'journal_records.dart';
import 'recovery_files.dart';
import 'recovery_quarantine.dart';
import 'training_payload.dart';
import 'training_rows.dart';

enum TrainingWriteStep { reviews, streaks, history, attempts, completed }

/// Puts one training change into the four training files.
///
/// Each file is replaced whole and atomically, so a stopped process leaves
/// every file either as it was or as this change makes it; a change that
/// touches several files (a rating writes the review, streaks and history)
/// can land in some and not others, which loses at most that one answer's
/// remainder and never a row that was already saved. That is the trade the
/// old per-answer journal made expensive: a create, a base64 copy of all four
/// files and a rewrite for every answer.
final class TrainingWriter {
  TrainingWriter({
    required this.documents,
    this._publish = replaceFile,
    this._synchronize = syncDirectory,
    this.testHook,
  });

  /// The canonical Documents folder the files sit in.
  final Directory documents;
  final Future<void> Function(String, List<int>) _publish;
  final Future<void> Function(String) _synchronize;
  final Future<void> Function(TrainingWriteStep)? testHook;

  /// Applies [payload], after checking that every PGN it names is still the
  /// file it was read from ([sources]) or a later save of it.
  ///
  /// [attempted] carries the bytes an earlier attempt of the same change set
  /// out to publish. A file that already holds them was written, even if that
  /// attempt failed before it heard so, and is skipped: a retry never appends
  /// a history row or an answer twice.
  ///
  /// Throws [TrainingChanged] when a source or a row changed since it was
  /// read, and [TrainingUnreadable] when a file is not rows.
  Future<void> apply(
    String payload,
    Map<String, Revision> sources, {
    required String trainingRoot,
    required Map<String, List<int>> attempted,
    bool Function(String path) movedAway = _never,
  }) async {
    final change = TrainingPayload.decode(payload);
    await _checkSources(change, sources, trainingRoot, movedAway);
    final before = {
      for (final name in trainingFileNames) name: await _bytes(name),
    };
    final after = change.plan(before);
    const equal = ListEquality<int>();
    for (final name in trainingFileNames) {
      if ((attempted.containsKey(name) &&
              equal.equals(before[name], attempted[name])) ||
          equal.equals(before[name], after[name])) {
        continue;
      }
      final bytes = after[name]!;
      await _keepFirstVersion(name, before[name]);
      final path = p.join(documents.path, name);
      await discardLeftoverStage(path);
      attempted[name] = bytes;
      await _publish(path, bytes);
      await testHook?.call(_steps[trainingFileNames.indexOf(name)]);
    }
    if (!Platform.isWindows) await _synchronize(documents.path);
    await testHook?.call(TrainingWriteStep.completed);
  }

  Future<void> _checkSources(
    TrainingPayload change,
    Map<String, Revision> sources,
    String trainingRoot,
    bool Function(String path) movedAway,
  ) async {
    for (final path in change.sources) {
      final expected = sources[path];
      if (expected == null) throw TrainingChanged('Training source $path');
      final canonical = p.isWithin(documents.path, path)
          ? path
          : p.join(documents.path, p.relative(path, from: trainingRoot));
      // A chapter saved since (an autosave publishes a new file under the
      // same name) keeps the rows meaningful: they name the path and a stable
      // line id. A chapter that is gone, or moved away so that its path now
      // names something else, refuses the change.
      if (movedAway(canonical) ||
          await probeDocument(canonical) is! FileFound) {
        throw TrainingChanged('Training source $path');
      }
    }
  }

  Future<Uint8List?> _bytes(String name) async {
    final path = p.join(documents.path, name);
    final observed = await observeFile(path);
    if (observed.status == 1) return null;
    if (observed.status != 0 || observed.bytes == null) {
      throw FileSystemException('Training file is unreadable or linked', path);
    }
    return observed.bytes;
  }

  /// The first write to a file keeps a `<file>.pre-csv-v2.bak` copy of it, as
  /// the old app does before it rewrites a file in the newer format.
  Future<void> _keepFirstVersion(String name, Uint8List? before) async {
    if (before == null || name == attemptsFile) return;
    final path = p.join(documents.path, '$name.pre-csv-v2.bak');
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return;
    }
    await discardLeftoverStage(path);
    await createFileExclusively(path, before);
  }
}

bool _never(String path) => false;

const _steps = [
  TrainingWriteStep.reviews,
  TrainingWriteStep.streaks,
  TrainingWriteStep.history,
  TrainingWriteStep.attempts,
];

/// Earlier builds queued every training change in `Support/training-writes/`
/// before writing it. Finished records there are only receipts and are
/// removed; one that never finished holds the answer it was saving, so it is
/// set aside ([quarantine]) with a line in the log rather than replayed onto
/// files that may have moved on since.
final class TrainingQueueMigration {
  TrainingQueueMigration({
    required Directory documents,
    required Directory support,
  }) : documents = canonicalRecoveryRoot(documents),
       support = canonicalRecoveryRoot(support);

  final Directory documents;
  final Directory support;
  Directory get _folder => Directory(p.join(support.path, 'training-writes'));

  Future<void> recover() async {
    if (await FileSystemEntity.type(_folder.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final records = await readJournal(
      _folder,
      decode: (value, id) =>
          value is Map<String, Object?> && value['state'] == 'complete',
    );
    for (final (file, complete) in records) {
      if (complete) {
        await file.delete();
      } else {
        await quarantine(
          support,
          file,
          'an unfinished training change from an earlier build',
        );
      }
    }
    try {
      await _folder.delete();
    } on FileSystemException catch (error) {
      log.w('remove the old training queue ${_folder.path}', error);
    }
  }
}
