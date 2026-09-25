import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'backups.dart';
import 'backup_relocation.dart';
import 'book_references.dart';
import 'directory_entries.dart';
import '../diagnostics/log.dart';
import 'journal_records.dart';
import 'recovery_quarantine.dart';
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

/// A file's or folder's location, training rows, book selectors and kept
/// versions change together. The caller holds the profile domain, Documents
/// and Support locks throughout.
///
/// The move is written down in `Support/relocation-writes/<id>.json` before
/// anything changes and removed once everything has. A stopped process leaves
/// the record, and the next start finishes it: training rows and books that
/// changed in the meantime are repointed as they now are. A move that cannot
/// be finished is set aside and logged, never left in the way of other work.
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

  // Moves this process finished, so a retry of the same id — through any
  // store of this profile — is answered without moving again. Retries only
  // come from this process: the caller's retry token is in memory too.
  static final _finished = <String, Map<String, RelocationRecord>>{};
  Map<String, RelocationRecord> get _completed =>
      _finished.putIfAbsent(support.path, () => {});
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
      final existing =
          _completed[operationId] ?? await _pendingRecord(operationId);
      if (existing != null &&
          (existing is! FolderRelocationRecord ||
              existing.from != source ||
              existing.to != target)) {
        throw const RecoveryRequired(
          'This relocation id belongs to another operation.',
        );
      }
      if (_completed.containsKey(operationId)) {
        return _folderResult(existing! as FolderRelocationRecord);
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
      if (existing == null) await _prepare(record);
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
      backups[entry.path] = _backups.planMove(
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
      final found =
          _completed[operationId] ?? await _pendingRecord(operationId);
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
      if (_completed.containsKey(operationId)) return _result(existing!);
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
      if (existing == null) await _prepare(record);
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
    final backup = _backups.planMove(
      fromId: backupId(p.relative(from, from: documents.path)),
      toId: backupId(p.relative(to, from: documents.path)),
      documentPath: to,
      operationId: id,
    );
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

  Future<void> _prepare(RelocationRecord record) async {
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
    await testHook?.call(FileRelocationStep.prepared);
    await _keepTraining(record);
    final path = _path(record.id);
    await discardLeftoverStage(path);
    await createFileExclusively(
      path,
      encodeJournal(record.toJson(RelocationState.committing)),
    );
    await testHook?.call(FileRelocationStep.intent);
  }

  /// Finishes the moves a stopped process began. One that can never be
  /// finished — its file is gone or replaced, or the record is damaged — is
  /// set aside and logged; the rest still run.
  Future<void> recover() async {
    _checkRoots();
    for (final (file, note) in await _readAll()) {
      try {
        if (note.state != RelocationState.committing) {
          // Earlier builds kept finished and abandoned records too.
          await _forget(file);
          continue;
        }
        await _finish(note);
      } on RecoveryRequired catch (error) {
        await quarantine(support, file, error);
      } on Object catch (error) {
        // Most likely passing (a full disk, a file held open): try again at
        // the next start rather than setting the move aside.
        log.w('finish the move recorded at ${file.path}', error);
      }
    }
  }

  Future<RelocationRecord?> _pendingRecord(String id) async {
    for (final (_, note) in await _readAll()) {
      if (note.id == id && note.state == RelocationState.committing) {
        return note;
      }
    }
    return null;
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
    final rows = await _trainingNow(record);
    for (var i = 0; i < rows.length; i++) {
      final file = rows[i];
      await _publish(p.join(documents.path, file.name), file.after);
      await testHook?.call(steps[i]);
    }
    final books = await recoveryText(_books);
    await _publish(
      _books,
      books == record.booksBefore || books == record.booksAfter
          ? record.booksAfter
          : relocateBookReferences(
              books,
              repertoireRoot: p.join(documents.path, 'repertoires'),
              from: record.from,
              to: record.to,
              directory: record is FolderRelocationRecord,
            ),
    );
    await testHook?.call(FileRelocationStep.books);
    for (final backup in record.backups) {
      await _backups.applyMove(backup, documents: documents);
      await testHook?.call(FileRelocationStep.backups);
    }
    _completed[record.id] = record;
    if (_completed.length > 256) _completed.remove(_completed.keys.first);
    await _forget(File(_path(record.id)));
    await testHook?.call(FileRelocationStep.completed);
  }

  /// Removes a finished move's journal; the move itself is on disk.
  Future<void> _forget(File journal) async {
    if (await journal.exists()) await journal.delete();
    await flushRecoveryDirectory(_folder.path, synchronize: _synchronize);
  }

  /// The training rewrite as planned, or planned again from the files as they
  /// are now when somebody trained between the plan and this finish.
  Future<List<training.TrainingRepointFile>> _trainingNow(
    RelocationRecord record,
  ) async {
    var current = true;
    for (final file in record.training.files) {
      final text = await recoveryText(p.join(documents.path, file.name));
      if (text != file.before && text != file.after) current = false;
    }
    if (current) return record.training.files;
    return (await training.TrainingRecords(documents).plan(
      DocumentRef(record.from),
      DocumentRef(record.to),
      alternateFrom: DocumentRef(
        p.join(
          record.trainingRoot,
          p.relative(record.from, from: documents.path),
        ),
      ),
      alternateTo: DocumentRef(
        p.join(
          record.trainingRoot,
          p.relative(record.to, from: documents.path),
        ),
      ),
    )).files;
  }

  /// Before a move starts, its participants must still be what was planned;
  /// when finishing one, only its location has to be recognisable.
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
    if (!allowAfter) {
      for (final file in record.training.files) {
        await _expect(p.join(documents.path, file.name), file.before);
      }
      await _expect(_books, record.booksBefore);
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
      // The whole tree is checked before it moves. Once moved it is the
      // user's again: edits inside it, or a history offered back as a deleted
      // chapter, must not stop the rest of the move from finishing.
      if (before) await record.snapshot.verify(record.from);
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
      if (await recoveryText(path) == null) {
        await discardLeftoverStage(path);
        await createFileExclusively(path, utf8.encode(file.before!));
      }
      await flushRecoveryAncestry(
        folder.path,
        through: documents.path,
        synchronize: _synchronize,
      );
    }
  }

  Future<void> _publish(String path, String? after) async {
    final current = await recoveryText(path);
    if (current == after || after == null) {
      await flushRecoveryDirectory(p.dirname(path), synchronize: _synchronize);
    } else {
      await discardLeftoverStage(path);
      await replaceFile(path, utf8.encode(after));
    }
  }

  Future<void> _expect(String path, String? expected) async {
    if (await recoveryText(path) != expected) {
      throw RecoveryRequired('$path changed while the move was prepared.');
    }
  }

  Future<List<(File, RelocationRecord)>> _readAll() async {
    if (!await recoveryDirectory(support)) return const [];
    return readJournal(
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
