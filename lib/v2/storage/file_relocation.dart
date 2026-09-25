import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'backups.dart';
import 'backup_relocation.dart';
import 'book_references.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'pgn_document_store.dart';
import 'recovery_files.dart';
import 'relocation_notes.dart' show RecoveryRequired;
import 'relocation_record.dart';
import 'training_records.dart' as training;

enum FileRelocationStep {
  prepared,
  intent,
  document,
  reviews,
  streaks,
  history,
  attempts,
  books,
  backups,
  completed,
}

/// A file's location, training, selectors and backup ownership commit together.
/// The caller holds the profile domain, Documents and Support locks throughout.
/// Intent authorizes forward recovery from immutable before/after snapshots;
/// terminal receipts acknowledge exact retries without inspecting reused paths.
final class FileRelocations {
  FileRelocations({
    required Directory documents,
    required Directory support,
    this.testHook,
    Future<void> Function(String) synchronize = syncDirectory,
  }) : _synchronize = synchronize,
       _configuredDocuments = documents,
       _configuredSupport = support,
       documents = canonicalRecoveryRoot(documents),
       support = canonicalRecoveryRoot(support);

  final Future<void> Function(String) _synchronize;
  final Directory _configuredDocuments;
  final Directory _configuredSupport;
  final Directory documents;
  final Directory support;
  final Future<void> Function(FileRelocationStep)? testHook;
  Directory get _folder => Directory(p.join(support.path, 'relocation-writes'));
  BackupArchive get _backups =>
      BackupArchive(Directory(p.join(support.path, 'backups')));
  String get _trainingRoot =>
      p.normalize(p.absolute(_configuredDocuments.path));
  String get _books => p.join(support.path, 'books.json');
  String _path(String id) => p.join(_folder.path, '$id.json');

  Future<MoveResult> move(
    DocumentRef from,
    DocumentRef to, {
    required Revision expected,
    required String operationId,
  }) => _move(from, to, expected: expected, operationId: operationId);

  /// Quarantine has a stable name and carries the file's complete history.
  /// Keeping its latest bytes is preparation; only intent authorizes movement.
  Future<DeleteResult> delete(
    DocumentRef from, {
    required Revision expected,
    required String operationId,
  }) async {
    final to = DocumentRef(
      p.join(
        p.dirname(from.path),
        '.cap-pgn-history',
        '$operationId-${p.basename(from.path)}',
      ),
    );
    final result = await _move(
      from,
      to,
      expected: expected,
      operationId: operationId,
      keepCurrent: true,
    );
    return switch (result) {
      Moved(:final training) => Deleted(to.path, training: training),
      Conflict() => result,
      IoFailure() => result,
      Collision() => const IoFailure('The private recovery name is occupied.'),
    };
  }

  Future<MoveResult> _move(
    DocumentRef from,
    DocumentRef to, {
    required Revision expected,
    required String operationId,
    bool keepCurrent = false,
  }) async {
    try {
      _checkRoots();
      validateRelocationId(operationId);
      if (keepCurrent) validateDeletionId(operationId);
      final source = _canonical(from.path);
      final target = _canonical(to.path);
      validateRelocationPaths(documents, source, target);
      final notes = await _readAll();
      final existing = notes.where((n) => n.id == operationId).firstOrNull;
      if (existing != null &&
          (existing.kind !=
                  (keepCurrent
                      ? FileRelocationKind.delete
                      : FileRelocationKind.move) ||
              existing.from != source ||
              existing.to != target ||
              existing.hash != expected.contentHash ||
              (expected.nativeIdentity != null &&
                  existing.identity != expected.nativeIdentity))) {
        throw const RecoveryRequired(
          'This relocation id belongs to another move.',
        );
      }
      await _recover(notes);
      if (existing?.state == RelocationState.complete) {
        return _result(existing!);
      }
      final RelocationRecord record;
      if (existing != null) {
        record = existing;
      } else {
        final observed = await probeDocument(source);
        if (observed is FileMissing) return const Conflict(null);
        if (observed is FileUnreadable) return IoFailure(observed.detail);
        final file = observed as FileFound;
        if (file.revision != expected ||
            (expected.nativeIdentity != null &&
                file.identity != expected.nativeIdentity)) {
          return Conflict(file.revision);
        }
        final destination = await observeFile(target);
        if (destination.status == 0) return const Collision();
        if (destination.status != 1) {
          throw const RecoveryRequired(
            'The destination is unreadable or occupied.',
          );
        }
        record = await _plan(
          operationId,
          source,
          target,
          file,
          keepCurrent: keepCurrent,
        );
      }
      await _prepare(record, fresh: existing == null);
      await _finish(record);
      return _result(record);
    } on Object catch (error) {
      final detail = switch (error) {
        RecoveryRequired(:final detail) => detail,
        training.Malformed(:final file, :final line) =>
          'Training file $file is malformed at line $line.',
        training.IoFailure(:final detail) => detail,
        _ => '$error',
      };
      return IoFailure('File relocation needs attention: $detail');
    }
  }

  Moved _result(RelocationRecord record) => Moved(
    Revision(record.hash, nativeIdentity: record.identity),
    training: record.training.rowsChanged == 0
        ? const training.NothingToRepoint()
        : training.Repointed(record.training.rowsChanged),
  );

  Future<RelocationRecord> _plan(
    String id,
    String from,
    String to,
    FileFound file, {
    required bool keepCurrent,
  }) async {
    await _parents(from, create: false);
    await _parents(to, create: false);
    final rows = await training.TrainingRecords(documents).plan(
      DocumentRef(from),
      DocumentRef(to),
      alternateFrom: DocumentRef(
        p.join(_trainingRoot, p.relative(from, from: documents.path)),
      ),
      alternateTo: DocumentRef(
        p.join(_trainingRoot, p.relative(to, from: documents.path)),
      ),
    );
    final books = await recoveryText(_books);
    final booksAfter = relocateBookReferences(
      books,
      repertoireRoot: p.join(documents.path, 'repertoires'),
      from: from,
      to: to,
      directory: false,
    );
    Future<BackupMove> backupPlan() => _backups.planMove(
      fromId: backupId(p.relative(from, from: documents.path)),
      toId: backupId(p.relative(to, from: documents.path)),
      documentPath: to,
      operationId: id,
    );
    var backup = await backupPlan();
    if (keepCurrent) {
      final kept = await _backups.record(
        id: backup.fromId,
        documentPath: from,
        bytes: file.bytes,
        hash: file.revision.contentHash,
      );
      if (kept case BackupFailed(:final detail)) {
        throw RecoveryRequired(
          'The deleted version could not be kept: $detail',
        );
      }
      await flushRecoveryAncestry(
        _backups.folderFor(backup.fromId).path,
        through: support.path,
        synchronize: _synchronize,
      );
      backup = await backupPlan();
    }
    return RelocationRecord(
      id: id,
      kind: keepCurrent ? FileRelocationKind.delete : FileRelocationKind.move,
      from: from,
      to: to,
      trainingRoot: _trainingRoot,
      identity: file.identity,
      hash: file.revision.contentHash,
      training: rows,
      booksBefore: books,
      booksAfter: booksAfter,
      backup: backup,
    );
  }

  Future<void> _prepare(RelocationRecord record, {required bool fresh}) async {
    record.validate(documents: documents, support: support);
    await _preflight(record, allowAfter: false);
    await recoveryDirectory(support, create: true);
    await recoveryDirectory(_folder, create: true);
    // New profile/journal ancestry must survive loss of this process too.
    await flushRecoveryAncestry(_folder.path, synchronize: _synchronize);
    await _record(record, RelocationState.prepared, fresh: fresh);
    await testHook?.call(FileRelocationStep.prepared);
    await _keepTraining(record);
    await _preflight(record, allowAfter: false);
    await _record(record, RelocationState.committing);
    await testHook?.call(FileRelocationStep.intent);
  }

  Future<void> recover() async {
    _checkRoots();
    try {
      await _recover(await _readAll());
    } on RecoveryRequired {
      rethrow;
    } on Object catch (error) {
      throw RecoveryRequired('File relocation recovery failed: $error');
    }
  }

  Future<void> _recover(List<RelocationRecord> notes) async {
    for (final note in notes) {
      switch (note.state) {
        case RelocationState.prepared:
          await _record(note, RelocationState.cancelled);
        case RelocationState.committing:
          await _finish(note);
        case RelocationState.complete || RelocationState.cancelled:
          break;
      }
    }
  }

  Future<void> _finish(RelocationRecord record) async {
    await _preflight(record, allowAfter: true);
    await _keepTraining(record);
    final source = await observeFile(record.from);
    if (source.status == 0) {
      final created = await _parents(record.to, create: true);
      try {
        await movePathNoReplace(record.from, record.to);
      } on Object {
        await _removeEmptyParents(created, record);
        rethrow;
      }
    }
    await flushRecoveryAncestry(
      p.dirname(record.from),
      through: documents.path,
      synchronize: _synchronize,
    );
    await flushRecoveryAncestry(
      p.dirname(record.to),
      through: documents.path,
      synchronize: _synchronize,
    );
    await testHook?.call(FileRelocationStep.document);
    const steps = [
      FileRelocationStep.reviews,
      FileRelocationStep.streaks,
      FileRelocationStep.history,
      FileRelocationStep.attempts,
    ];
    for (var i = 0; i < record.training.files.length; i++) {
      final file = record.training.files[i];
      await _publish(
        p.join(documents.path, file.name),
        file.before,
        file.after,
      );
      await testHook?.call(steps[i]);
    }
    await _publish(_books, record.booksBefore, record.booksAfter);
    await testHook?.call(FileRelocationStep.books);
    await _backups.applyMove(record.backup);
    await testHook?.call(FileRelocationStep.backups);
    await _record(record, RelocationState.complete);
    await testHook?.call(FileRelocationStep.completed);
  }

  Future<void> _preflight(
    RelocationRecord record, {
    required bool allowAfter,
  }) async {
    _checkRoots();
    if (canonicalRecoveryRoot(Directory(record.trainingRoot)).path !=
        documents.path) {
      throw const RecoveryRequired('The recorded training root alias changed.');
    }
    await _parents(record.from, create: false);
    await _parents(record.to, create: false);
    final from = await observeFile(record.from);
    final to = await observeFile(record.to);
    bool owns(NativeFileObservation file) =>
        file.status == 0 &&
        file.identity == record.identity &&
        file.sha256Hex == record.hash;
    final before = owns(from) && to.status == 1;
    final after = from.status == 1 && owns(to);
    if (!before && !(allowAfter && after)) {
      throw const RecoveryRequired(
        'The recorded PGN location or identity changed.',
      );
    }
    for (final file in record.training.files) {
      await _expect(
        p.join(documents.path, file.name),
        file.before,
        allowAfter ? file.after : file.before,
      );
    }
    await _expect(
      _books,
      record.booksBefore,
      allowAfter ? record.booksAfter : record.booksBefore,
    );
    await _backups.validateMove(record.backup, allowAfter: allowAfter);
  }

  Future<void> _keepTraining(RelocationRecord record) async {
    final folder = Directory(
      p.join(documents.path, '.cap-reference-history', record.id),
    );
    for (final file in record.training.files.where((f) => f.changed)) {
      final path = p.join(folder.path, file.name);
      await _parents(path, create: true);
      final kept = await recoveryText(path);
      if (kept == null) {
        await requireUnusedRecoveryStage(path);
        await createFileExclusively(path, utf8.encode(file.before!));
      } else if (kept != file.before) {
        throw RecoveryRequired(
          'The retained training snapshot changed: $path.',
        );
      }
      await flushRecoveryAncestry(
        folder.path,
        through: documents.path,
        synchronize: _synchronize,
      );
    }
  }

  Future<void> _publish(String path, String? before, String? after) async {
    final current = await _expect(path, before, after);
    if (current == after) {
      await flushRecoveryDirectory(p.dirname(path), synchronize: _synchronize);
    } else if (after == null) {
      throw const RecoveryRequired('Relocation cannot remove a participant.');
    } else {
      await requireUnusedRecoveryStage(path);
      await replaceFile(path, utf8.encode(after));
    }
  }

  Future<String?> _expect(String path, String? before, String? after) async {
    final current = await recoveryText(path);
    if (current != before && current != after) {
      throw RecoveryRequired(
        'A relocation participant changed externally: $path.',
      );
    }
    return current;
  }

  Future<void> _record(
    RelocationRecord record,
    RelocationState state, {
    bool fresh = false,
  }) async {
    final path = _path(record.id);
    await requireUnusedRecoveryStage(path);
    final bytes = utf8.encode(jsonEncode(record.toJson(state)));
    if (bytes.length > 512 * 1024 * 1024) {
      throw const RecoveryRequired(
        'The relocation journal exceeds the native read limit.',
      );
    }
    if (fresh) {
      await createFileExclusively(path, bytes);
    } else {
      await replaceFile(path, bytes);
    }
    record.state = state;
  }

  Future<List<RelocationRecord>> _readAll() async {
    if (!await recoveryDirectory(support) ||
        !await recoveryDirectory(_folder)) {
      return [];
    }
    final entries = await _folder.list(followLinks: false).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final notes = <RelocationRecord>[];
    for (final entry in entries) {
      if (entry is! File || p.extension(entry.path) != '.json') {
        throw RecoveryRequired(
          'Unsupported relocation metadata at ${entry.path}.',
        );
      }
      final id = p.basenameWithoutExtension(entry.path);
      validateRelocationId(id);
      final text = await recoveryText(entry.path);
      if (text == null) {
        throw RecoveryRequired('Relocation metadata disappeared: $id.');
      }
      final note = RelocationRecord.fromJson(
        jsonDecode(text),
        id: id,
        documents: documents,
      );
      note.validate(documents: documents, support: support);
      notes.add(note);
    }
    return notes;
  }

  void _checkRoots() {
    if (canonicalRecoveryRoot(_configuredDocuments).path != documents.path ||
        canonicalRecoveryRoot(_configuredSupport).path != support.path) {
      throw const RecoveryRequired('The configured profile root changed.');
    }
  }

  String _canonical(String path) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        path.contains('\u0000')) {
      throw const RecoveryRequired('Relocation path is not normalized.');
    }
    final configured = p.normalize(p.absolute(_configuredDocuments.path));
    return p.isWithin(configured, path)
        ? p.join(documents.path, p.relative(path, from: configured))
        : path;
  }

  /// Probe every existing ancestor without following links. Missing target
  /// parents are allowed while planning and are created only after preflight.
  Future<List<(String, String)>> _parents(
    String path, {
    required bool create,
  }) async {
    if (!await recoveryDirectory(documents)) {
      throw const RecoveryRequired('The Documents directory is missing.');
    }
    final created = <(String, String)>[];
    var parent = documents.path;
    for (final part in p.split(p.relative(p.dirname(path), from: parent))) {
      if (part == '.') continue;
      parent = p.join(parent, part);
      if (await recoveryDirectory(Directory(parent))) continue;
      if (!create) return created;
      await recoveryDirectory(Directory(parent), create: true);
      created.add((parent, (await observeDirectory(parent)).identity!));
    }
    return created;
  }

  /// A refused native rename can leave private empty parents. Remove only
  /// directories this attempt created and still owns; intent remains retryable.
  Future<void> _removeEmptyParents(
    List<(String, String)> created,
    RelocationRecord record,
  ) async {
    final source = await observeFile(record.from);
    if (source.identity != record.identity ||
        (await observeFile(record.to)).status != 1) {
      return;
    }
    for (final (path, identity) in created.reversed) {
      try {
        if ((await observeDirectory(path)).identity != identity) return;
        final directory = Directory(path);
        if (!await directory.list(followLinks: false).isEmpty) return;
        await directory.delete();
        await flushRecoveryDirectory(
          p.dirname(path),
          synchronize: _synchronize,
        );
      } on FileSystemException {
        // Preserve anything now occupied or inaccessible. The original error
        // remains the command's outcome and its committing intent is retained.
        return;
      }
    }
  }
}
