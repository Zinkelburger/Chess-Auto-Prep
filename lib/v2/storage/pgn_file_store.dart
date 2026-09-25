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
import 'book_file.dart';
import 'book_references.dart';
import 'compound_commit.dart';
import 'compound_write.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'document_relocation.dart';
import 'edit_scope.dart';
import 'file_relocation.dart';
import 'reference_change.dart';
import 'mutation_guards.dart';
import 'pgn_document_store.dart';
import 'relocation_notes.dart';
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
/// [DocumentRelocation] still owns folder moves under the original protocol.
final class PgnFileStore implements PgnDocumentStore {
  factory PgnFileStore({
    required Directory documents,
    required Directory support,
    Future<void> Function(CompoundWriteStep)? compoundHook,
    Future<void> Function(FileRelocationStep)? relocationHook,
  }) {
    final backups = BackupArchive(Directory(p.join(support.path, 'backups')));
    final recovery = RecoveryGate(
      documents: documents,
      support: support,
      compoundHook: compoundHook,
      relocationHook: relocationHook,
    );
    return PgnFileStore._(
      documents,
      backups,
      recovery,
      BookFile(support, recovery: recovery),
      DocumentRelocation(
        documents: documents,
        backups: backups,
        notes: recovery.notes,
      ),
    );
  }

  PgnFileStore._(
    this.documents,
    this._backups,
    this.recovery,
    this.books,
    this._relocation,
  );

  /// Shared with native listings and progress access for this profile.
  final RecoveryGate recovery;

  /// The raw book snapshot participating in this profile’s structural saves.
  final BookFile books;

  /// The folder every document lives under; a ref outside it is refused.
  final Directory documents;

  final BackupArchive _backups;
  final DocumentRelocation _relocation;

  @override
  Future<DocumentRead> open(DocumentRef ref) =>
      _guard(() => _open(ref), Unreadable.new);

  Future<T> _guard<T>(
    Future<T> Function() action,
    T Function(String) failed,
  ) async {
    try {
      return await recovery.run(action);
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
      () => lockedForRelocation(documents, ref, [folderOf(ref)], () async {
        await folderOf(ref).create(recursive: true);
        return _create(ref, text);
      }, IoFailure.new),
      IoFailure.new,
    );
  }

  Future<CreateResult> _create(DocumentRef ref, String text) async {
    final bytes = await _encoded(text);
    try {
      await removeStaleTemporaries(folderOf(ref));
      await createFileExclusively(ref.path, bytes.bytes);
    } on NativeNameCollision {
      return const Collision();
    } on Object catch (error) {
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
      final expectedBooks = scope.references == null
          ? null
          : await books.expectedText();
      return await _guard(
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
        final unkept = await keepReplacedVersion(
          backups: _backups,
          documents: documents,
          ref: ref,
          bytes: current,
          hash: revision.contentHash,
        );
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
          );
        } on Object catch (error) {
          log.e('save ${ref.path}', error);
          return IoFailure(failureDetail(error));
        }
        return Saved(_receipt(before, revision, installed!));
    }
  }

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
          'The compound inverse is not a committed receipt from this profile.',
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
    final committed = await recovery.compounds.commit(command);
    return Saved(_compoundReceipt(committed, beforeRevision: beforeRevision));
  }

  Receipt _compoundReceipt(
    CompoundCommit command, {
    Revision? beforeRevision,
  }) => Receipt(
    committed:
        recovery.compounds.publishedRevision(command.id) ??
        _textRevision(command.documentAfter),
    before: command.documentBefore,
    beforeRevision: beforeRevision ?? _textRevision(command.documentBefore),
    compound: command,
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
    final id = operationId ?? newCompoundId();
    return _guard(
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
  Future<FolderMoveResult> moveFolder(String from, String to) =>
      _guard(() => _relocation.moveFolder(from, to), FolderMoveFailed.new);

  @override
  Future<DeleteResult> delete(
    DocumentRef ref, {
    required Revision expected,
    String? operationId,
  }) {
    final id = operationId ?? newCompoundId();
    return _guard(
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

const _undeclared =
    'the whole document was replaced; the save did not say which game it '
    'changed';

// Reading a file's bytes as a document, or refusing them.
//
// One place, because the store must read a file exactly as it will write it
// back: a byte string this decides is a document is a byte string a save may
// replace.

/// What a file holds: a document, or a reason this app will not treat it as
/// one. Never a document made out of bytes that are not text.
sealed class DocumentText {
  const DocumentText();
}

/// Text this app read as UTF-8, exactly, and may write back as UTF-8.
final class PlainText extends DocumentText {
  const PlainText(this.text);

  final String text;
}

/// Text this app can show and must not write back.
///
/// Reading it took a guess — Latin-1, or UTF-8 with damaged bytes read as
/// U+FFFD — and a save writes UTF-8. Every untouched game holding a
/// non-ASCII character would come out as different bytes, and the store
/// would stop the save with a sentence about a line the user never edited.
/// Saying so when the file opens is the honest answer; the old app converts
/// it.
final class ForeignText extends DocumentText {
  const ForeignText(this.text, this.detail);

  final String text;

  /// For the log and for the user; the widget writes the sentence.
  final String detail;
}

final class NotText extends DocumentText {
  const NotText(this.detail);

  /// For the log and for the user; the widget writes the sentence around it.
  final String detail;
}

/// A gzipped chapter, which the old app writes and reads by the two magic
/// bytes of RFC 1952 rather than by extension.
const _compressed =
    'this chapter is compressed; open and save it in the old app to '
    'store it uncompressed';

const _notText = 'the file is not text';

const _notUtf8 =
    'this file is not UTF-8; open and save it in the old app to convert it, '
    'then edit it here';

/// Control bytes per byte read at which a file stops being text. Tab, line
/// feed and carriage return are text; a stray escape or two in a course
/// export is not enough to refuse the file.
const _controlLimit = 0.01;

/// How much of a file is looked at to decide whether it is text at all.
const _sampled = 8192;

/// Valid non-ASCII characters per stray byte for a file to keep its UTF-8
/// reading. The old app's number, and both apps must read one file the same
/// way.
const _validToStrayRatio = 8;

/// The text in [bytes], read as the old app reads the same files, so every
/// PGN it opens opens here too. Whatever came in, a save writes UTF-8 back.
///
/// Bytes that are not text at all are refused rather than decoded: a
/// gzipped chapter read as Latin-1 would open as mojibake and the first save
/// would replace it with bytes neither app could read.
///
/// Strict UTF-8 opens for editing, with its byte-order mark if it had one.
/// Anything else opens to read, because writing it back would re-encode it.
///
/// A file that fails strict UTF-8 is one of two things. A
/// Latin-1 file fails on its first accented letter and holds no valid
/// multi-byte sequence anywhere, so it is decoded as Latin-1. A UTF-8 file
/// with a few damaged bytes among thousands of good ones — a course export
/// with four control bytes in ten megabytes of curly quotes — keeps its UTF-8
/// reading with the stray bytes as U+FFFD, because reading it as Latin-1
/// would turn every one of those quotes into mojibake.
DocumentText readDocumentText(List<int> bytes) {
  final refusal = _binary(bytes);
  if (refusal != null) return NotText(refusal);
  final strict = _strictUtf8(bytes);
  if (strict != null) return PlainText(strict);
  return ForeignText(_guessed(bytes), _notUtf8);
}

/// The byte-order mark, which `utf8.decode` eats.
///
/// It is three bytes of the file like any other: a document that comes back
/// without them is a document whose first save takes them off disk, and a
/// scoped save comparing headings finds a heading three bytes short of the
/// one it is replacing and stops every write.
const _bom = '\uFEFF';

/// [bytes] as UTF-8 with nothing guessed, or null when they are not.
///
/// The decoder eats exactly one leading mark, so exactly one goes back on
/// whenever the bytes start with one — not only when the decoding came back
/// without one. A file written with two marks is a file with two, and
/// handing it back with one is three bytes a scoped save would find missing
/// from the heading of every game it was not asked to change.
String? _strictUtf8(List<int> bytes) {
  try {
    final text = utf8.decode(bytes);
    final marked =
        bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF;
    return marked ? '$_bom$text' : text;
  } on FormatException {
    return null;
  }
}

/// Why [bytes] are not a text document, or null when they could be one.
String? _binary(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    return _compressed;
  }
  final sample = bytes.length < _sampled ? bytes.length : _sampled;
  var controls = 0;
  for (var i = 0; i < sample; i++) {
    final byte = bytes[i];
    if (byte == 0) return _notText;
    if (byte < 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) controls++;
  }
  return controls > sample * _controlLimit ? _notText : null;
}

String _guessed(List<int> bytes) {
  final tolerant = utf8.decode(bytes, allowMalformed: true);
  var strays = 0;
  var valid = 0;
  for (final unit in tolerant.codeUnits) {
    if (unit == 0xFFFD) {
      strays++;
    } else if (unit > 0x7F) {
      valid++;
    }
  }
  return valid >= strays * _validToStrayRatio ? tolerant : latin1.decode(bytes);
}
