import 'dart:io';

import 'package:chess_auto_prep/storage/deleted_chapters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory profile;
  late Directory root;
  setUp(() async {
    profile = await Directory.systemTemp.createTemp('deleted-chapters-');
    root = await Directory(p.join(profile.path, 'repertoires')).create();
  });
  tearDown(() => profile.delete(recursive: true));

  void deleted(String folder, String name) {
    File(p.join(folder, '.cap-pgn-history', '123-abc-$name.pgn'))
      ..createSync(recursive: true)
      ..writeAsStringSync('*');
  }

  Future<List<String>> names() async => [
    for (final chapter in (await listDeleted(root) as DeletedChapters).chapters)
      chapter.name,
  ];

  test(
    'deleted chapters are found in every repertoire and folder below',
    () async {
      deleted(p.join(root.path, 'KID'), 'Main');
      deleted(p.join(root.path, 'KID', 'Sidelines'), 'Fianchetto');
      expect(await names(), unorderedEquals(['Main', 'Fianchetto']));
    },
  );

  test(
    'a linked folder is not walked into, so a link back up cannot loop',
    () async {
      final kid = Directory(p.join(root.path, 'KID'))..createSync();
      deleted(kid.path, 'Main');
      final elsewhere = Directory(p.join(profile.path, 'Elsewhere'))
        ..createSync();
      deleted(elsewhere.path, 'Theirs');
      Link(p.join(root.path, 'Linked')).createSync(elsewhere.path);
      Link(p.join(kid.path, 'Again')).createSync(kid.path);
      expect(await names(), ['Main']);
    },
  );
}
