import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'recovery_files.dart';
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

  /// Applies an already admitted [payload]. Source revisions were checked
  /// at admission; later saves may pass, but missing or non-plain PGNs refuse
  /// publication. [sources] follows accepted chapter relocations.
  ///
  /// [attempted] carries the bytes an earlier attempt of the same change set
  /// out to publish. A file that already holds them was written, even if that
  /// attempt failed before it heard so, and is skipped: a retry never appends
  /// a history row or an answer twice.
  ///
  /// Throws [TrainingChanged] when a source or a row changed since it was
  /// read, [TrainingUnreadable] when a file is not rows or a row a change
  /// replaces cannot be read ([TrainingUnreadable.wholeFile] tells them
  /// apart), [TrainingSourceNotReadNow] when a source cannot be read right
  /// now, which a retry of the same change may get past, and
  /// [FileSystemException] when a training file cannot be read or written.
  Future<void> apply(
    String payload,
    Map<String, Revision> sources, {
    required String trainingRoot,
    required Map<String, List<int>> attempted,
  }) async {
    final change = TrainingPayload.decode(payload);
    await _checkSources(change, sources, trainingRoot);
    final before = {
      for (final name in trainingParticipants) name: await _bytes(name),
    };
    final after = change.plan(before);
    const equal = ListEquality<int>();
    for (final name in trainingParticipants) {
      if ((attempted.containsKey(name) &&
              equal.equals(before[name], attempted[name])) ||
          equal.equals(before[name], after[name])) {
        continue;
      }
      final bytes = after[name]!;
      final path = p.join(documents.path, name);
      await discardLeftoverStage(path);
      attempted[name] = bytes;
      await _publish(path, bytes);
      await testHook?.call(_steps[trainingParticipants.indexOf(name)]);
    }
    await syncDirectoryWhereSupported(documents.path, _synchronize);
    await testHook?.call(TrainingWriteStep.completed);
  }

  Future<void> _checkSources(
    TrainingPayload change,
    Map<String, Revision> sources,
    String trainingRoot,
  ) async {
    for (final path in change.sources) {
      final expected = sources[path];
      if (expected == null) throw TrainingChanged('Training source $path');
      final canonical = canonicalSource(path, trainingRoot);
      // A chapter saved since (an autosave publishes a new file under the
      // same name) keeps the rows meaningful: they name the path and a stable
      // line id. A chapter that is gone, or whose path now names a link, a
      // folder or a hard-linked file refuses the change. One that cannot be
      // read right now (a save renaming over it, a sharing violation) fails
      // this attempt and leaves the change to be retried.
      switch (await probeDocument(canonical)) {
        case FileFound():
          break;
        case FileMissing() || FileNotPlain():
          throw TrainingChanged('Training source $path');
        case FileNotReadNow(:final detail):
          throw TrainingSourceNotReadNow(detail, canonical);
      }
    }
  }

  /// [path], as a row names it under [trainingRoot], spelled under the
  /// canonical [documents] the way a relocation records it.
  String canonicalSource(String path, String trainingRoot) =>
      p.isWithin(documents.path, path)
      ? path
      : p.join(documents.path, p.relative(path, from: trainingRoot));

  Future<Uint8List?> _bytes(String name) async {
    final path = p.join(documents.path, name);
    final observed = await observeFile(path);
    if (observed.status == 1) return null;
    if (observed.status != 0 || observed.bytes == null) {
      throw FileSystemException('Training file is unreadable or linked', path);
    }
    return observed.bytes;
  }
}

/// A chapter a training change names cannot be read right now: a permission
/// error, a sharing violation, a cloud file not downloaded. Only the changes
/// that name that chapter must wait for it; a failure of the training files
/// themselves stays a plain [FileSystemException], which every change waits
/// for.
final class TrainingSourceNotReadNow extends FileSystemException {
  const TrainingSourceNotReadNow(String detail, String path)
    : super('Training source: $detail', path);
}

const _steps = [
  TrainingWriteStep.reviews,
  TrainingWriteStep.streaks,
  TrainingWriteStep.history,
  TrainingWriteStep.attempts,
];
