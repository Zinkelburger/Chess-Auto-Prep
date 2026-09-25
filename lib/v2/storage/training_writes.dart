import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'recovery_copies.dart';
import 'recovery_files.dart';
import 'relocation_notes.dart';
import 'training_intent.dart';
import 'training_payload.dart';
import 'training_rows.dart';

enum TrainingWriteStep {
  queued,
  intent,
  reviews,
  streaks,
  history,
  attempts,
  completed,
}

/// Durable accepted commands and their ordered four-file commit. Callers own
/// domain, Documents and Support locks. Enqueue never executes predecessors.
final class TrainingWrites {
  TrainingWrites({
    required Directory documents,
    required Directory support,
    this._publish = replaceFile,
    this._synchronize = syncDirectory,
    this.testHook,
  }) : _configuredDocuments = documents,
       _configuredSupport = support,
       documents = canonicalRecoveryRoot(documents),
       support = canonicalRecoveryRoot(support) {
    _boundary = recoveryMetadataBoundary(this.support);
  }
  final Directory _configuredDocuments;
  final Directory _configuredSupport;
  final Directory documents;
  final Directory support;
  final Future<void> Function(String, List<int>) _publish;
  final Future<void> Function(String) _synchronize;
  final Future<void> Function(TrainingWriteStep)? testHook;
  late final String _boundary;
  Directory get _folder => Directory(p.join(support.path, 'training-writes'));
  String get _trainingRoot =>
      p.normalize(p.absolute(_configuredDocuments.path));

  Future<bool> inspect() async =>
      (await _readAll()).any((note) => !note.complete);

  Future<void> recover() async {
    try {
      for (final note in await _readAll()) {
        if (!note.complete) await _finish(note);
      }
    } on RecoveryRequired {
      rethrow;
    } on Object catch (error) {
      throw RecoveryRequired('Training recovery needs attention: $error');
    }
  }

  Future<void> enqueue({
    required String id,
    required String payload,
    required Map<String, Revision> sources,
    String? predecessorId,
  }) async {
    final captured = Map<String, Revision>.of(sources);
    final notes = await _readAll();
    final existing = notes.where((note) => note.id == id).firstOrNull;
    if (existing != null) {
      if (existing.digest != trainingDigest(payload) ||
          existing.dependency != predecessorId ||
          !const DeepCollectionEquality().equals(
            _sourceJson(existing.sources),
            _sourceJson(captured),
          )) {
        throw const TrainingChanged(
          'An operation id was reused with different inputs.',
        );
      }
      return;
    }
    if (predecessorId != null &&
        !notes.any((note) => note.id == predecessorId)) {
      throw const RecoveryRequired(
        'An earlier training acceptance is not durable. Retry it first.',
      );
    }
    final note = TrainingIntent(
      trainingCore(
        id: id,
        sequence: notes.length + 1,
        previous: notes.lastOrNull?.id,
        dependency: predecessorId,
        documents: documents.path,
        support: support.path,
        trainingRoot: _trainingRoot,
        sources: captured,
        payload: payload,
      ),
      'queued',
      payload,
      null,
      null,
    );
    _decode(note.toJson(), id);
    await _admit(note);
    await _validateProjection(notes, TrainingPayload.decode(payload));
    await recoveryDirectory(support, create: true);
    await recoveryDirectory(_folder, create: true);
    await flushRecoveryAncestry(
      _folder.path,
      through: _boundary,
      synchronize: _synchronize,
    );
    await _write(note, fresh: true);
    await testHook?.call(TrainingWriteStep.queued);
  }

  Future<void> commit({required String id, required String digest}) async {
    final notes = await _readAll();
    final target = notes.where((note) => note.id == id).firstOrNull;
    if (target == null || target.digest != digest) {
      throw const TrainingChanged(
        'The accepted training command cannot be verified.',
      );
    }
    if (target.complete) return;
    for (final note in notes) {
      if (!note.complete) await _finish(note);
      if (note.id == id) return;
    }
  }

  Future<void> _finish(TrainingIntent note) async {
    await _admit(note);
    if (note.state == 'queued') await _materialize(note);
    final remaining = <Map<String, Object?>>[];
    for (final file in note.files!) {
      final name = file['name']! as String;
      await requireUnusedRecoveryStage(p.join(documents.path, name));
      final current = await _bytes(name);
      final before = trainingBytes(file['before']);
      final after = trainingBytes(file['after']);
      if (_equal(current, after)) continue;
      if (!_equal(current, before)) throw TrainingChanged(name);
      remaining.add(file);
    }
    for (final file in remaining) {
      await _keepFirstVersion(file);
    }
    for (final file in remaining) {
      final name = file['name']! as String;
      final bytes = trainingBytes(file['after']);
      if (bytes == null) {
        throw const RecoveryRequired(
          'Training publication cannot delete a participant.',
        );
      }
      await _publish(p.join(documents.path, name), bytes);
      await testHook?.call(_steps[trainingFileNames.indexOf(name)]);
    }
    // A previous replacement may have landed before its flush acknowledged.
    for (final file in note.files!) {
      if (file['after'] != null) {
        await syncFile(p.join(documents.path, file['name']! as String));
      }
    }
    await flushRecoveryDirectory(documents.path, synchronize: _synchronize);
    note
      ..state = 'complete'
      ..payload = null
      ..files = null;
    await _write(note);
    await testHook?.call(TrainingWriteStep.completed);
  }

  Future<void> _validateProjection(
    List<TrainingIntent> notes,
    TrainingPayload next,
  ) async {
    var projected = {
      for (final name in trainingFileNames) name: await _bytes(name),
    };
    for (final note in notes.where((note) => !note.complete)) {
      if (note.state == 'queued') {
        projected = TrainingPayload.decode(note.payload!).plan(projected);
        continue;
      }
      for (final file in note.files!) {
        final name = file['name']! as String;
        final before = trainingBytes(file['before']);
        final after = trainingBytes(file['after']);
        if (!_equal(projected[name], before) &&
            !_equal(projected[name], after)) {
          throw TrainingChanged(name);
        }
        projected[name] = after;
      }
    }
    next.plan(projected);
  }

  Future<void> _materialize(TrainingIntent note) async {
    final before = {
      for (final name in trainingFileNames) name: await _bytes(name),
    };
    final after = TrainingPayload.decode(note.payload!).plan(before);
    final files = [
      for (final name in trainingFileNames)
        <String, Object?>{
          'name': name,
          'before': _encoded(before[name]),
          'after': _encoded(after[name]),
        },
    ];
    note
      ..files = files
      ..planDigest = note.digestPlan(files)
      ..state = 'committing';
    await _write(note);
    await testHook?.call(TrainingWriteStep.intent);
  }

  Future<void> _admit(TrainingIntent note) async {
    if (canonicalRecoveryRoot(Directory(note.trainingRoot)).path !=
        documents.path) {
      throw const RecoveryRequired(
        'The accepted training profile alias changed.',
      );
    }
    final sources = note.sources;
    for (final path in TrainingPayload.decode(note.payload!).sources) {
      final canonical = p.isWithin(documents.path, path)
          ? path
          : p.join(documents.path, p.relative(path, from: note.trainingRoot));
      var parent = p.dirname(canonical);
      while (parent != documents.path) {
        if (!p.isWithin(documents.path, parent) ||
            !await recoveryDirectory(Directory(parent))) {
          throw TrainingChanged('Training source ancestry $path');
        }
        parent = p.dirname(parent);
      }
      final observed = await probeDocument(canonical);
      final expected = sources[path]!;
      if (observed is! FileFound ||
          observed.revision != expected ||
          observed.identity != expected.nativeIdentity) {
        throw TrainingChanged('Training source $path');
      }
    }
  }

  Future<Uint8List?> _bytes(String name) async {
    final path = p.join(documents.path, name);
    final observed = await observeFile(path);
    if (observed.status == 1) return null;
    if (observed.status != 0 || observed.bytes == null) {
      throw RecoveryRequired(
        'Training participant is unreadable or linked: $path',
      );
    }
    return observed.bytes;
  }

  Future<void> _keepFirstVersion(Map<String, Object?> file) async {
    final before = trainingBytes(file['before']);
    if (before == null || file['name'] == attemptsFile) return;
    final path = p.join(documents.path, '${file['name']}.pre-csv-v2.bak');
    final observed = await observeFile(path);
    if (observed.status == 0) return;
    if (observed.status != 1) {
      throw RecoveryRequired('Training migration backup is unreadable: $path');
    }
    await requireUnusedRecoveryStage(path);
    await createFileExclusively(path, before);
  }

  Future<void> _write(TrainingIntent note, {bool fresh = false}) async {
    _decode(note.toJson(), note.id);
    final path = p.join(_folder.path, '${note.id}.json');
    await requireUnusedRecoveryStage(path);
    final bytes = utf8.encode(jsonEncode(note.toJson()));
    if (bytes.length > 512 * 1024 * 1024) {
      throw const RecoveryRequired(
        'Training recovery metadata exceeds the native read limit.',
      );
    }
    if (fresh) {
      await createFileExclusively(path, bytes);
    } else {
      await replaceFile(path, bytes);
    }
  }

  TrainingIntent _decode(Object? value, String id) => TrainingIntent.decode(
    value,
    id,
    documents: documents.path,
    support: support.path,
  );

  Future<List<TrainingIntent>> _readAll() async {
    try {
      if (canonicalRecoveryRoot(_configuredDocuments).path != documents.path ||
          canonicalRecoveryRoot(_configuredSupport).path != support.path) {
        throw const RecoveryRequired(
          'The configured training profile changed.',
        );
      }
      if (!await recoveryDirectory(documents)) {
        throw const RecoveryRequired('Training Documents is unavailable.');
      }
      if (!await recoveryDirectory(support) ||
          !await recoveryDirectory(_folder)) {
        return [];
      }
      final notes = await readRecoveryRecords(
        _folder,
        decode: _decode,
        predecessor: trainingPredecessor,
      );
      notes.sort((a, b) => a.sequence.compareTo(b.sequence));
      final preceding = <String>{};
      var pending = false;
      for (final (index, note) in notes.indexed) {
        if (note.sequence != index + 1 ||
            note.previous != (index == 0 ? null : notes[index - 1].id) ||
            (note.dependency != null && !preceding.contains(note.dependency))) {
          throw const RecoveryRequired(
            'The durable training queue has a missing or ambiguous predecessor.',
          );
        }
        if ((note.complete || note.state == 'committing') && pending) {
          throw const RecoveryRequired(
            'The training queue has impossible commit ordering.',
          );
        }
        pending = pending || !note.complete;
        preceding.add(note.id);
      }
      return notes;
    } on RecoveryRequired {
      rethrow;
    } on Object catch (error) {
      throw RecoveryRequired(
        'Training recovery metadata cannot be verified: $error',
      );
    }
  }
}

Object _sourceJson(Map<String, Revision> sources) {
  final paths = sources.keys.toList()..sort();
  return [
    for (final path in paths)
      [path, sources[path]!.contentHash, sources[path]!.nativeIdentity],
  ];
}

bool _equal(List<int>? a, List<int>? b) =>
    const ListEquality<int>().equals(a, b);
String? _encoded(Uint8List? bytes) =>
    bytes == null ? null : base64Encode(bytes);
const _steps = [
  TrainingWriteStep.reviews,
  TrainingWriteStep.streaks,
  TrainingWriteStep.history,
  TrainingWriteStep.attempts,
];
