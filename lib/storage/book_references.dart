import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'book_list.dart';
import 'operation_journal.dart';
import 'recovery_files.dart';
import 'reference_change.dart';

/// Changes only explicit section selectors in the existing books v1 JSON.
/// Whole-file and folder membership, order, duplicate entries and unknown
/// metadata survive. Validate before returning whenever a change falls under
/// the root, even when no reference matches: an unreadable source must never
/// become permission to publish over it. Changes elsewhere never read it.
String? renameBookReferences(
  String? original, {
  required String repertoireRoot,
  required List<SectionRename> changes,
}) {
  final relative = [
    for (final change in changes)
      if (p.isWithin(repertoireRoot, change.path))
        (
          path: _bookPath(repertoireRoot, change.path),
          from: change.from,
          to: change.to,
        ),
  ];
  if (relative.isEmpty) return original;
  final value = readBookDocument(original);
  if (value == null) return null;
  var changed = false;
  for (final book
      in (value['books']! as List<Object?>).cast<Map<String, Object?>>()) {
    for (final entry in _entries(book, 'chapters')) {
      final chapter = _chapter(entry);
      final before = chapter['section'];
      var section = before;
      for (final change in relative) {
        if (chapter['path'] == change.path && section == change.from) {
          section = change.to;
        }
      }
      if (section != before) {
        chapter['section'] = section;
        changed = true;
      }
    }
  }
  return changed ? _encode(value, like: original!) : original;
}

/// The section renames that turn the books [before] into [after], each
/// chapter selector compared in place: absolute paths under
/// [repertoireRoot], as [renameBookReferences] takes them. Null unless a
/// section of a selector is all that changed, each renamed section of a
/// chapter got one new name, every selector of it was renamed, and no
/// section was renamed to one that was renamed too: then the rename cannot
/// be read back without guessing.
List<SectionRename>? sectionRenamesBetween(
  String? before,
  String? after, {
  required String repertoireRoot,
}) {
  if (before == after) return const [];
  final Map<String, Object?>? was;
  final Map<String, Object?>? now;
  try {
    was = readBookDocument(before);
    now = readBookDocument(after);
  } on FormatException {
    return null;
  }
  if (was == null || now == null) return null;
  final chapters = _chaptersBetween(was, now);
  if (chapters == null) return null;
  final renames = <(String, String), String>{};
  final stayed = <(String, String)>{};
  for (final (path, from, to) in chapters) {
    if (from == to) {
      if (from != null) stayed.add((path, from));
    } else if (from == null ||
        to == null ||
        renames.putIfAbsent((path, from), () => to) != to) {
      return null;
    }
  }
  if (stayed.any(renames.containsKey) ||
      renames.entries.any((e) => renames.containsKey((e.key.$1, e.value)))) {
    return null;
  }
  return [
    for (final MapEntry(key: (path, from), value: to) in renames.entries)
      SectionRename(
        path: p.joinAll([repertoireRoot, ...p.posix.split(path)]),
        from: from,
        to: to,
      ),
  ];
}

/// Every chapter selector of [was] with its section there and in [now],
/// or null when anything else of the two books documents differs.
List<(String, String?, String?)>? _chaptersBetween(
  Map<String, Object?> was,
  Map<String, Object?> now,
) {
  bool same(Map<String, Object?> a, Map<String, Object?> b, String field) =>
      const DeepCollectionEquality().equals(
        {...a}..remove(field),
        {...b}..remove(field),
      );
  final books = (
    was['books']! as List<Object?>,
    now['books']! as List<Object?>,
  );
  if (!same(was, now, 'books') || books.$1.length != books.$2.length) {
    return null;
  }
  final chapters = <(String, String?, String?)>[];
  for (final (i, book) in books.$1.cast<Map<String, Object?>>().indexed) {
    final other = books.$2[i]! as Map<String, Object?>;
    final (a, b) = (_entries(book, 'chapters'), _entries(other, 'chapters'));
    if (!same(book, other, 'chapters') ||
        book.containsKey('chapters') != other.containsKey('chapters') ||
        a.length != b.length) {
      return null;
    }
    for (final (j, entry) in a.cast<Map<String, Object?>>().indexed) {
      final renamed = b[j]! as Map<String, Object?>;
      if (!same(entry, renamed, 'section')) return null;
      chapters.add((
        entry['path']! as String,
        entry['section'] as String?,
        renamed['section'] as String?,
      ));
    }
  }
  return chapters;
}

/// Relocates explicit file or folder selections without rebuilding the book
/// model. Quarantined paths remain selectors, ready to follow a later restore.
/// The caller supplies canonical absolute paths; no filesystem reads occur.
/// Books are read only for a move under the root, and books this build cannot
/// read are refused there, unless [unreadable] is given: it is told why, the
/// selectors it can read in a version 1 list still move, and anything else
/// comes back exactly as it is.
String? relocateBookReferences(
  String? original, {
  required String repertoireRoot,
  required String from,
  required String to,
  required bool directory,
  void Function(FormatException error)? unreadable,
}) {
  for (final path in [repertoireRoot, from, to]) {
    if (!p.isAbsolute(path) || p.normalize(path) != path) {
      throw const FormatException(
        'Book relocation requires canonical absolute paths.',
      );
    }
  }
  if (p.equals(from, repertoireRoot) || p.equals(to, repertoireRoot)) {
    throw const FormatException(
      'The repertoire root cannot be a book selector.',
    );
  }
  final fromInside = p.isWithin(repertoireRoot, from);
  final toInside = p.isWithin(repertoireRoot, to);
  if (fromInside != toInside) {
    throw const FormatException(
      'Book selections cannot move outside the repertoire root.',
    );
  }
  if (original == null || !fromInside || p.equals(from, to)) return original;
  final before = _bookPath(repertoireRoot, from);
  final after = _bookPath(repertoireRoot, to);
  if (!isBookSelector(before) || !isBookSelector(after)) {
    throw const FormatException(
      'Book relocation paths must remain valid selectors.',
    );
  }
  final value = _movable(original, unreadable);
  if (value == null) return original;
  String moved(String path) => path == before
      ? after
      : directory && p.posix.isWithin(before, path)
      ? p.posix.join(after, p.posix.relative(path, from: before))
      : path;

  // Entries this build refuses are never selectors under [before], so they
  // stay exactly as they are while the others follow the move.
  var changed = false;
  for (final book in value['books']! as List<Object?>) {
    if (book is! Map<String, Object?>) continue;
    // Standalone course PGNs can also be selected as a whole repertoire.
    final folders = book['repertoires'];
    if (folders is List<Object?>) {
      for (var i = 0; i < folders.length; i++) {
        final path = folders[i];
        if (!isBookSelector(path)) continue;
        final next = moved(path! as String);
        if (next != path) {
          folders[i] = next;
          changed = true;
        }
      }
    }
    final chapters = book['chapters'];
    if (chapters is List<Object?>) {
      for (final chapter in chapters) {
        if (chapter is! Map<String, Object?>) continue;
        final path = chapter['path'];
        if (!isBookSelector(path)) continue;
        final next = moved(path! as String);
        if (next != path) {
          chapter['path'] = next;
          changed = true;
        }
      }
    }
  }
  return changed ? _encode(value, like: original) : original;
}

/// A move's book selectors in books.json at [path]: as planned while it
/// holds what the plan read or wrote, planned again from what it holds now
/// otherwise. Books this build cannot read never stop a move and are never
/// written: a newer build may own them.
final class BookSelectors implements Reference {
  BookSelectors.moved(
    this.path, {
    required this.before,
    required this.after,
    required this.repertoireRoot,
    required this.from,
    required this.to,
    required this.directory,
    this.written,
    this.synchronize = syncDirectory,
  });

  final String path;
  final String? before;
  final String? after;
  final String repertoireRoot;
  final String from;
  final String to;
  final bool directory;

  /// Told once books.json is written.
  final Future<void> Function()? written;
  final Future<void> Function(String) synchronize;

  @override
  Future<Holds> look() async => await readBooksText(path) == before
      ? const HoldsBefore()
      : HoldsOther('$path changed while the move was prepared.');

  @override
  Future<void> follow() async {
    final books = await readBooksText(path);
    await publishText(
      path,
      books == before || books == after
          ? after
          : moveBookSelectors(
              books,
              path: path,
              repertoireRoot: repertoireRoot,
              from: from,
              to: to,
              directory: directory,
            ),
      synchronize: synchronize,
    );
    await written?.call();
  }
}

/// A section rename's book selectors in books.json at [path]: exactly as
/// recorded while books.json holds what the rename planned from or wrote,
/// renamed again in what it holds now otherwise, by the renames the
/// record's snapshots show ([sectionRenamesBetween]). Books that are not a
/// books document, or a rename the snapshots do not show, are left as they
/// are ([NotFollowed]).
final class RenamedSections implements Reference {
  RenamedSections(
    this.path, {
    required this.before,
    required this.after,
    required this.repertoireRoot,
    this.written,
    this.synchronize = syncDirectory,
  });

  final String path;
  final String? before;
  final String? after;
  final String repertoireRoot;

  /// Told once books.json has followed.
  final Future<void> Function()? written;
  final Future<void> Function(String) synchronize;

  // Whether [look] last found books.json there.
  var _looked = false;

  @override
  Future<Holds> look() async {
    try {
      final books = await recoveryText(path);
      _looked = books != null;
      if (books == before) return const HoldsBefore();
      if (books == after) return const HoldsAfter();
      return HoldsOther('$path changed since the rename was planned.');
    } on FileSystemException catch (error) {
      return CannotTell('$error');
    } on Object catch (error) {
      return HoldsOther(describeFailure(error));
    }
  }

  @override
  Future<void> follow() async {
    final String? books;
    try {
      books = await recoveryText(path);
    } on FormatException {
      throw NotFollowed('$path is not UTF-8 text.');
    } on RecoveryRequired catch (error) {
      throw NotFollowed(error.detail);
    }
    if (books == before || books == after) {
      await publishExactText(
        path,
        current: books,
        after: after,
        synchronize: synchronize,
      );
    } else if (books == null && _looked) {
      // Here a moment ago: it is gone only for now.
      throw FileSystemException('books.json is missing for now', path);
    } else {
      await publishText(path, _renamed(books), synchronize: synchronize);
    }
    await written?.call();
  }

  String _renamed(String? books) {
    final changes = sectionRenamesBetween(
      before,
      after,
      repertoireRoot: repertoireRoot,
    );
    if (changes == null) {
      throw NotFollowed('The renamed sections cannot be read back for $path.');
    }
    final String? renamed;
    try {
      renamed = renameBookReferences(
        books,
        repertoireRoot: repertoireRoot,
        changes: changes,
      );
    } on FormatException catch (error) {
      throw NotFollowed('$path is not a books document: ${error.message}');
    }
    if (renamed == null) throw NotFollowed('$path is gone.');
    return renamed;
  }
}

/// The books.json at [path] as text. Bytes that are not UTF-8 take no part
/// in a move, like a missing file: they read as null and are never written.
Future<String?> readBooksText(String path) async {
  try {
    return await recoveryText(path);
  } on FormatException catch (error) {
    log.w('leave the unreadable $path as it is', error);
    return null;
  }
}

/// [relocateBookReferences] for the books.json at [path], leaving books this
/// build cannot read exactly as they are.
String? moveBookSelectors(
  String? books, {
  required String path,
  required String repertoireRoot,
  required String from,
  required String to,
  required bool directory,
}) => relocateBookReferences(
  books,
  repertoireRoot: repertoireRoot,
  from: from,
  to: to,
  directory: directory,
  unreadable: (error) => log.w('leave the unreadable $path as it is', error),
);

/// The books [original] holds, read strictly unless [unreadable] is given:
/// then a version 1 list with entries this build refuses is still read, and
/// anything else, told to [unreadable], is null.
Map<String, Object?>? _movable(
  String original,
  void Function(FormatException error)? unreadable,
) {
  try {
    return readBookDocument(original);
  } on FormatException catch (error) {
    if (unreadable == null) rethrow;
    unreadable(error);
  }
  try {
    final value = jsonDecode(_unmarked(original));
    if (value is Map<String, Object?> &&
        value['version'] == 1 &&
        value['books'] is List<Object?>) {
      return value;
    }
  } on FormatException {
    // Not JSON at all: left as it is.
  }
  return null;
}

/// [text] without the byte-order mark some editors save books.json after.
String _unmarked(String text) =>
    text.startsWith('\ufeff') ? text.substring(1) : text;

/// [value] encoded after the byte-order mark [like] starts with, if any.
String _encode(Map<String, Object?> value, {required String like}) =>
    '${like.startsWith('\ufeff') ? '\ufeff' : ''}${jsonEncode(value)}';

String _bookPath(String root, String path) =>
    p.posix.joinAll(p.split(p.relative(path, from: root)));

/// Validates the complete known books schema without changing any bytes.
/// Reference transforms and read-only integrity checks share this decoder.
Map<String, Object?>? readBookDocument(String? original) {
  if (original == null) return null;
  final value = jsonDecode(_unmarked(original));
  if (value is! Map<String, Object?> ||
      value['version'] != 1 ||
      value['books'] is! List<Object?> ||
      (value['active'] != null && value['active'] is! String)) {
    throw const FormatException('Unsupported books metadata.');
  }
  for (final book in value['books']! as List<Object?>) {
    if (book is! Map<String, Object?> ||
        book['id'] is! String ||
        book['name'] is! String) {
      throw const FormatException('Invalid book metadata.');
    }
    for (final folder in _entries(book, 'repertoires')) {
      if (!isBookSelector(folder))
        throw const FormatException('Invalid book repertoire path.');
    }
    for (final entry in _entries(book, 'chapters')) {
      _chapter(entry);
    }
  }
  return value;
}

List<Object?> _entries(Map<String, Object?> book, String field) {
  if (!book.containsKey(field)) return const [];
  final entries = book[field];
  if (entries is! List<Object?>) throw FormatException('Invalid book $field.');
  return entries;
}

Map<String, Object?> _chapter(Object? value) {
  if (value is! Map<String, Object?> ||
      !isBookSelector(value['path']) ||
      (value['section'] != null && value['section'] is! String)) {
    throw const FormatException('Invalid book chapter selector.');
  }
  return value;
}
