import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../chess/pgn/chapter.dart' show readOffThreadFrom;
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'backups.dart';
import 'document_text.dart';
import 'book_file.dart';
import 'book_references.dart';
import 'compound_commit.dart';
import 'line_progress.dart';
import 'compound_write.dart';
import 'operation_journal.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'edit_scope.dart';
import 'file_relocation.dart';
import 'operation_id.dart';
import 'mutation_guards.dart';
import 'pgn_document_store.dart';
import 'recovery_files.dart';
import 'recovery_gate.dart';
import 'section_reference_check.dart';

/// The documents root as files on disk.
///
/// Every mutation runs under the directory lock the old app also takes, so the
/// two apps cannot write one folder at once, and publishes through the atomic
/// writer, so a reader never sees half a document. Every access first holds
/// the shared recovery domain and settles known relocation notes or refuses.
/// The native probe takes bytes and hash from one open handle.
///
/// What that does and does not promise. Against the old app and against
/// another copy of this one, which take the same lock, a mutation is
/// exclusive and neither side can lose the other's write. Against a program
/// that does not take the lock — a text editor, a sync client — the file is
/// read under the lock and the mutation refuses on any change since the
/// caller's read, but that check and the rename are separate system calls.
/// What is kept in Support before the rename is the version this app read at
/// that check, so every version this app replaces can be had back; a write by
/// a program that took no lock and landed in the moment between the check and
/// the rename is replaced without being reported, and those bytes are in no
/// kept version.
///
/// A save also has to survive the app itself. It says which games it means
/// to change ([EditScope]); before anything is written, the text is compared
/// with the version on disk game by game and a change to any other game
/// stops the write. That comparison, and everything else that touches every
/// byte of the file, runs on another isolate.
///
/// File moves use [FileRelocations] to commit location, training, selectors
/// and backup ownership together, including quarantine delete and restore.
/// Folder moves capture their complete native inventory in the same journal.
final class PgnFileStore implements PgnDocumentStore {
  factory PgnFileStore({
    required Directory documents,
    required Directory support,
    Future<void> Function(CompoundWriteStep)? compoundHook,
    Future<void> Function(FileRelocationStep)? relocationHook,
    Duration recoveryRetry = const Duration(seconds: 30),
    DateTime Function() recoveryClock = DateTime.now,
    Future<void> Function(String) synchronize = syncDirectory,
  }) {
    final backups = BackupArchive(Directory(p.join(support.path, 'backups')));
    final recovery = RecoveryGate(
      documents: documents,
      support: support,
      compoundHook: compoundHook,
      relocationHook: relocationHook,
      retryDelay: recoveryRetry,
      clock: recoveryClock,
    );
    return PgnFileStore._(
      documents,
      backups,
      recovery,
      BookFile(support, recovery: recovery),
      synchronize,
    );
  }

  PgnFileStore._(
    this.documents,
    this._backups,
    this.recovery,
    this.books,
    this._synchronize,
  );

  /// Shared with native listings and progress access for this profile.
  final RecoveryGate recovery;

  /// The raw book snapshot participating in this profile’s structural saves.
  final BookFile books;

  /// The folder every document lives under; a ref outside it is refused.
  final Directory documents;

  final BackupArchive _backups;

  /// Flushes the folder of a plain create or save once its name holds the
  /// new bytes.
  final Future<void> Function(String) _synchronize;

  @override
  Future<DocumentRead> open(DocumentRef ref) =>
      _guard(Reads([ref.path]), () => _open(ref), Unreadable.new);

  /// [action] through the recovery gate as [access], answering [failed]
  /// when it cannot run.
  Future<T> _guard<T>(
    Access access,
    Future<T> Function() action,
    T Function(String) failed,
  ) async {
    try {
      return await recovery.access(access, action, owed: failed);
    } on RecoveryRequired catch (error) {
      return failed(error.detail);
    } on FileSystemException catch (error) {
      return failed(failureDetail(error));
    }
  }

  Future<DocumentRead> _open(DocumentRef ref) async {
    switch (await probeDocument(ref.path)) {
      case FileMissing():
        return const Absent();
      case FileUnreadable(:final detail):
        log.w('open ${ref.path}', detail);
        return Unreadable(detail);
      case FileFound(:final bytes, :final revision):
        switch (await _decoded(bytes)) {
          case PlainText(:final text):
            return Opened(text, revision, readOnly: _outsideRoot(ref));
          case ForeignText(:final text, :final detail):
            log.w('open ${ref.path}', detail);
            return Opened(
              text,
              revision,
              readOnly: _outsideRoot(ref) ?? detail,
            );
          case NotText(:final detail):
            log.w('open ${ref.path}', detail);
            return Unreadable(detail);
        }
    }
  }

  /// Why a file at [ref] opens to read, or null when it may be written.
  ///
  /// Every write keeps the version it replaces under an id made from the
  /// path inside the documents folder, so a file outside it has nowhere for
  /// its versions to go and no write ever reaches it. It is still read: the
  /// viewer opens whatever the user browses to.
  String? _outsideRoot(DocumentRef ref) =>
      documentBackupIdFor(documents, ref) == null
      ? 'it is outside your Documents folder'
      : null;

  @override
  Future<CreateResult> create(DocumentRef ref, String text) async {
    // Before anything reaches the disk: a ref outside the root must not make
    // folders outside the root either.
    if (documentBackupIdFor(documents, ref) == null) {
      return const IoFailure(outsideRoot);
    }
    return _guard(
      // A file here would leave a waiting move nowhere to go.
      Saves([ref.path]),
      () => lockedForRelocation(documents, ref, [folderOf(ref)], () async {
        await folderOf(ref).create(recursive: true);
        return _create(ref, text);
      }, IoFailure.new),
      IoFailure.new,
    );
  }

  Future<CreateResult> _create(DocumentRef ref, String text) async {
    final bytes = await _encoded(text);
    var landed = false;
    try {
      await removeStaleTemporaries(folderOf(ref));
      await createFileExclusively(
        ref.path,
        bytes.bytes,
        installed: () => landed = true,
        synchronize: _synchronize,
      );
    } on NativeNameCollision {
      return const Collision();
    } on Object catch (error) {
      // Only the folder flush is left once the name holds the bytes; see
      // [_replace].
      if (landed) {
        log.w('create ${ref.path}', '$_unflushed: ${failureDetail(error)}');
        return Created(Revision(bytes.hash));
      }
      log.e('create ${ref.path}', error);
      return IoFailure(failureDetail(error));
    }
    return Created(Revision(bytes.hash));
  }

  @override
  Future<SaveResult> save(
    DocumentRef ref,
    String text, {
    required Revision expected,
    required EditScope scope,
  }) async {
    try {
      if (scope is RestoredVersion && scope.inverse?.secondary != null) {
        return await _restorePair(ref, text, expected, scope.inverse!);
      }
      final expectedBooks = scope.references == null
          ? null
          : await books.expectedText();
      return await _guard(
        _compoundId(scope) == null ? Saves([ref.path]) : Records([ref.path]),
        () => lockedForRelocation(
          documents,
          ref,
          [folderOf(ref), if (_compoundId(scope) != null) recovery.support],
          () => _save(ref, text, expected, scope, expectedBooks),
          IoFailure.new,
        ),
        IoFailure.new,
      );
    } on Object catch (error) {
      return IoFailure(failureDetail(error));
    }
  }

  @override
  Future<SaveResult> savePair(
    DocumentEdit primary,
    DocumentEdit secondary, {
    required String operationId,
  }) async {
    if ([primary, secondary].any(
      (edit) =>
          documentBackupIdFor(documents, edit.ref) == null ||
          edit.scope.references != null ||
          (edit.scope is RestoredVersion &&
              (edit.scope as RestoredVersion).inverse != null),
    )) {
      return const SaveRefused('The pair must name two managed PGN edits.');
    }
    try {
      return await _guard(
        // An unfinished pair, perhaps this one, may have published either
        // file: probing now would answer Conflict for an edit still owed.
        Records([primary.ref.path, secondary.ref.path]),
        () => lockedForRelocation(
          documents,
          primary.ref,
          [folderOf(primary.ref), folderOf(secondary.ref), recovery.support],
          () => _savePair(primary, secondary, operationId),
          IoFailure.new,
        ),
        IoFailure.new,
      );
    } on Object catch (error) {
      return IoFailure(failureDetail(error));
    }
  }

  Future<SaveResult> _savePair(
    DocumentEdit primary,
    DocumentEdit secondary,
    String id, {
    List<CompoundTraining>? restoredTraining,
  }) async {
    final edits = [primary, secondary];
    final paths = [for (final edit in edits) await _completedPath(edit.ref)];
    if (p.equals(paths[0], paths[1])) {
      return const SaveRefused('A pair must name two distinct PGN files.');
    }
    final retried = await _retriedPair(edits, paths, id);
    if (retried != null) return retried;
    // Prepare and validate both scopes before preserving either preimage.
    final inputs = <({DocumentEdit edit, FileFound found, String before})>[];
    for (final edit in edits) {
      final observed = await probeDocument(edit.ref.path);
      switch (observed) {
        case FileMissing():
          return const Conflict(null);
        case FileUnreadable(:final detail):
          return IoFailure(detail);
        case FileFound(:final revision, :final bytes):
          if (revision != edit.expected ||
              (edit.expected.nativeIdentity != null &&
                  revision.nativeIdentity != edit.expected.nativeIdentity)) {
            return Conflict(revision);
          }
          final prepared = await _prepared(
            edit.ref.path,
            bytes,
            revision.contentHash,
            edit.text,
            edit.scope,
          );
          switch (prepared) {
            case _NotReplaceable(:final result):
              return result;
            case _OutsideScope(:final detail):
              return SaveRefused(detail);
            case _Unchanged(:final before):
              inputs.add((edit: edit, found: observed, before: before));
            case _Ready(:final before, :final hash, :final undeclared):
              if (undeclared) log.w('save pair ${edit.ref.path}', _undeclared);
              if (edit.scope is RestoredVersion) {
                final refused = await _keptHere(edit.ref, hash);
                if (refused != null) return refused;
              }
              inputs.add((edit: edit, found: observed, before: before));
          }
      }
    }
    final List<CompoundTraining> training;
    try {
      training =
          restoredTraining ??
          (primary.movedLines.isEmpty && primary.foldedLines.isEmpty
              ? const <CompoundTraining>[]
              : await lineProgressPlan(
                  recovery.compounds.documents,
                  from: paths[0],
                  to: paths[1],
                  ids: primary.movedLines,
                  folded: primary.foldedLines,
                  alternateFrom: primary.ref.path,
                  alternateTo: secondary.ref.path,
                ));
    } on FormatException catch (error) {
      return SaveRefused(error.message);
    }
    for (final input in inputs) {
      if (input.before == input.edit.text) continue;
      final failed = await keepReplacedVersion(
        backups: _backups,
        documents: documents,
        ref: input.edit.ref,
        bytes: input.found.bytes,
        hash: input.found.revision.contentHash,
      );
      if (failed != null) return failed;
    }
    final command = CompoundCommit.pair(
      id: id,
      training: training,
      primary: CompoundDocument(
        path: paths[0],
        before: inputs[0].before,
        after: primary.text,
      ),
      secondary: CompoundDocument(
        path: paths[1],
        before: inputs[1].before,
        after: secondary.text,
      ),
    );
    return _committed(
      command,
      beforeRevision: inputs.first.found.revision,
      secondaryRef: secondary.ref,
    );
  }

  Future<SaveResult?> _retriedPair(
    List<DocumentEdit> edits,
    List<String> paths,
    String id,
  ) async {
    final completed = await recovery.compounds.completed(id);
    if (completed != null) {
      final participants = completed.documents;
      if (participants.length != 2 ||
          edits.indexed.any(
            (entry) =>
                participants[entry.$1].path != paths[entry.$1] ||
                participants[entry.$1].after != entry.$2.text ||
                _textRevision(participants[entry.$1].before) !=
                    entry.$2.expected,
          )) {
        return const SaveRefused('The pair id belongs to another edit.');
      }
      return Saved(_compoundReceipt(completed, secondaryRef: edits[1].ref));
    }
    return null;
  }

  Future<SaveResult> _restorePair(
    DocumentRef ref,
    String text,
    Revision expected,
    CompoundCommit inverse,
  ) => _guard(_undoing(ref, inverse), () async {
    final original = await recovery.compounds.completed(inverse.id);
    if (original == null ||
        original.secondary == null ||
        original.documents.length != inverse.documents.length ||
        original.documents.indexed.any(
          (entry) =>
              entry.$2.path != inverse.documents[entry.$1].path ||
              entry.$2.before != inverse.documents[entry.$1].before ||
              entry.$2.after != inverse.documents[entry.$1].after,
        ) ||
        inverse.documentPath != await _completedPath(ref) ||
        inverse.documentBefore != text ||
        _textRevision(inverse.documentAfter) != expected) {
      return const RestoreRefused(
        'The pair inverse is not an edit this session made.',
      );
    }
    final primary = DocumentEdit(
      ref: ref,
      text: text,
      expected: expected,
      scope: const RestoredVersion(),
    );
    final second = inverse.secondary!;
    final secondary = DocumentEdit(
      ref: DocumentRef(
        p.join(
          documents.path,
          p.relative(second.path, from: recovery.compounds.documents.path),
        ),
      ),
      text: second.before,
      expected: _textRevision(second.after),
      scope: const RestoredVersion(),
    );
    // Already inside the recovery domain: acquire participants directly,
    // never recursively enter the public save boundary.
    return lockedForRelocation(
      documents,
      ref,
      [folderOf(ref), folderOf(secondary.ref), recovery.support],
      () => _savePair(
        primary,
        secondary,
        '${inverse.id}-undo',
        restoredTraining: [for (final file in original.training) file.inverse],
      ),
      IoFailure.new,
    );
  }, IoFailure.new);

  /// An undo of the pair [inverse] takes back: both its PGNs.
  Records _undoing(DocumentRef ref, CompoundCommit inverse) => Records([
    ref.path,
    for (final document in inverse.documents) document.path,
  ]);

  Future<SaveResult> _save(
    DocumentRef ref,
    String text,
    Revision expected,
    EditScope scope,
    String? expectedBooks,
  ) async {
    final committed = await _retriedCompound(ref, text, expected, scope);
    if (committed != null) return committed;
    switch (await probeDocument(ref.path)) {
      case FileMissing():
        return const Conflict(null);
      case FileUnreadable(:final detail):
        log.w('save ${ref.path}', detail);
        return IoFailure(detail);
      case FileFound(:final bytes, :final revision):
        if (revision != expected) return Conflict(revision);
        return _replace(ref, text, bytes, revision, scope, expectedBooks);
    }
  }

  Future<SaveResult> _replace(
    DocumentRef ref,
    String text,
    Uint8List current,
    Revision revision,
    EditScope scope,
    String? expectedBooks,
  ) async {
    final prepared = await _prepared(
      ref.path,
      current,
      revision.contentHash,
      text,
      scope,
    );
    switch (prepared) {
      case _NotReplaceable(:final result, :final detail):
        log.w('save ${ref.path}', detail);
        return result;
      case _OutsideScope(:final detail):
        log.e('save ${ref.path}', detail);
        return SaveRefused(detail);
      case _Unchanged(:final before):
        // Nothing to replace, so nothing to keep and nothing to write.
        if (_compoundId(scope) != null) {
          return _compound(ref, before, text, revision, scope, expectedBooks);
        }
        return Saved(_receipt(before, revision, revision));
      case _Ready(:final before, :final bytes, :final hash, :final undeclared):
        if (undeclared) log.w('save ${ref.path}', _undeclared);
        if (scope is RestoredVersion) {
          final refused = await _keptHere(ref, hash);
          if (refused != null) return refused;
        }
        final unkept = _keepsVersion(ref, scope)
            ? await keepReplacedVersion(
                backups: _backups,
                documents: documents,
                ref: ref,
                bytes: current,
                hash: revision.contentHash,
              )
            : null;
        if (unkept != null) return unkept;
        if (_compoundId(scope) != null) {
          return _compound(ref, before, text, revision, scope, expectedBooks);
        }
        Revision? installed;
        try {
          await removeStaleTemporaries(folderOf(ref));
          await replaceFile(
            ref.path,
            bytes,
            installed: (file) {
              installed = Revision(hash, nativeIdentity: file.identity);
            },
            synchronize: _synchronize,
          );
        } on Object catch (error) {
          // The name already holds the new bytes, so only the folder flush
          // failed: some filesystems never offer one. Calling that a failed
          // save would leave the editor holding the old revision, and its
          // next save would be refused as a change on disk.
          if (installed != null) {
            log.w('save ${ref.path}', '$_unflushed: ${failureDetail(error)}');
            return Saved(_receipt(before, revision, installed!));
          }
          log.e('save ${ref.path}', error);
          return IoFailure(failureDetail(error));
        }
        return Saved(_receipt(before, revision, installed!));
    }
  }

  /// Whether a save keeps the version it replaces. Every one does but games
  /// added to the end of the downloaded games cache: the scope check has
  /// already proved each game before them unchanged, the new ones can be
  /// downloaded again, and a copy per download would grow without end.
  bool _keepsVersion(DocumentRef ref, EditScope scope) =>
      !(p.isWithin(p.join(documents.path, 'games_library'), ref.path) &&
          scope is GamesEdited &&
          scope.written.rewritten.isEmpty &&
          scope.written.appended > 0 &&
          scope.references == null);

  String? _compoundId(EditScope scope) =>
      scope.references?.id ??
      (scope is RestoredVersion && scope.inverse != null
          ? '${scope.inverse!.id}-undo'
          : null);

  Future<SaveResult?> _retriedCompound(
    DocumentRef ref,
    String text,
    Revision expected,
    EditScope scope,
  ) async {
    final id = _compoundId(scope);
    if (id == null) return null;
    final done = await recovery.compounds.completed(id);
    if (done == null) return null;
    if (done.documentPath != await _completedPath(ref) ||
        done.documentAfter != text ||
        _textRevision(done.documentBefore) != expected) {
      return const SaveRefused(
        'The compound operation id belongs to another edit.',
      );
    }
    return Saved(_compoundReceipt(done));
  }

  /// A retained receipt identifies the original namespace entry, even after
  /// somebody moves, removes or replaces its leaf. Only the configured root
  /// may be an alias; existing parents within it must still be real folders.
  Future<String> _completedPath(DocumentRef ref) async {
    final path = ref.path;
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        path.contains('\u0000')) {
      throw const RecoveryRequired('The completed document path is invalid.');
    }
    final configured = p.normalize(p.absolute(documents.path));
    final root = await documents.resolveSymbolicLinks();
    final canonical = p.isWithin(configured, path)
        ? p.join(root, p.relative(path, from: configured))
        : path;
    if (!p.isWithin(root, canonical)) throw const RecoveryRequired(outsideRoot);
    var parent = root;
    for (final part in p.split(p.relative(p.dirname(canonical), from: root))) {
      if (part == '.') continue;
      parent = p.join(parent, part);
      final observed = await observeDirectory(parent);
      if (observed.status == 1) break;
      if (observed.status != 0) {
        throw RecoveryRequired(
          'The completed document parent is unreadable or linked: $parent.',
        );
      }
    }
    return canonical;
  }

  Future<SaveResult> _compound(
    DocumentRef ref,
    String before,
    String after,
    Revision beforeRevision,
    EditScope scope,
    String? expectedBooks,
  ) async {
    final inverse = scope is RestoredVersion ? scope.inverse : null;
    if (inverse != null &&
        (inverse.documentPath != await File(ref.path).resolveSymbolicLinks() ||
            inverse.documentBefore != after ||
            inverse.documentAfter != before)) {
      return const RestoreRefused(
        'This inverse belongs to another document version.',
      );
    }
    if (inverse != null) {
      final kept = await recovery.compounds.completed(inverse.id);
      if (kept == null ||
          kept.documentPath != inverse.documentPath ||
          kept.documentBefore != inverse.documentBefore ||
          kept.documentAfter != inverse.documentAfter ||
          kept.booksBefore != inverse.booksBefore ||
          kept.booksAfter != inverse.booksAfter) {
        return const RestoreRefused(
          'The compound inverse is not an edit this session made.',
        );
      }
    }
    final beforeBooks = inverse != null ? inverse.booksAfter : expectedBooks;
    final afterBooks = inverse != null
        ? inverse.booksBefore
        : renameBookReferences(
            beforeBooks,
            repertoireRoot: p.join(documents.path, 'repertoires'),
            changes: scope.references!.changes,
          );
    final command = CompoundCommit(
      id: _compoundId(scope)!,
      documentPath: ref.path,
      documentBefore: before,
      documentAfter: after,
      booksBefore: beforeBooks,
      booksAfter: afterBooks,
    );
    return _committed(command, beforeRevision: beforeRevision);
  }

  /// Commits [command] and answers what it came to as a save.
  Future<SaveResult> _committed(
    CompoundCommit command, {
    required Revision beforeRevision,
    DocumentRef? secondaryRef,
  }) async {
    switch (await recovery.compounds.commit(command)) {
      case Finished():
        // As recorded: under the canonical roots.
        final done = await recovery.compounds.completed(command.id);
        return Saved(
          _compoundReceipt(
            done ?? command,
            beforeRevision: beforeRevision,
            secondaryRef: secondaryRef,
          ),
        );
      case Deferred(:final detail):
        log.w('save ${command.documentPath}', detail);
        return Unfinished(detail);
      case SetAside(:final detail):
        log.w('save ${command.documentPath}', detail);
        return IoFailure(detail);
      case Refused(:final reason):
        log.w('save ${command.documentPath}', reason.detail);
        return IoFailure(reason.detail);
    }
  }

  Receipt _compoundReceipt(
    CompoundCommit command, {
    Revision? beforeRevision,
    DocumentRef? secondaryRef,
  }) => Receipt(
    committed:
        recovery.compounds.publishedRevision(command.id) ??
        _textRevision(command.documentAfter),
    before: command.documentBefore,
    beforeRevision: beforeRevision ?? _textRevision(command.documentBefore),
    compound: command,
    secondaryRef: secondaryRef,
  );

  Revision _textRevision(String text) =>
      Revision(sha256.convert(utf8.encode(text)).toString());

  /// Why [hash] is not a version this store kept for [ref], or null when it
  /// is one.
  ///
  /// A restore is the one write with nothing to compare against, so it is
  /// compared against the archive instead: bytes that hash to no version
  /// kept for this document are not a version being put back, whatever the
  /// caller called them.
  Future<SaveResult?> _keptHere(DocumentRef ref, String hash) async {
    final id = documentBackupIdFor(documents, ref);
    final kept = id == null ? null : await _backups.versionWithHash(id, hash);
    if (kept == null) {
      log.e('restore ${ref.path}', _unkeptVersion);
      return const RestoreRefused(_unkeptVersion);
    }
    log.i('restore ${ref.path} to the version of ${kept.time}');
    return null;
  }

  @override
  Future<MoveResult> rename(
    DocumentRef ref,
    String name, {
    required Revision expected,
    String? operationId,
  }) => move(
    ref,
    DocumentRef(p.join(p.dirname(ref.path), name)),
    expected: expected,
    operationId: operationId,
  );

  @override
  Future<MoveResult> move(
    DocumentRef ref,
    DocumentRef destination, {
    required Revision expected,
    String? operationId,
  }) {
    final id = operationId ?? newOperationId();
    return _guard(
      _relocating([ref.path, destination.path]),
      () => lockedForRelocation(
        documents,
        ref,
        [folderOf(ref), folderOf(destination), recovery.support],
        () => recovery.relocations.move(
          ref,
          destination,
          expected: expected,
          operationId: id,
        ),
        IoFailure.new,
      ),
      IoFailure.new,
    );
  }

  @override
  Future<FolderMoveResult> moveFolder(
    String from,
    String to, {
    String? operationId,
  }) {
    final id = operationId ?? newOperationId();
    return _guard(
      _relocating([from, to]),
      () => lockedForRelocation(
        documents,
        DocumentRef(from),
        [Directory(from), Directory(to), recovery.support],
        () => recovery.relocations.moveFolder(from, to, operationId: id),
        FolderMoveFailed.new,
      ),
      FolderMoveFailed.new,
    );
  }

  @override
  Future<DeleteResult> delete(
    DocumentRef ref, {
    required Revision expected,
    String? operationId,
  }) {
    final id = operationId ?? newOperationId();
    return _guard(
      _relocating([ref.path]),
      () => lockedForRelocation(
        documents,
        ref,
        [folderOf(ref), recovery.support],
        () => recovery.relocations.delete(
          ref,
          expected: expected,
          operationId: id,
        ),
        IoFailure.new,
      ),
      IoFailure.new,
    );
  }

  /// A move of [paths]: the training rows and book selectors that follow
  /// it are planned again when they changed, so they guard nothing.
  Records _relocating(List<String> paths) => Records(paths);

  Receipt _receipt(String before, Revision was, Revision committed) =>
      Receipt(committed: committed, before: before, beforeRevision: was);
}

/// [bytes] as a document. A small file is decoded here; a large one on
/// another isolate, because decoding megabytes is work the screen would
/// otherwise wait for.
Future<DocumentText> _decoded(Uint8List bytes) =>
    bytes.length < readOffThreadFrom
    ? Future.value(readDocumentText(bytes))
    : Isolate.run(() => readDocumentText(bytes));

/// [text] as the bytes a file will hold, and their hash.
Future<({Uint8List bytes, String hash})> _encoded(String text) =>
    text.length < readOffThreadFrom
    ? Future.value(_encode(text))
    : Isolate.run(() => _encode(text));

/// What a save works out before it writes, on another isolate once either
/// side of the comparison is big enough to be worth the trip.
Future<_Prepared> _prepared(
  String documentPath,
  Uint8List current,
  String currentHash,
  String text,
  EditScope scope,
) => current.length < readOffThreadFrom && text.length < readOffThreadFrom
    ? Future.value(_prepare(documentPath, current, currentHash, text, scope))
    : Isolate.run(
        () => _prepare(documentPath, current, currentHash, text, scope),
      );

({Uint8List bytes, String hash}) _encode(String text) {
  final bytes = utf8.encode(text);
  return (bytes: bytes, hash: sha256.convert(bytes).toString());
}

/// Everything a save works out before it touches the disk: whether the
/// current bytes may be replaced at all, whether the new text changes only
/// what the scope declared, and the bytes and hash to write.
sealed class _Prepared {
  const _Prepared();
}

/// The file on disk is not one this app may replace; [result] says so.
final class _NotReplaceable extends _Prepared {
  const _NotReplaceable(this.result, this.detail);

  final SaveResult result;
  final String detail;
}

/// The text would change a game the save did not declare.
final class _OutsideScope extends _Prepared {
  const _OutsideScope(this.detail);

  final String detail;
}

/// The text is already what the file holds.
final class _Unchanged extends _Prepared {
  const _Unchanged(this.before);

  final String before;
}

final class _Ready extends _Prepared {
  const _Ready({
    required this.before,
    required this.bytes,
    required this.hash,
    required this.undeclared,
  });

  /// The text being replaced, as it was read from disk.
  final String before;

  final Uint8List bytes;
  final String hash;

  /// Whether the save replaced the whole document without saying which
  /// game it changed, which is logged so that a writer that does it is
  /// visible.
  final bool undeclared;
}

/// Runs on another isolate: everything about a save that reads every byte.
_Prepared _prepare(
  String documentPath,
  Uint8List current,
  String currentHash,
  String text,
  EditScope scope,
) {
  final read = readDocumentText(current);
  // A document this app cannot read is not one it may replace: a save over
  // a compressed chapter would leave bytes neither app can open.
  if (read case NotText(:final detail)) {
    return _NotReplaceable(IoFailure(detail), detail);
  }
  // Nor one it had to guess at: this writes UTF-8, so putting a Latin-1
  // file back would change every game holding an accented letter.
  if (read case ForeignText(:final detail)) {
    return _NotReplaceable(NotWritable(detail), detail);
  }
  final before = (read as PlainText).text;
  final referenceProblem = sectionReferenceProblem(
    documentPath: documentPath,
    before: before,
    after: text,
    scope: scope,
  );
  if (referenceProblem != null) return _OutsideScope(referenceProblem);
  final encoded = _encode(text);
  if (encoded.hash == currentHash) return _Unchanged(before);
  final outside = changeOutsideScope(
    previous: current,
    next: encoded.bytes,
    scope: scope,
  );
  if (outside != null) return _OutsideScope(outside);
  return _Ready(
    before: before,
    bytes: encoded.bytes,
    hash: encoded.hash,
    undeclared: scope is WholeDocument,
  );
}

const _unkeptVersion =
    'the save said it was putting a kept version back, and these are not the '
    'bytes of any version kept for this document';

const _unflushed = 'published; the folder flush failed';

const _undeclared =
    'the whole document was replaced; the save did not say which game it '
    'changed';
