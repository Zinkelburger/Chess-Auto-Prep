import 'dart:io';

import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('v2-chapters-');
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> put(String relative, String text) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  test(
    'lists chapter files by repertoire and name, ignoring the rest',
    () async {
      await put('KID/Main.pgn', '*');
      await put('KID/aux.pgn', '*');
      await put('KID/index.json', '{}');
      await put('benko/Main.pgn', '*');
      await put('stray.pgn', '*');
      final listing = await ChapterDirectory(root).list();
      final refs = (listing as Chapters).refs;
      expect(refs.map((r) => '${r.repertoire}/${r.name}'), [
        'benko/Main',
        'KID/aux',
        'KID/Main',
      ]);
      expect(refs.first.path, p.join(root.path, 'benko', 'Main.pgn'));
    },
  );

  test('a missing repertoires folder is an empty library', () async {
    final files = ChapterDirectory(Directory(p.join(root.path, 'none')));
    expect(((await files.list()) as Chapters).refs, isEmpty);
  });
}
