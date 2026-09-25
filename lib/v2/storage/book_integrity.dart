import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../chess/pgn/chapter_sections.dart';
import '../chess/pgn/chapter.dart' show readOffThreadFrom;
import 'atomic_write.dart';
import 'book_list.dart';
import 'book_references.dart';
import 'integrity_report.dart';

/// Book selectors include preserved quarantine targets. Check their actual
/// paths and tagged sections, rather than a catalog that hides deleted files.
Future<List<IntegrityFinding>> inspectBookReferences(
  Directory documents,
  Directory support,
) async {
  final findings = <IntegrityFinding>[];
  final path = p.join(support.path, 'books.json');
  try {
    final stagePath = temporaryPathFor(path);
    final stage = await observeFile(stagePath);
    if (stage.status != 1) {
      return [
        IntegrityFinding(
          stage.status == 0
              ? IntegrityKind.unfinished
              : IntegrityKind.unavailable,
          stagePath,
          'An unverified book publication stage remains. References could not be checked.',
        ),
      ];
    }
    final observed = await observeFile(path);
    if (observed.status == 1) return findings;
    if (observed.status != 0 || observed.bytes == null)
      throw const FormatException('Books are unreadable or linked.');
    final original = utf8.decode(observed.bytes!);
    final text = original.startsWith('\ufeff')
        ? original.substring(1)
        : original;
    final raw = readBookDocument(text)!;
    final books = BookList.decode(text);
    if (raw['active'] != null && books.byId(raw['active'] as String) == null) {
      findings.add(
        IntegrityFinding(
          IntegrityKind.dangling,
          path,
          'The active book no longer exists.',
        ),
      );
    }
    final ids = <String>{};
    final root = p.join(documents.path, 'repertoires');
    for (final book in books.books) {
      if (!ids.add(book.id))
        findings.add(
          IntegrityFinding(
            IntegrityKind.dangling,
            path,
            'Book identity ${book.id} is duplicated.',
          ),
        );
      for (final folder in book.repertoires) {
        findings.addAll(
          await _selector(root, folder, null, book.name, folder: true),
        );
      }
      for (final chapter in book.chapters) {
        findings.addAll(
          await _selector(root, chapter.path, chapter.section, book.name),
        );
      }
    }
  } on Object {
    findings.add(
      IntegrityFinding(
        IntegrityKind.unavailable,
        path,
        'Books could not be checked: the file is unavailable or has an unsupported format.',
      ),
    );
  }
  return findings;
}

Future<List<IntegrityFinding>> _selector(
  String root,
  String relative,
  String? section,
  String book, {
  bool folder = false,
}) async {
  final path = p.joinAll([root, ...p.posix.split(relative)]);
  try {
    final parentsExist = await _parents(root, p.dirname(path));
    final type = parentsExist
        ? await FileSystemEntity.type(path, followLinks: false)
        : FileSystemEntityType.notFound;
    if (type == FileSystemEntityType.notFound) {
      return [
        IntegrityFinding(
          IntegrityKind.dangling,
          path,
          'Book "$book" names a missing ${folder ? 'repertoire' : 'chapter'}.',
        ),
      ];
    }
    if (folder && type == FileSystemEntityType.directory) return [];
    if (type != FileSystemEntityType.file ||
        p.extension(path).toLowerCase() != '.pgn') {
      throw const FormatException(
        'The selected path is linked or is not a PGN.',
      );
    }
    final observed = await observeFile(path);
    if (observed.status != 0 || observed.bytes == null)
      throw const FormatException('The selected PGN is unreadable.');
    if (section != null &&
        !await _hasSection(utf8.decode(observed.bytes!), section)) {
      return [
        IntegrityFinding(
          IntegrityKind.dangling,
          path,
          'Book "$book" names missing section "$section".',
        ),
      ];
    }
    return [];
  } on Object {
    return [
      IntegrityFinding(
        IntegrityKind.unavailable,
        path,
        'Book "$book" could not be checked: its selected path is unavailable, linked or malformed.',
      ),
    ];
  }
}

Future<bool> _parents(String root, String parent) async {
  var current = root;
  for (final component in ['.', ...p.split(p.relative(parent, from: root))]) {
    if (component != '.') current = p.join(current, component);
    final observed = await observeDirectory(current);
    if (observed.status == 1) return false;
    if (observed.status != 0)
      throw const FormatException(
        'A selected parent directory is unavailable or linked.',
      );
  }
  return true;
}

Future<bool> _hasSection(String text, String section) async =>
    text.length >= readOffThreadFrom
    ? Isolate.run(() => sectionsInText(text).contains(section))
    : sectionsInText(text).contains(section);
