import 'dart:io';

import 'package:chess_auto_prep/v2/storage/pgn_file_import.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late Directory documents;
  late NativePgnFileImport import;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('v2-import-');
    documents = Directory(p.join(root.path, 'Documents'));
    await documents.create();
    import = NativePgnFileImport(
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
}
