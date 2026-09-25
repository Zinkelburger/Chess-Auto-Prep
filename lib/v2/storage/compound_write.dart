import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import 'atomic_write.dart';
import 'compound_commit.dart';
import 'document_ref.dart';
import 'relocation_notes.dart' show RecoveryRequired;

enum CompoundWriteStep { prepared, intent, document, books, completed }

/// One PGN edit and its book references, under locks owned by the caller.
/// Prepared snapshots alone authorize nothing: durable committing intent is
/// required before publication. Complete receipts remain for exact retries.
final class CompoundWrites {
  CompoundWrites({
    required Directory documents,
    required Directory support,
    this.testHook,
  }) : _configuredDocuments = documents,
       _configuredSupport = support,
       documents = _canonicalRoot(documents),
       support = _canonicalRoot(support);

  final Directory _configuredDocuments;
  final Directory _configuredSupport;
  final Directory documents;
  final Directory support;
  final Future<void> Function(CompoundWriteStep)? testHook;

  // Native receipts exist only for publications observed by this process.
  // A replayed completion never authorizes training against an arbitrary
  // replacement now occupying the path; reopening supplies a new observation.
  final _published = <String, Revision>{};
  Revision? publishedRevision(String id) => _published[id];

  Directory get _folder => Directory(p.join(support.path, 'compound-writes'));
  String get _books => p.join(support.path, 'books.json');
  String _path(String id) => p.join(_folder.path, '$id.json');

  Future<CompoundCommit> commit(CompoundCommit command) => _checked(() async {
    _checkRoots();
    return _commit(_canonicalCommand(command, _configuredDocuments));
  });

  void _checkRoots() {
    if (_canonicalRoot(_configuredDocuments).path != documents.path ||
        _canonicalRoot(_configuredSupport).path != support.path) {
      throw const RecoveryRequired('The configured profile root changed.');
    }
  }

  CompoundCommit _canonicalCommand(
    CompoundCommit command,
    Directory configured,
  ) {
    final path = command.documentPath;
    if (path.contains('\u0000') ||
        !p.isAbsolute(path) ||
        p.normalize(path) != path) {
      throw RecoveryRequired('Compound document is not a managed PGN: $path.');
    }
    final originalRoot = p.normalize(p.absolute(configured.path));
    final canonicalPath = p.isWithin(originalRoot, path)
        ? p.join(documents.path, p.relative(path, from: originalRoot))
        : path;
    return CompoundCommit(
      id: command.id,
      documentPath: canonicalPath,
      documentBefore: command.documentBefore,
      documentAfter: command.documentAfter,
      booksBefore: command.booksBefore,
      booksAfter: command.booksAfter,
    );
  }

  Future<CompoundCommit> _commit(CompoundCommit command) async {
    _validate(command);
    final notes = await _readAll();
    final existing = notes
        .where((note) => note.command.id == command.id)
        .firstOrNull;
    if (existing != null && !_same(existing.command, command)) {
      throw RecoveryRequired(
        'Compound id ${command.id} belongs to another command.',
      );
    }
    await _recover(notes);
    if (existing?.state == _State.complete) return existing!.command;
    // A fresh or cancelled command has not published either participant.
    await _preflight(command, allowAfter: false);
    final note = existing ?? _Note(command, _State.prepared);
    await _directory(support, create: true);
    await _directory(_folder, create: true);
    await _record(note, _State.prepared, fresh: existing == null);
    await testHook?.call(CompoundWriteStep.prepared);
    await _record(note, _State.committing);
    await testHook?.call(CompoundWriteStep.intent);
    await _finish(note);
    return note.command;
  }

  Future<void> recover() => _checked(() async {
    _checkRoots();
    await _recover(await _readAll());
  });

  Future<CompoundCommit?> completed(String id) => _checked(() async {
    _validateId(id);
    _checkRoots();
    final notes = await _readAll();
    for (final note in notes) {
      if (note.command.id == id && note.state == _State.complete) {
        return note.command;
      }
    }
    return null;
  });

  Future<void> _recover(List<_Note> notes) async {
    for (final note in notes) {
      switch (note.state) {
        case _State.prepared:
          await _record(note, _State.cancelled);
        case _State.committing:
          await _finish(note);
        case _State.complete || _State.cancelled:
          break;
      }
    }
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
    await _publish(_books, command.booksBefore, command.booksAfter);
    await testHook?.call(CompoundWriteStep.books);
    await _record(note, _State.complete);
    await testHook?.call(CompoundWriteStep.completed);
  }

  Future<void> _preflight(
    CompoundCommit command, {
    required bool allowAfter,
  }) async {
    if (!await _directory(documents)) {
      throw const RecoveryRequired('The Documents directory is missing.');
    }
    await _directory(support);
    final root = p.normalize(p.absolute(documents.path));
    var parent = root;
    final parts = p.split(
      p.relative(p.dirname(command.documentPath), from: root),
    );
    for (final part in parts) {
      parent = p.join(parent, part);
      if (!await _directory(Directory(parent))) {
        throw RecoveryRequired('The document directory is missing: $parent.');
      }
    }
    final document = await _text(command.documentPath);
    final books = await _text(_books);
    _expect(
      command.documentPath,
      document,
      command.documentBefore,
      allowAfter ? command.documentAfter : command.documentBefore,
    );
    _expect(
      _books,
      books,
      command.booksBefore,
      allowAfter ? command.booksAfter : command.booksBefore,
    );
  }

  Future<void> _publish(
    String path,
    String? before,
    String? after, {
    String? documentId,
  }) async {
    final current = await _text(path);
    _expect(path, current, before, after);
    if (current == after) {
      // A prior rename/delete may have landed but lost its directory-flush
      // acknowledgement. Confirm its namespace durability before completing.
      await _sync(p.dirname(path));
      return;
    }
    if (after == null) {
      await File(path).delete();
      await _sync(p.dirname(path));
      return;
    }
    await _unusedStage(path);
    await replaceFile(
      path,
      utf8.encode(after),
      installed: documentId == null
          ? null
          : (file) => _published[documentId] = Revision(
              file.sha256Hex!,
              nativeIdentity: file.identity,
            ),
    );
  }

  Future<void> _record(_Note note, _State state, {bool fresh = false}) async {
    final path = _path(note.command.id);
    await _unusedStage(path);
    final bytes = utf8.encode(jsonEncode(note.json(state)));
    // The native no-follow reader has this allocation limit. Never publish
    // a journal it could not validate after a restart.
    if (bytes.length > 512 * 1024 * 1024) {
      throw const RecoveryRequired(
        'The compound journal exceeds the native read limit.',
      );
    }
    if (fresh) {
      await createFileExclusively(path, bytes);
    } else {
      await replaceFile(path, bytes);
    }
    note.state = state;
  }

  Future<List<_Note>> _readAll() async {
    if (!await _directory(support) || !await _directory(_folder)) return [];
    final entries = await directoryEntries(
      _folder,
      followLinks: false,
    ).toList();
    entries.sort((a, b) => a.path.compareTo(b.path));
    final notes = <_Note>[];
    for (final entry in entries) {
      if (entry is! File || p.extension(entry.path) != '.json') {
        throw RecoveryRequired(
          'Unsupported compound metadata at ${entry.path}.',
        );
      }
      final id = p.basenameWithoutExtension(entry.path);
      _validateId(id);
      final text = await _text(entry.path);
      if (text == null)
        throw RecoveryRequired('Compound metadata disappeared: $id.');
      final note = _decode(id, jsonDecode(text));
      _validate(note.command);
      notes.add(note);
    }
    return notes;
  }

  void _validate(CompoundCommit command) {
    _validateId(command.id);
    final root = p.normalize(p.absolute(documents.path));
    final path = command.documentPath;
    if (path.contains('\u0000') ||
        !p.isAbsolute(path) ||
        p.normalize(path) != path ||
        !p.isWithin(root, path) ||
        p.extension(path).toLowerCase() != '.pgn') {
      throw RecoveryRequired('Compound document is not a managed PGN: $path.');
    }
    _utf8(command.documentBefore);
    _utf8(command.documentAfter);
    for (final books in [command.booksBefore, command.booksAfter]) {
      if (books == null) continue;
      _utf8(books);
      if (jsonDecode(books) is! Map<String, Object?>) {
        throw const RecoveryRequired('A book snapshot is not a JSON object.');
      }
    }
  }
}

enum _State { prepared, committing, complete, cancelled }

final class _Note {
  _Note(this.command, this.state);
  final CompoundCommit command;
  _State state;

  Map<String, Object?> json(_State phase) => {
    'version': 1,
    'id': command.id,
    'state': phase.name,
    'documentPath': command.documentPath,
    'documentBefore': command.documentBefore,
    'documentAfter': command.documentAfter,
    'booksBefore': command.booksBefore,
    'booksAfter': command.booksAfter,
  };
}

_Note _decode(String id, Object? json) {
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
  final state = _State.values
      .where((state) => state.name == json['state'])
      .firstOrNull;
  if (state == null)
    throw RecoveryRequired('Unsupported compound state in $id.');
  return _Note(
    CompoundCommit(
      id: id,
      documentPath: json['documentPath'] as String,
      documentBefore: json['documentBefore'] as String,
      documentAfter: json['documentAfter'] as String,
      booksBefore: json['booksBefore'] as String?,
      booksAfter: json['booksAfter'] as String?,
    ),
    state,
  );
}

bool _same(CompoundCommit a, CompoundCommit b) =>
    a.id == b.id &&
    a.documentPath == b.documentPath &&
    a.documentBefore == b.documentBefore &&
    a.documentAfter == b.documentAfter &&
    a.booksBefore == b.booksBefore &&
    a.booksAfter == b.booksAfter;

void _validateId(String id) {
  if (RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$').stringMatch(id) != id) {
    throw RecoveryRequired('Unsupported compound id: $id.');
  }
}

void _utf8(String text) {
  if (text.contains('\u0000') || utf8.decode(utf8.encode(text)) != text) {
    throw const RecoveryRequired('A compound snapshot is not safe UTF-8 text.');
  }
}

void _expect(String path, String? current, String? before, String? after) {
  if (current != before && current != after) {
    throw RecoveryRequired('Compound participant changed externally: $path.');
  }
}

Future<String?> _text(String path) async {
  final observed = await observeFile(path);
  if (observed.status == 1) return null;
  if (observed.status != 0) {
    throw RecoveryRequired(
      'Compound file is unreadable or unsupported: $path.',
    );
  }
  return utf8.decode(observed.bytes!);
}

Future<bool> _directory(Directory directory, {bool create = false}) async {
  var observed = await observeDirectory(directory.path);
  if (observed.status == 1) {
    if (!create) return false;
    await directory.create(recursive: true);
    await _sync(p.dirname(directory.path));
    observed = await observeDirectory(directory.path);
  }
  if (observed.status != 0) {
    throw RecoveryRequired(
      'Compound directory is unreadable or unsupported: ${directory.path}.',
    );
  }
  return true;
}

Future<void> _unusedStage(String path) async {
  final stage = await observeFile(temporaryPathFor(path));
  if (stage.status != 1) {
    throw RecoveryRequired('An unverified staged file remains for $path.');
  }
}

Future<void> _sync(String directory) async {
  if (!Platform.isWindows) await syncDirectory(directory);
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

// Pin configured roots before any await. Aliases at construction are trusted;
// later resolutions only detect retargeting. Participants stay no-follow.
// Support can be absent on the first edit, so resolve its nearest existing
// ancestor without creating any directories before command validation.
Directory _canonicalRoot(Directory directory) {
  var current = p.normalize(p.absolute(directory.path));
  final absent = <String>[];
  while (FileSystemEntity.typeSync(current, followLinks: false) ==
      FileSystemEntityType.notFound) {
    absent.add(p.basename(current));
    final parent = p.dirname(current);
    if (parent == current) {
      throw RecoveryRequired(
        'The profile root cannot be resolved: ${directory.path}.',
      );
    }
    current = parent;
  }
  final resolved = Directory(current).resolveSymbolicLinksSync();
  return Directory(p.joinAll([resolved, ...absent.reversed]));
}
