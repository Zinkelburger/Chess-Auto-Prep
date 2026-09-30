import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'backups.dart';
import 'backup_relocation.dart';
import 'book_references.dart';
import 'directory_entries.dart';
import 'mutation_guards.dart';
import 'operation_id.dart';
import 'operation_journal.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'directory_snapshot.dart';
import 'pgn_document_store.dart';
import 'recovery_files.dart';
import 'recovery_ledger.dart';
import 'relocation_record.dart';
import 'training_records.dart' as training;
import 'training_rows.dart';

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

/// The step each training file's write is told as.
const _trainingSteps = {
  reviewsFile: FileRelocationStep.reviews,
  streaksFile: FileRelocationStep.streaks,
  historyFile: FileRelocationStep.history,
  attemptsFile: FileRelocationStep.attempts,
};

/// A file's or folder's location, training rows, book selectors and kept
/// versions change together. The caller holds the profile domain, Documents
/// and Support locks throughout.
///
/// The move is written down in `Support/relocation-writes/<id>.json` before
/// anything changes and removed once everything has ([OperationJournal]):
/// the file or folder is its pivot, and the training rows, book selectors
/// and kept versions follow it. A stopped process or a failed step leaves
/// the record, and the next access or start finishes it: training rows and
/// books that changed in the meantime are repointed as they now are. Until
/// then the [RecoveryLedger] owes it. A move that cannot be finished is set
/// aside and logged, never left in the way of other work.
final class FileRelocations {
  FileRelocations({
    required Directory documents,
    required Directory support,
    this.testHook,
    DateTime Function() clock = DateTime.now,
    Future<void> Function(String) synchronize = syncDirectory,
  }) : _synchronize = synchronize,
       _configuredDocuments = documents,
       _configuredSupport = support,
       documents = canonicalRecoveryRoot(documents),
       support = canonicalRecoveryRoot(support) {
    _histories = OwedHistories(
      support: this.support,
      documents: this.documents,
      synchronize: synchronize,
    );
    _journal = OperationJournal(
      name: journal,
      support: this.support,
      decode: _decode,
      participants: _participants,
      steps: (
        prepared: FileRelocationStep.prepared,
        intent: FileRelocationStep.intent,
        completed: FileRelocationStep.completed,
      ),
      prepare: _keepTraining,
      finished: (record) => _moves.add((record.from, record.to)),
      handOver: _oweHistories,
      lock: _locked,
      describe: _detail,
      testHook: testHook == null
          ? null
          : (step) => testHook!(step as FileRelocationStep),
      clock: clock,
      synchronize: synchronize,
    );
  }

  /// The folder under Support the records are written in.
  static const journal = 'relocation-writes';

  final Future<void> Function(String) _synchronize;
  final Directory _configuredDocuments;
  final Directory _configuredSupport;
  final Directory documents;
  final Directory support;
  final Future<void> Function(FileRelocationStep)? testHook;
  late final OperationJournal<RelocationRecord> _journal;
  late final OwedHistories _histories;

  // Every move this process finished, from and to, in order, so a change
  // projected before a move can tell that its chapter's path now names
  // something else, and one accepted before it can follow its chapter.
  static final _moves = <(String, String)>[];

  /// A mark to pass to [movedAwaySince] or [movesSince] later.
  static int get moveMark => _moves.length;

  /// Whether a move after [mark] took the file at canonical [path], or a
  /// folder holding it, away.
  static bool movedAwaySince(int mark, String path) => _moves
      .skip(mark)
      .any((move) => p.equals(move.$1, path) || p.isWithin(move.$1, path));

  /// The moves after [mark], oldest first, as canonical from and to paths.
  /// A delete is a move into the recovery folder.
  static Iterable<(String, String)> movesSince(int mark) => _moves.skip(mark);

  /// Where the file at canonical [path] is after the moves that followed
  /// [mark], or null when none of them took it.
  static String? relocatedSince(int mark, String path) {
    String? relocated;
    for (final (from, to) in movesSince(mark)) {
      relocated = training.movedPath(relocated ?? path, from, to) ?? relocated;
    }
    return relocated;
  }

  BackupArchive get _backups =>
      BackupArchive(Directory(p.join(support.path, 'backups')));
  String get _trainingRoot =>
      p.normalize(p.absolute(_configuredDocuments.path));
  String get _books => p.join(support.path, 'books.json');
  String get _repertoires => p.join(documents.path, 'repertoires');

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
      OperationId(operationId);
      final source = _canonical(from);
      final target = _canonical(to);
      validateFolderRelocationPaths(documents, source, target);
      validateFolderParticipantPaths(documents, support, source, target);
      final prior = await _prior(
        operationId,
        (record) =>
            record is FolderRelocationRecord &&
            record.from == source &&
            record.to == target,
      );
      if (prior != null) return _folderMoved(prior.$1, prior.$2);
      await _parents(documents, source, create: false);
      await _parents(documents, target, create: false);
      final destination = await observeDirectory(target);
      if (destination.status == 0 || (await observeFile(target)).status == 0) {
        return const FolderNameTaken();
      }
      if (destination.status != 1) {
        throw const RecoveryRequired(
          'The destination is unreadable or occupied.',
        );
      }
      if (await _settle(source, target) case final unfinished?) {
        return FolderMoveFailed(_attention('Folder', unfinished.detail));
      }
      final record = await _planFolder(operationId, source, target);
      return _folderMoved(record, await _run(record));
    } on Object catch (error) {
      return FolderMoveFailed(_attention('Folder', _detail(error)));
    }
  }

  FolderMoveResult _folderMoved(
    RelocationRecord record,
    Settlement settlement,
  ) => switch (settlement) {
    Finished() => _folderResult(record as FolderRelocationRecord),
    Deferred(:final detail) => FolderMoveUnfinished(
      _attention('Folder', detail),
    ),
    SetAside(:final detail) => FolderMoveFailed(_attention('Folder', detail)),
    Refused(:final reason) => FolderMoveFailed(
      _attention('Folder', reason.detail),
    ),
  };

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
    final rows = await _planTraining(from, to);
    final books = await readBooksText(_books);
    final booksAfter = _relocateBooks(books, from, to, directory: true);
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

  Future<training.TrainingRepointPlan> _planTraining(String from, String to) {
    DocumentRef under(String path) => DocumentRef(
      p.join(_trainingRoot, p.relative(path, from: documents.path)),
    );
    return training.TrainingRecords(documents).plan(
      DocumentRef(from),
      DocumentRef(to),
      alternateFrom: under(from),
      alternateTo: under(to),
    );
  }

  /// Books this build cannot read are left exactly as they are, never moved
  /// aside or written over (a newer build may own them), and never stop a move.
  String? _relocateBooks(
    String? books,
    String from,
    String to, {
    required bool directory,
  }) => moveBookSelectors(
    books,
    path: _books,
    repertoireRoot: _repertoires,
    from: from,
    to: to,
    directory: directory,
  );

  String _detail(Object error) => switch (error) {
    RecoveryRequired(:final detail) => detail,
    training.Malformed(:final file, :final line) =>
      'Training file $file is malformed at line $line.',
    training.IoFailure(:final detail) => detail,
    _ => '$error',
  };

  String _attention(String what, String detail) =>
      '$what relocation needs attention: $detail';

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
      OperationId(operationId);
      if (keepCurrent) validateDeletionId(operationId);
      final source = _canonical(from.path);
      final target = _canonical(to.path);
      validateRelocationPaths(documents, source, target);
      final kind = keepCurrent
          ? FileRelocationKind.delete
          : FileRelocationKind.move;
      final prior = await _prior(
        operationId,
        (record) =>
            record is FileRelocationRecord &&
            record.kind == kind &&
            record.from == source &&
            record.to == target &&
            record.hash == expected.contentHash &&
            (expected.nativeIdentity == null ||
                record.identity == expected.nativeIdentity),
      );
      if (prior != null) return _moved(prior.$1, prior.$2);
      if (await _settle(source, target) case final unfinished?) {
        return IoFailure(_attention('File', unfinished.detail));
      }
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
      final record = await _plan(
        operationId,
        source,
        target,
        file,
        keepCurrent: keepCurrent,
      );
      return _moved(record, await _run(record));
    } on Object catch (error) {
      return IoFailure(_attention('File', _detail(error)));
    }
  }

  MoveResult _moved(RelocationRecord record, Settlement settlement) =>
      switch (settlement) {
        Finished() => _result(record as FileRelocationRecord),
        Deferred(:final detail) => Unfinished(_attention('File', detail)),
        SetAside(:final detail) => IoFailure(_attention('File', detail)),
        Refused(:final reason) => IoFailure(_attention('File', reason.detail)),
      };

  Moved _result(FileRelocationRecord record) => Moved(
    Revision(record.hash, nativeIdentity: record.identity),
    training: record.training.rowsChanged == 0
        ? const training.NothingToRepoint()
        : training.Repointed(record.training.rowsChanged),
  );

  /// The move the caller asks for again, carried as far as it goes now:
  /// the one [id] names, answered as it finished in this process or
  /// finished now while still recorded; otherwise one still recorded under
  /// another id that [same] recognises, taken over (a retry that lost its
  /// id). Null when there is none; a throw when [id] names another change.
  Future<(RelocationRecord, Settlement)?> _prior(
    String id,
    bool Function(RelocationRecord record) same,
  ) async {
    final named = await _journal.named(id);
    if (named == null) return _journal.adopt(id, same);
    if (!same(named.record)) {
      throw const RecoveryRequired(
        'This relocation id belongs to another move.',
      );
    }
    if (named.done) return (named.record, const Finished());
    return (named.record, await _journal.finish(named.record, setAside: false));
  }

  Future<Settlement> _run(RelocationRecord record) {
    record.validate(documents: documents, support: support);
    return _journal.run(record);
  }

  Future<FileRelocationRecord> _plan(
    String id,
    String from,
    String to,
    FileFound file, {
    required bool keepCurrent,
  }) async {
    await _parents(documents, from, create: false);
    await _parents(documents, to, create: false);
    await requireSameFileSystem(from, to, directory: false);
    final rows = await _planTraining(from, to);
    final books = await readBooksText(_books);
    final booksAfter = _relocateBooks(books, from, to, directory: false);
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

  /// Finishes the moves a stopped process began, and tells the ledger what
  /// each came to. One that can never be finished — its file is gone or
  /// replaced, or the record is damaged — is set aside and logged; the rest
  /// still run. Then the kept versions still owed are moved.
  Future<void> recover() async {
    _checkRoots();
    await _journal.recover();
    await _histories.moveAll();
  }

  /// Stops the owed move [id] guarding its file or folder, once it has
  /// guarded it too long ([OperationJournal.stopGuarding]).
  Future<void> stopGuarding(String id) async {
    _checkRoots();
    await _journal.stopGuarding(id);
  }

  /// [finish] under the locks of the folders [record] changes, as its
  /// command took them, so a writer that takes only a folder's lock, as the
  /// old app's save does, never runs beside it. The Documents root and
  /// Support are the caller's.
  Future<T> _locked<T>(RelocationRecord record, Future<T> Function() action) =>
      lockedForFolders(
        [
          for (final path in [record.from, record.to])
            Directory(
              record is FolderRelocationRecord ? path : p.dirname(path),
            ),
        ],
        held: [documents, support],
        action,
      );

  /// Writes down the kept versions a landed move still owes before saves
  /// over its file or folder may pass: a version a save keeps under the new
  /// id is then the document's own, merged when the history follows, never
  /// displaced as another document's.
  Future<void> _oweHistories(RelocationRecord record) async {
    for (final move in record.backups) {
      if (!await _histories.owe(move)) {
        throw FileSystemException(
          'The kept versions still to move could not be written down.',
          move.documentPath,
        );
      }
    }
  }

  /// Finishes the moves still recorded at or around [source] or [target], so
  /// a new move never plans over one left unfinished: its rows and selectors
  /// would name a path that is gone. One that can never be finished is set
  /// aside; one that fails for now fails this move too.
  Future<Deferred?> _settle(String source, String target) {
    bool overlaps(String path) => [source, target].any(
      (end) =>
          p.equals(end, path) || p.isWithin(end, path) || p.isWithin(path, end),
    );
    return _journal.finishOverlapping(
      (record) => overlaps(record.from) || overlaps(record.to),
    );
  }

  RelocationRecord _decode(Object? value, String id) {
    final record = RelocationRecord.fromJson(
      value,
      id: id,
      documents: documents,
    );
    record.validate(documents: documents, support: support);
    return record;
  }

  /// The file or folder a move renames, then what points at it: its
  /// training rows, its book selectors and its kept versions.
  Participants _participants(
    RelocationRecord record, {
    bool following = false,
  }) {
    Future<void> step(FileRelocationStep step) async => testHook?.call(step);
    return (
      pivots: [
        switch (record) {
          FolderRelocationRecord() => MovedFolder(
            record,
            documents: documents,
            synchronize: _synchronize,
            landed: () => step(FileRelocationStep.document),
          ),
          FileRelocationRecord() => MovedFile(
            record,
            documents: documents,
            synchronize: _synchronize,
            landed: () => step(FileRelocationStep.document),
          ),
        },
      ],
      references: [
        training.TrainingRows.moved(
          documents,
          plan: record.training,
          from: record.from,
          to: record.to,
          trainingRoot: record.trainingRoot,
          written: (name) => step(_trainingSteps[name]!),
          synchronize: _synchronize,
        ),
        BookSelectors.moved(
          _books,
          before: record.booksBefore,
          after: record.booksAfter,
          repertoireRoot: _repertoires,
          from: record.from,
          to: record.to,
          directory: record is FolderRelocationRecord,
          written: () => step(FileRelocationStep.books),
          synchronize: _synchronize,
        ),
        KeptVersions(
          record.backups,
          root: _backups.root,
          documents: documents,
          owed: _histories,
          following: following,
          moved: () => step(FileRelocationStep.backups),
        ),
      ],
    );
  }

  /// Keeps what the training files held before the move replaces them, in
  /// `.cap-reference-history/<id>/`, where the old app keeps them too.
  Future<void> _keepTraining(RelocationRecord record) async {
    final folder = Directory(
      p.join(documents.path, '.cap-reference-history', record.id),
    );
    for (final file in record.training.files.where((f) => f.changed)) {
      final path = p.join(folder.path, file.name);
      await _parents(documents, path, create: true);
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
}

/// The file or folder a relocation renames: at its old name before and its
/// new one after, known by its native identity.
sealed class MovedPath implements Pivot {
  MovedPath(
    this.record, {
    required this.documents,
    required this.synchronize,
    this.landed,
  });

  final RelocationRecord record;

  /// The canonical Documents folder.
  final Directory documents;
  final Future<void> Function(String) synchronize;

  /// Told once the new name is durable.
  final Future<void> Function()? landed;

  bool get _folder => this is MovedFolder;

  @override
  Set<String> get paths => {record.from, record.to};

  @override
  Future<Holds> look() async {
    try {
      if (canonicalRecoveryRoot(Directory(record.trainingRoot)).path !=
          documents.path) {
        return const HoldsOther('The recorded training root alias changed.');
      }
      await _parents(documents, record.from, create: false);
      await _parents(documents, record.to, create: false);
      final holds = await _holds();
      if (holds is! HoldsBefore) return holds;
      try {
        await _verifyBefore();
        await requireSameFileSystem(record.from, record.to, directory: _folder);
      } on FileSystemException catch (error) {
        // Its names show it has not moved; only what it holds is unreadable.
        return CannotTell('$error', unapplied: true);
      }
      return holds;
    } on RecoveryRequired catch (error) {
      return HoldsOther(error.detail);
    } on FileSystemException catch (error) {
      return CannotTell('$error');
    }
  }

  /// Where the name is now, by native identity alone.
  Future<Holds> _holds();

  /// Throws unless what is still at the old name is what was planned.
  Future<void> _verifyBefore() async {}

  Future<({int status, String? identity})> _observe(String path);

  @override
  Future<void> apply() async {
    final created = await _parents(documents, record.to, create: true);
    try {
      await movePathNoReplace(record.from, record.to);
    } on Object catch (error) {
      await _removeEmptyParents(created);
      if (error is NativeNameCollision) {
        throw PivotTaken('${record.to} was taken while the move waited.');
      }
      rethrow;
    }
  }

  /// A folder removed since the move (the old one, emptied by it, say) has
  /// no entry left to make durable: each side flushes from the nearest
  /// folder above it that is still there.
  @override
  Future<void> settle() async {
    for (final path in [record.from, record.to]) {
      await flushRecoveryAncestry(
        _existingAncestor(p.dirname(path), documents.path),
        through: documents.path,
        synchronize: synchronize,
      );
    }
    await landed?.call();
  }

  @override
  Future<bool> putBack() async {
    if (await look() is! HoldsAfter) return false;
    await movePathNoReplace(record.to, record.from);
    await flushRecoveryDirectory(
      p.dirname(record.from),
      synchronize: synchronize,
    );
    await flushRecoveryDirectory(
      p.dirname(record.to),
      synchronize: synchronize,
    );
    return true;
  }

  /// A refused native rename can leave private empty parents. Remove only
  /// directories this attempt created and still owns; intent remains retryable.
  Future<void> _removeEmptyParents(List<(String, String)> created) async {
    final source = (await _observe(record.from)).identity;
    final targetStatus = (await _observe(record.to)).status;
    if (source != record.identity || targetStatus != 1) return;
    for (final (path, identity) in created.reversed) {
      try {
        if ((await observeDirectory(path)).identity != identity) return;
        final directory = Directory(path);
        if (!await directoryEntries(directory, followLinks: false).isEmpty) {
          return;
        }
        await directory.delete();
        await flushRecoveryDirectory(p.dirname(path), synchronize: synchronize);
      } on FileSystemException {
        // Preserve anything now occupied or inaccessible. The original error
        // remains the command's outcome and its committing intent is retained.
        return;
      }
    }
  }
}

/// A PGN a move renames, known by its identity and its bytes.
final class MovedFile extends MovedPath {
  MovedFile(
    FileRelocationRecord super.record, {
    required super.documents,
    required super.synchronize,
    super.landed,
  });

  @override
  Future<({int status, String? identity})> _observe(String path) async {
    final observed = await observeFile(path);
    return (status: observed.status, identity: observed.identity);
  }

  @override
  Future<Holds> _holds() async {
    final file = record as FileRelocationRecord;
    final from = await observeFile(file.from);
    final to = await observeFile(file.to);
    requireObserved(from.status, file.from);
    requireObserved(to.status, file.to);
    bool owns(NativeFileObservation observed) =>
        observed.status == 0 &&
        observed.identity == file.identity &&
        observed.sha256Hex == file.hash;
    if (owns(from) && to.status == 1) return const HoldsBefore();
    if (from.status == 1 && owns(to)) return const HoldsAfter();
    return const HoldsOther('The recorded PGN location or identity changed.');
  }
}

/// A folder a move renames whole. Its whole tree is checked before it
/// moves; once moved it is the user's again, so edits inside it, or a
/// history offered back as a deleted chapter, never stop the rest of the
/// move from finishing.
final class MovedFolder extends MovedPath {
  MovedFolder(
    FolderRelocationRecord super.record, {
    required super.documents,
    required super.synchronize,
    super.landed,
  });

  @override
  Future<({int status, String? identity})> _observe(String path) =>
      observeDirectory(path).then(
        (observed) => (status: observed.status, identity: observed.identity),
      );

  @override
  Future<void> _verifyBefore() =>
      (record as FolderRelocationRecord).snapshot.verify(record.from);

  @override
  Future<Holds> _holds() async {
    final folder = record as FolderRelocationRecord;
    final from = await observeDirectory(folder.from);
    final to = await observeDirectory(folder.to);
    requireObserved(from.status, folder.from);
    requireObserved(to.status, folder.to);
    if (from.status == 0 &&
        from.identity == folder.identity &&
        to.status == 1) {
      return const HoldsBefore();
    }
    if (from.status == 1 && to.status == 0 && to.identity == folder.identity) {
      return const HoldsAfter();
    }
    return const HoldsOther(
      'The recorded folder location or identity changed.',
    );
  }
}

/// [directory], or the nearest folder above it up to [root] that exists.
String _existingAncestor(String directory, String root) {
  var current = directory;
  while (p.isWithin(root, current) &&
      FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.notFound) {
    current = p.dirname(current);
  }
  return current;
}

/// Probe every existing ancestor of [path] under [documents] without
/// following links. Missing parents are allowed while planning and looking,
/// and are created only when [create]; answers those it created.
Future<List<(String, String)>> _parents(
  Directory documents,
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
