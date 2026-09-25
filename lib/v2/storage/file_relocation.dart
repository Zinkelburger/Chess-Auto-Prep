import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'backups.dart';
import 'backup_relocation.dart';
import 'book_references.dart';
import 'directory_entries.dart';
import 'recovery_copies.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'directory_snapshot.dart';
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
       support = canonicalRecoveryRoot(support) {
    // Backup preparation can create Support before the journal is written.
    // Retain its original containing ancestor through every retry.
    _metadataBoundary = recoveryMetadataBoundary(this.support);
  }

  final Future<void> Function(String) _synchronize;
  late final String _metadataBoundary;
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

  Future<FolderMoveResult> moveFolder(
    String from,
    String to, {
    required String operationId,
  }) async {
    try {
      _checkRoots();
      validateRelocationId(operationId);
      final source = _canonical(from);
      final target = _canonical(to);
      validateFolderRelocationPaths(documents, source, target);
      validateFolderParticipantPaths(documents, support, source, target);
      final notes = await _readAll();
      final existing = notes
          .where((note) => note.id == operationId)
          .firstOrNull;
      if (existing != null &&
          (existing is! FolderRelocationRecord ||
              existing.from != source ||
              existing.to != target)) {
        throw const RecoveryRequired(
          'This relocation id belongs to another operation.',
        );
      }
      await _recover(notes);
      if (existing?.state == RelocationState.complete) {
        return _folderResult(existing as FolderRelocationRecord);
      }
      final FolderRelocationRecord record;
      if (existing != null) {
        record = existing as FolderRelocationRecord;
      } else {
        await _parents(source, create: false);
        await _parents(target, create: false);
        final destination = await observeDirectory(target);
        if (destination.status == 0 ||
            (await observeFile(target)).status == 0) {
          return const FolderNameTaken();
        }
        if (destination.status != 1) {
          throw const RecoveryRequired(
            'The destination is unreadable or occupied.',
          );
        }
        record = await _planFolder(operationId, source, target);
      }
      await _prepare(record, fresh: existing == null);
      await _finish(record);
      return _folderResult(record);
    } on Object catch (error) {
      return FolderMoveFailed(
        'Folder relocation needs attention: ${_detail(error)}',
      );
    }
  }

  FolderMoved _folderResult(FolderRelocationRecord record) => FolderMoved(
    training: record.training.rowsChanged == 0
        ? const training.NothingToRepoint()
        : training.Repointed(record.training.rowsChanged),
    files: Map.unmodifiable({
      for (final entry in record.snapshot.entries)
        if (entry.kind == DirectoryEntryKind.file &&
            p.extension(entry.path).toLowerCase() == '.pgn')
          entry.path: Revision(entry.sha256!, nativeIdentity: entry.identity),
    }),
  );

  Future<FolderRelocationRecord> _planFolder(
    String id,
    String from,
    String to,
  ) async {
    await requireSameFileSystem(from, to, directory: true);
    final snapshot = await DirectorySnapshot.capture(from);
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
      directory: true,
    );
    final backups = <String, BackupMove>{};
    for (final entry in snapshot.entries) {
      if (entry.kind != DirectoryEntryKind.file ||
          p.extension(entry.path).toLowerCase() != '.pgn') {
        continue;
      }
      final source = p.join(from, entry.path);
      final target = p.join(to, entry.path);
      backups[entry.path] = await _backups.planMove(
        fromId: backupId(p.relative(source, from: documents.path)),
        toId: backupId(p.relative(target, from: documents.path)),
        documentPath: target,
        operationId: id,
      );
    }
    return FolderRelocationRecord(
      id: id,
      from: from,
      to: to,
      trainingRoot: _trainingRoot,
      snapshot: snapshot,
      training: rows,
      booksBefore: books,
      booksAfter: booksAfter,
      backupByPath: backups,
    );
  }

  String _detail(Object error) => switch (error) {
    RecoveryRequired(:final detail) => detail,
    training.Malformed(:final file, :final line) =>
      'Training file $file is malformed at line $line.',
    training.IoFailure(:final detail) => detail,
    _ => '$error',
  };

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
      final found = notes.where((n) => n.id == operationId).firstOrNull;
      if (found != null && found is! FileRelocationRecord) {
        throw const RecoveryRequired(
          'This relocation id belongs to a folder move.',
        );
      }
      final existing = found as FileRelocationRecord?;
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
      final FileRelocationRecord record;
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

  Moved _result(FileRelocationRecord record) => Moved(
    Revision(record.hash, nativeIdentity: record.identity),
    training: record.training.rowsChanged == 0
        ? const training.NothingToRepoint()
        : training.Repointed(record.training.rowsChanged),
  );

  Future<FileRelocationRecord> _plan(
    String id,
    String from,
    String to,
    FileFound file, {
    required bool keepCurrent,
  }) async {
    await _parents(from, create: false);
    await _parents(to, create: false);
    await requireSameFileSystem(from, to, directory: false);
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
    return FileRelocationRecord(
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
    await flushRecoveryAncestry(
      _folder.path,
      through: _metadataBoundary,
      synchronize: _synchronize,
    );
    await _record(record, RelocationState.prepared, fresh: fresh);
    await testHook?.call(FileRelocationStep.prepared);
    await _keepTraining(record);
    await _preflight(record, allowAfter: false);
    await _record(record, RelocationState.committing);
    await testHook?.call(FileRelocationStep.intent);
  }

  /// Validate every receipt without replay, before choosing recovery order.
  Future<bool> inspect() async {
    _checkRoots();
    try {
      final notes = await _readAll();
      return notes.any(
        (note) =>
            note.state == RelocationState.prepared ||
            note.state == RelocationState.committing,
      );
    } on RecoveryRequired {
      rethrow;
    } on Object catch (error) {
      throw RecoveryRequired('File relocation inspection failed: $error');
    }
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
    final atSource = await _preflight(record, allowAfter: true);
    await _keepTraining(record);
    if (atSource) {
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
    for (final backup in record.backups) {
      await _backups.applyMove(backup);
      await testHook?.call(FileRelocationStep.backups);
    }
    await _record(record, RelocationState.complete);
    await testHook?.call(FileRelocationStep.completed);
  }

  Future<bool> _preflight(
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
    final before = await _namespaceBefore(record, allowAfter: allowAfter);
    if (before) {
      await requireSameFileSystem(
        record.from,
        record.to,
        directory: record is FolderRelocationRecord,
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
    for (final backup in record.backups) {
      await _backups.validateMove(backup, allowAfter: allowAfter);
    }
    return before;
  }

  Future<bool> _namespaceBefore(
    RelocationRecord record, {
    required bool allowAfter,
  }) async {
    if (record is FolderRelocationRecord) {
      final from = await observeDirectory(record.from);
      final to = await observeDirectory(record.to);
      final before =
          from.status == 0 &&
          from.identity == record.identity &&
          to.status == 1;
      final after =
          from.status == 1 && to.status == 0 && to.identity == record.identity;
      if (!before && !(allowAfter && after)) {
        throw const RecoveryRequired(
          'The recorded folder location or identity changed.',
        );
      }
      await record.snapshot.verify(before ? record.from : record.to);
      return before;
    }
    final file = record as FileRelocationRecord;
    final from = await observeFile(file.from);
    final to = await observeFile(file.to);
    bool owns(NativeFileObservation observed) =>
        observed.status == 0 &&
        observed.identity == file.identity &&
        observed.sha256Hex == file.hash;
    final before = owns(from) && to.status == 1;
    final after = from.status == 1 && owns(to);
    if (!before && !(allowAfter && after)) {
      throw const RecoveryRequired(
        'The recorded PGN location or identity changed.',
      );
    }
    return before;
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
    return readRecoveryRecords(
      _folder,
      decode: (value, id) {
        final note = RelocationRecord.fromJson(
          value,
          id: id,
          documents: documents,
        );
        note.validate(documents: documents, support: support);
        return note;
      },
    );
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
    final source = record is FolderRelocationRecord
        ? (await observeDirectory(record.from)).identity
        : (await observeFile(record.from)).identity;
    final targetStatus = record is FolderRelocationRecord
        ? (await observeDirectory(record.to)).status
        : (await observeFile(record.to)).status;
    if (source != record.identity || targetStatus != 1) return;
    for (final (path, identity) in created.reversed) {
      try {
        if ((await observeDirectory(path)).identity != identity) return;
        final directory = Directory(path);
        if (!await directoryEntries(directory, followLinks: false).isEmpty) {
          return;
        }
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
