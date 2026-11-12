import 'dart:io';

import 'package:chess_auto_prep/storage/directory_entries.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('directory-entries-');
    Directory(
      p.join(folder.path, 'KID', 'Sidelines'),
    ).createSync(recursive: true);
    File(p.join(folder.path, 'KID', 'Main.pgn')).writeAsStringSync('*');
    Link(p.join(folder.path, 'Linked')).createSync(p.join(folder.path, 'KID'));
  });
  tearDown(() => folder.delete(recursive: true));

  Future<Map<String, Type>> listed({
    bool? recursive,
    bool? followLinks,
  }) async => {
    await for (final entry in directoryEntries(
      folder,
      recursive: recursive ?? false,
      followLinks: followLinks ?? true,
    ))
      p.relative(entry.path, from: folder.path): entry.runtimeType,
  };

  test('lists one level, in the caller\'s spelling, following links', () async {
    final entries = {
      await for (final entry in directoryEntries(folder))
        p.relative(entry.path, from: folder.path): entry is Directory,
    };
    expect(entries, {'KID': true, 'Linked': true});
  });

  test('lists every level when asked, and links as links when told', () async {
    final entries = await listed(recursive: true, followLinks: false);
    expect(entries.keys.toSet(), {
      'KID',
      p.join('KID', 'Sidelines'),
      p.join('KID', 'Main.pgn'),
      'Linked',
    });
    expect(entries['Linked'].toString(), contains('Link'));
  });
}
