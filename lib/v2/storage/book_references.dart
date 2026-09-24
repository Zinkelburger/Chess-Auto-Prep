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
  if (original == null) return null;
  final value = jsonDecode(original);
  if (value is! Map<String, Object?> ||
      value['version'] != 1 ||
      value['books'] is! List<Object?> ||
      (value['active'] != null && value['active'] is! String)) {
    throw const FormatException('Unsupported books metadata.');
  }
  final relative = [
    for (final change in changes)
      if (p.isWithin(repertoireRoot, change.path))
        (
          path: p.posix.joinAll(
            p.split(p.relative(change.path, from: repertoireRoot)),
          ),
          from: change.from,
          to: change.to,
        ),
  ];
  var changed = false;
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
