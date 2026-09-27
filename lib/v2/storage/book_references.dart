import 'dart:convert';

import 'package:path/path.dart' as p;

import 'reference_change.dart';

/// Changes only explicit section selectors in the existing books v1 JSON.
/// Whole-file and folder membership, order, duplicate entries and unknown
/// metadata survive. Validate before returning even when no reference matches:
/// an unreadable source must never become permission to publish over it.
String? renameBookReferences(
  String? original, {
  required String repertoireRoot,
  required List<SectionRename> changes,
}) {
  final value = readBookDocument(original);
  if (value == null) return null;
  final relative = [
    for (final change in changes)
      if (p.isWithin(repertoireRoot, change.path))
        (
          path: _bookPath(repertoireRoot, change.path),
          from: change.from,
          to: change.to,
        ),
  ];
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
  return changed ? jsonEncode(value) : original;
}

/// Relocates explicit file or folder selections without rebuilding the book
/// model. Quarantined paths remain selectors, ready to follow a later restore.
/// The caller supplies canonical absolute paths; no filesystem reads occur.
String? relocateBookReferences(
  String? original, {
  required String repertoireRoot,
  required String from,
  required String to,
  required bool directory,
}) {
  final value = readBookDocument(original);
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
  if (value == null || !fromInside || p.equals(from, to)) return original;
  final before = _bookPath(repertoireRoot, from);
  final after = _bookPath(repertoireRoot, to);
  if (!_relativePath(before) || !_relativePath(after)) {
    throw const FormatException(
      'Book relocation paths must remain valid selectors.',
    );
  }
  String moved(String path) => path == before
      ? after
      : directory && p.posix.isWithin(before, path)
      ? p.posix.join(after, p.posix.relative(path, from: before))
      : path;

  var changed = false;
  for (final book
      in (value['books']! as List<Object?>).cast<Map<String, Object?>>()) {
    // Standalone course PGNs can also be selected as a whole repertoire.
    final folders = _entries(book, 'repertoires');
    for (var i = 0; i < folders.length; i++) {
      final path = folders[i] as String;
      final next = moved(path);
      if (next != path) {
        folders[i] = next;
        changed = true;
      }
    }
    for (final entry in _entries(book, 'chapters')) {
      final chapter = entry as Map<String, Object?>;
      final path = chapter['path'] as String;
      final next = moved(path);
      if (next != path) {
        chapter['path'] = next;
        changed = true;
      }
    }
  }
  return changed ? jsonEncode(value) : original;
}

String _bookPath(String root, String path) =>
    p.posix.joinAll(p.split(p.relative(path, from: root)));

/// Validates the complete known books schema without changing any bytes.
/// Reference transforms and read-only integrity checks share this decoder.
Map<String, Object?>? readBookDocument(String? original) {
  if (original == null) return null;
  final value = jsonDecode(original);
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
      if (!_relativePath(folder))
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
      !_relativePath(value['path']) ||
      (value['section'] != null && value['section'] is! String)) {
    throw const FormatException('Invalid book chapter selector.');
  }
  return value;
}

bool _relativePath(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value != '.' &&
    !value.contains('\\') &&
    !p.posix.isAbsolute(value) &&
    !p.windows.isAbsolute(value) &&
    p.posix.normalize(value) == value &&
    !p.posix.split(value).contains('..');
