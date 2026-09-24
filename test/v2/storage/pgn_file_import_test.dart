import 'dart:io';

import 'package:chess_auto_prep/v2/storage/pgn_file_import.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/lock_path.dart';

void main() {
  late Directory root;
  late Directory documents;
  late NativePgnFileImport import;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('v2-import-');
    documents = Directory(p.join(root.path, 'Documents'));
    await documents.create();
    import = NativePgnFileImport(
      recovery: RecoveryGate(
        documents: documents,
        support: Directory(p.join(root.path, 'Support')),
      ),
      documents: documents.path,
      into: p.join(documents.path, 'pgn_collections'),
    );
  });

  tearDown(() => root.delete(recursive: true));

  test('a file inside Documents is opened where it is', () async {
    final path = p.join(documents.path, 'repertoires', 'KID', 'Main.pgn');
    final result = await import.insideDocuments(path);
    expect(result, isA<FileToOpen>());
    expect((result as FileToOpen).path, path);
    expect(result.copied, isFalse);
  });

  test(
    'a file outside is copied into pgn_collections and the copy opened',
    () async {
      final downloads = Directory(p.join(root.path, 'Downloads'));
      await downloads.create();
      final source = File(p.join(downloads.path, 'course.pgn'));
      await source.writeAsString('[Event "A"]\n\n1. e4 *\n');
      final result = await import.insideDocuments(source.path) as FileToOpen;
      expect(result.copied, isTrue);
      expect(
        result.path,
        p.join(documents.path, 'pgn_collections', 'course.pgn'),
      );
      expect(
        await File(result.path).readAsString(),
        '[Event "A"]\n\n1. e4 *\n',
      );
      expect(await source.exists(), isTrue, reason: 'the original is left');
    },
  );

  test('a second copy of the same name sits beside the first', () async {
    final source = File(p.join(root.path, 'course.pgn'));
    await source.writeAsString('1. e4 *\n');
    final first = await import.insideDocuments(source.path) as FileToOpen;
    await source.writeAsString('1. d4 *\n');
    final second = await import.insideDocuments(source.path) as FileToOpen;
    expect(p.basename(second.path), 'course (2).pgn');
    expect(await File(first.path).readAsString(), '1. e4 *\n');
    expect(await File(second.path).readAsString(), '1. d4 *\n');
  });

  test('a file that is not there cannot be copied, and says so', () async {
    final result = await import.insideDocuments(p.join(root.path, 'no.pgn'));
    expect(result, isA<ImportFailed>());
  });

  test('a copy waits while another writer holds pgn_collections', () async {
    final source = File(p.join(root.path, 'course.pgn'));
    await source.writeAsString('1. e4 *\n');
    final into = Directory(p.join(documents.path, 'pgn_collections'));
    await into.create();
    // A save of a file already in the folder, by this app or the old one:
    // it sweeps staged copies before writing its own.
    final other = sqlite3.open(await lockPathOf(into));
    other.execute('PRAGMA busy_timeout = 0');
    other.execute('BEGIN IMMEDIATE');
    var done = false;
    final copied = import
        .insideDocuments(source.path)
        .whenComplete(() => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(done, isFalse, reason: 'the other writer still holds the folder');
    expect(await into.list().toList(), isEmpty);
    other
      ..execute('ROLLBACK')
      ..close();
    final result = await copied as FileToOpen;
    expect(await File(result.path).readAsString(), '1. e4 *\n');
  });

  test('a name taken by something that is not a file is passed over', () async {
    final source = File(p.join(root.path, 'course.pgn'));
    await source.writeAsString('1. e4 *\n');
    final into = p.join(documents.path, 'pgn_collections');
    // Not a file, so a look for a file there finds nothing, but the name is
    // still taken when the copy is put in place.
    await Directory(p.join(into, 'course.pgn')).create(recursive: true);
    final result = await import.insideDocuments(source.path) as FileToOpen;
    expect(p.basename(result.path), 'course (2).pgn');
    expect(await File(result.path).readAsString(), '1. e4 *\n');
  });
}
