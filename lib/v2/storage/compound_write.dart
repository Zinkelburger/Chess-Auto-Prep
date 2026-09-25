import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'journal_records.dart';
import 'recovery_quarantine.dart';
import 'atomic_write.dart';
import 'compound_commit.dart';
import 'document_ref.dart';
import 'relocation_notes.dart' show RecoveryRequired;
import 'recovery_files.dart';

enum CompoundWriteStep {
  prepared,
  intent,
  document,
  secondaryDocument,
  books,
  completed,
}

/// One PGN and books, or two PGNs, under locks owned by the caller.
///
/// The edit is written down in `Support/compound-writes/<id>.json` before
/// either file changes, and the record is removed once both have. A process
/// killed in between leaves the record, and the next start finishes it
/// ([recover]). A record that cannot be finished — a participant changed
/// since, or the record is damaged — is set aside and logged rather than
/// blocking every later open and save.
final class CompoundWrites {
  CompoundWrites({
    required Directory documents,
    required Directory support,
    this.testHook,
    this._synchronize = syncDirectory,
  }) : _configuredDocuments = documents,
       _configuredSupport = support,
       documents = canonicalRecoveryRoot(documents),
       support = canonicalRecoveryRoot(support) {
    _metadataBoundary = recoveryMetadataBoundary(this.support);
  }

  final Future<void> Function(String) _synchronize;
  late final String _metadataBoundary;
  final Directory _configuredDocuments;
  final Directory _configuredSupport;
  final Directory documents;
  final Directory support;
  final Future<void> Function(CompoundWriteStep)? testHook;

  // What this process finished, so a retry of the same id — through any store
  // of this profile — is answered without writing again. Retries only come
  // from this process: the caller's retry token is in memory too.
  static final _finished = <String, Map<String, CompoundCommit>>{};
  Map<String, CompoundCommit> get _completed =>
      _finished.putIfAbsent(support.path, () => {});

  // The native identity of what this owner published. Another owner's retry
  // gets content-only revisions, so it never vouches for a file it did not
  // observe being installed.
  final _published = <(String, String?), Revision>{};
  Revision? publishedRevision(String id, {String? path}) =>
      _published[(id, path)];

  Directory get _folder => Directory(p.join(support.path, 'compound-writes'));
  String get _books => p.join(support.path, 'books.json');
  String _path(String id) => p.join(_folder.path, '$id.json');

  Future<CompoundCommit> commit(CompoundCommit command) => _checked(() async {
    _checkRoots();
    return _commit(_canonicalCommand(command, _configuredDocuments));
  });

  void _checkRoots() {
    if (canonicalRecoveryRoot(_configuredDocuments).path != documents.path ||
        canonicalRecoveryRoot(_configuredSupport).path != support.path) {
      throw const RecoveryRequired('The configured profile root changed.');
    }
  }

  CompoundCommit _canonicalCommand(
    CompoundCommit command,
    Directory configured,
  ) {
    String canonical(String path) {
      if (path.contains('\u0000') ||
          !p.isAbsolute(path) ||
          p.normalize(path) != path) {
        throw RecoveryRequired(
          'Compound document is not a managed PGN: $path.',
        );
      }
      final originalRoot = p.normalize(p.absolute(configured.path));
      return p.isWithin(originalRoot, path)
          ? p.join(documents.path, p.relative(path, from: originalRoot))
          : path;
    }

    if (command.secondary case final secondary?) {
      return CompoundCommit.pair(
        id: command.id,
        primary: CompoundDocument(
          path: canonical(command.documentPath),
          before: command.documentBefore,
          after: command.documentAfter,
        ),
        secondary: CompoundDocument(
          path: canonical(secondary.path),
          before: secondary.before,
          after: secondary.after,
        ),
      );
    }
    return CompoundCommit(
      id: command.id,
      documentPath: canonical(command.documentPath),
      documentBefore: command.documentBefore,
      documentAfter: command.documentAfter,
      booksBefore: command.booksBefore,
      booksAfter: command.booksAfter,
    );
  }

  Future<CompoundCommit> _commit(CompoundCommit command) async {
    _validate(command);
    final done = _completed[command.id];
    if (done != null) {
      if (!_same(done, command)) {
        throw RecoveryRequired(
          'Compound id ${command.id} belongs to another command.',
        );
      }
      return done;
    }
    final pending = await _readAll();
    final existing = pending
        .where((note) => note.$2.pending && note.$2.command.id == command.id)
        .firstOrNull;
    if (existing != null && !_same(existing.$2.command, command)) {
      throw RecoveryRequired(
        'Compound id ${command.id} belongs to another command.',
      );
    }
    if (existing != null) {
      await _finish(existing.$2);
      return command;
    }
    await _preflight(command, allowAfter: false);
    await recoveryDirectory(support, create: true);
    await recoveryDirectory(_folder, create: true);
    await flushRecoveryAncestry(
      _folder.path,
      through: _metadataBoundary,
      synchronize: _synchronize,
    );
    await testHook?.call(CompoundWriteStep.prepared);
    final note = _Note(command);
    final path = _path(command.id);
    await discardLeftoverStage(path);
    await createFileExclusively(path, encodeJournal(note.json()));
    await testHook?.call(CompoundWriteStep.intent);
    await _finish(note);
    return command;
  }

  /// Whether an edit a stopped process began is still waiting to finish.
  Future<bool> inspect() => _checked(() async {
    _checkRoots();
    return (await _readAll()).any((note) => note.$2.pending);
  });

  /// Finishes the edits a stopped process began. One that can never be
  /// finished — a file changed since, or the record is damaged — is set aside
  /// and logged; the rest still run.
  Future<void> recover() async {
    _checkRoots();
    for (final (file, note) in await _readAll()) {
      try {
        if (!note.pending) {
          await _forget(file);
          continue;
        }
        await _finish(note);
      } on RecoveryRequired catch (error) {
        await quarantine(support, file, error);
      } on Object catch (error) {
        // Most likely passing (a full disk, a file held open): try again at
        // the next start rather than setting the edit aside.
        log.w('finish the edit recorded at ${file.path}', error);
      }
    }
  }

  /// The edit this process finished under [id], or null.
  Future<CompoundCommit?> completed(String id) async {
    _validateId(id);
    return _completed[id];
  }

  Future<void> _finish(_Note note) async {
    final command = note.command;
    // Check the complete read set before completing any remaining write.
    await _preflight(command, allowAfter: true);
    await _publish(
      command.documentPath,
      command.documentBefore,
      command.documentAfter,
      documentId: command.id,
    );
    await testHook?.call(CompoundWriteStep.document);
    if (command.secondary case final secondary?) {
      await _publish(
        secondary.path,
        secondary.before,
        secondary.after,
        documentId: command.id,
        primary: false,
      );
      await testHook?.call(CompoundWriteStep.secondaryDocument);
    } else {
      await _publish(_books, command.booksBefore, command.booksAfter);
      await testHook?.call(CompoundWriteStep.books);
    }
    _completed[command.id] = command;
    if (_completed.length > _remembered) {
      final oldest = _completed.keys.first;
      _completed.remove(oldest);
      _published.removeWhere((key, _) => key.$1 == oldest);
    }
    await _forget(File(_path(command.id)));
    await testHook?.call(CompoundWriteStep.completed);
  }

  /// Removes a finished edit's journal; the edit itself is on disk.
  Future<void> _forget(File journal) async {
    if (await journal.exists()) await journal.delete();
    await flushRecoveryDirectory(_folder.path, synchronize: _synchronize);
  }

  Future<void> _preflight(
    CompoundCommit command, {
    required bool allowAfter,
  }) async {
    if (!await recoveryDirectory(documents)) {
      throw const RecoveryRequired('The Documents directory is missing.');
    }
    await recoveryDirectory(support);
    for (final document in command.documents) {
      await _documentParents(document.path);
      _expect(
        document.path,
        await recoveryText(document.path),
        document.before,
        allowAfter ? document.after : document.before,
      );
    }
    if (command.secondary == null) {
      _expect(
        _books,
        await recoveryText(_books),
        command.booksBefore,
        allowAfter ? command.booksAfter : command.booksBefore,
      );
    }
  }

  Future<void> _documentParents(String path) async {
    final root = documents.path;
    var parent = root;
    for (final part in p.split(p.relative(p.dirname(path), from: root))) {
      if (part == '.') continue;
      parent = p.join(parent, part);
      if (!await recoveryDirectory(Directory(parent))) {
        throw RecoveryRequired('The document directory is missing: $parent.');
      }
    }
  }

  Future<void> _publish(
    String path,
    String? before,
    String? after, {
    String? documentId,
    bool primary = true,
  }) async {
    final current = await recoveryText(path);
    _expect(path, current, before, after);
    if (current == after) {
      // A prior rename/delete may have landed but lost its directory-flush
      // acknowledgement. Confirm its namespace durability before completing.
      await flushRecoveryDirectory(p.dirname(path));
      return;
    }
    if (after == null) {
      await File(path).delete();
      await flushRecoveryDirectory(p.dirname(path));
      return;
    }
    await discardLeftoverStage(path);
    await replaceFile(
      path,
      utf8.encode(after),
      installed: documentId == null
          ? null
          : (file) {
              final revision = Revision(
                file.sha256Hex!,
                nativeIdentity: file.identity,
              );
              _published[(documentId, path)] = revision;
              if (primary) _published[(documentId, null)] = revision;
            },
    );
  }

  Future<List<(File, _Note)>> _readAll() async {
    if (!await recoveryDirectory(support)) return const [];
    return readJournal(
      _folder,
      decode: (value, id) {
        final note = _decode(id, value);
        _validate(note.command);
        return note;
      },
    );
  }

  void _validate(CompoundCommit command) {
    _validateId(command.id);
    final root = p.normalize(p.absolute(documents.path));
    if (command.secondary case final secondary?
        when p.equals(secondary.path, command.documentPath)) {
      throw const RecoveryRequired(
        'Compound PGN participants must be distinct.',
      );
    }
    for (final document in command.documents) {
      final path = document.path;
      if (path.contains('\u0000') ||
          !p.isAbsolute(path) ||
          p.normalize(path) != path ||
          !p.isWithin(root, path) ||
          p.extension(path).toLowerCase() != '.pgn') {
        throw RecoveryRequired(
          'Compound document is not a managed PGN: $path.',
        );
      }
      _utf8(document.before);
      _utf8(document.after);
    }
    for (final books in [command.booksBefore, command.booksAfter]) {
      if (books == null) continue;
      _utf8(books);
      if (jsonDecode(books) is! Map<String, Object?>) {
        throw const RecoveryRequired('A book snapshot is not a JSON object.');
      }
    }
  }
}

final class _Note {
  _Note(this.command, {this.pending = true});
  final CompoundCommit command;

  /// Earlier builds kept finished and abandoned records too; only a record
  /// that reached `committing` still has anything to publish.
  final bool pending;

  Map<String, Object?> json() => command.secondary != null
      ? {
          'version': 2,
          'id': command.id,
          'state': 'committing',
          'documents': [
            for (final document in command.documents)
              {
                'path': document.path,
                'before': document.before,
                'after': document.after,
              },
          ],
        }
      : {
          'version': 1,
          'id': command.id,
          'state': 'committing',
          'documentPath': command.documentPath,
          'documentBefore': command.documentBefore,
          'documentAfter': command.documentAfter,
          'booksBefore': command.booksBefore,
          'booksAfter': command.booksAfter,
        };
}

_Note _decode(String id, Object? json) {
  if (json is Map<String, Object?> &&
      json['version'] is int &&
      json['version'] == 2) {
    return _decodePair(id, json);
  }
  const fields = {
    'version',
    'id',
    'state',
    'documentPath',
    'documentBefore',
    'documentAfter',
    'booksBefore',
    'booksAfter',
  };
  if (json is! Map<String, Object?> ||
      json.length != fields.length ||
      !json.keys.every(fields.contains) ||
      json['version'] is! int ||
      json['version'] != 1 ||
      json['id'] != id ||
      json['documentPath'] is! String ||
      json['documentBefore'] is! String ||
      json['documentAfter'] is! String ||
      (json['booksBefore'] != null && json['booksBefore'] is! String) ||
      (json['booksAfter'] != null && json['booksAfter'] is! String)) {
    throw RecoveryRequired('Unsupported compound schema in $id.');
  }
  final state = json['state'];
  if (!_states.contains(state)) {
    throw RecoveryRequired('Unsupported compound state in $id.');
  }
  return _Note(
    CompoundCommit(
      id: id,
      documentPath: json['documentPath'] as String,
      documentBefore: json['documentBefore'] as String,
      documentAfter: json['documentAfter'] as String,
      booksBefore: json['booksBefore'] as String?,
      booksAfter: json['booksAfter'] as String?,
    ),
    pending: state == 'committing',
  );
}

_Note _decodePair(String id, Map<String, Object?> json) {
  const fields = {'version', 'id', 'state', 'documents'};
  final entries = json['documents'];
  if (json.length != fields.length ||
      !json.keys.every(fields.contains) ||
      json['id'] != id ||
      entries is! List<Object?> ||
      entries.length != 2) {
    throw RecoveryRequired('Unsupported compound pair schema in $id.');
  }
  CompoundDocument document(Object? entry) {
    if (entry is! Map<String, Object?> ||
        entry.length != 3 ||
        entry['path'] is! String ||
        entry['before'] is! String ||
        entry['after'] is! String) {
      throw RecoveryRequired('Unsupported compound participant in $id.');
    }
    return CompoundDocument(
      path: entry['path'] as String,
      before: entry['before'] as String,
      after: entry['after'] as String,
    );
  }

  final state = json['state'];
  if (!_states.contains(state)) {
    throw RecoveryRequired('Unsupported compound state in $id.');
  }
  return _Note(
    CompoundCommit.pair(
      id: id,
      primary: document(entries[0]),
      secondary: document(entries[1]),
    ),
    pending: state == 'committing',
  );
}

/// How many finished edits a profile remembers for exact retries.
const _remembered = 256;

const _states = {'prepared', 'committing', 'complete', 'cancelled'};

bool _same(CompoundCommit a, CompoundCommit b) =>
    a.id == b.id &&
    a.documentPath == b.documentPath &&
    a.documentBefore == b.documentBefore &&
    a.documentAfter == b.documentAfter &&
    a.booksBefore == b.booksBefore &&
    a.booksAfter == b.booksAfter &&
    a.secondary?.path == b.secondary?.path &&
    a.secondary?.before == b.secondary?.before &&
    a.secondary?.after == b.secondary?.after;

void _validateId(String id) {
  if (RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$').stringMatch(id) != id) {
    throw RecoveryRequired('Unsupported compound id: $id.');
  }
}

void _utf8(String text) {
  if (text.contains('\u0000') ||
      utf8.decode(utf8.encode('x$text')) != 'x$text') {
    throw const RecoveryRequired('A compound snapshot is not safe UTF-8 text.');
  }
}

void _expect(String path, String? current, String? before, String? after) {
  if (current != before && current != after) {
    throw RecoveryRequired('Compound participant changed externally: $path.');
  }
}

Future<T> _checked<T>(Future<T> Function() work) async {
  try {
    return await work();
  } on FileSystemException catch (error) {
    throw RecoveryRequired('Compound persistence failed: $error');
  } on FormatException {
    throw const RecoveryRequired('Compound metadata or snapshot is malformed.');
  } on NativeNameCollision {
    throw const RecoveryRequired(
      'Compound metadata appeared during preparation.',
    );
  }
}
