import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/journal_records.dart';
import 'package:chess_auto_prep/v2/storage/recovery_quarantine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory support;
  late Directory journal;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('journal-records-');
    journal = await Directory(p.join(support.path, 'compound-writes')).create();
  });
  tearDown(() => support.delete(recursive: true));

  Future<List<String>> read() async => [
    for (final (_, id) in await readJournal(
      journal,
      decode: (value, id) {
        if (value is! Map<String, Object?> || value['id'] != id) {
          throw const FormatException('not this record');
        }
        return id;
      },
    ))
      id,
  ];

  Future<List<String>> quarantined() async {
    final folder = Directory(p.join(support.path, quarantineFolder));
    if (!await folder.exists()) return [];
    return [
      await for (final entry in folder.list(recursive: true))
        if (entry is File) p.basename(entry.path),
    ];
  }

  Future<void> write(String name, String text) =>
      File(p.join(journal.path, name)).writeAsString(text);

  test('a missing folder has no records', () async {
    await journal.delete();
    expect(await read(), isEmpty);
  });

  test('whole records are returned in name order', () async {
    await write('b.json', jsonEncode({'id': 'b'}));
    await write('a.json', jsonEncode({'id': 'a'}));
    expect(await read(), ['a', 'b']);
  });

  test('leftovers of a stopped journal write are removed', () async {
    await write('a.json', jsonEncode({'id': 'a'}));
    await write('.a.json.v2-tmp', '{"id": "half');
    await write('.a.json.v2-tmp.previous-12-34', jsonEncode({'id': 'a'}));
    expect(await read(), ['a']);
    expect(
      [await for (final e in journal.list()) p.basename(e.path)],
      ['a.json'],
    );
    expect(await quarantined(), isEmpty);
  });

  test('damaged and unknown entries are set aside, the rest read', () async {
    await write('good.json', jsonEncode({'id': 'good'}));
    await write('torn.json', '{"id": "to');
    await write('other.json', jsonEncode({'id': 'someone-else'}));
    await write('notes.txt', 'hello');
    await Directory(p.join(journal.path, 'folder')).create();
    expect(await read(), ['good']);
    expect(
      [await for (final e in journal.list()) p.basename(e.path)],
      ['good.json'],
    );
    expect(
      await quarantined(),
      containsAll([
        'compound-writes-torn.json',
        'compound-writes-other.json',
        'compound-writes-notes.txt',
      ]),
    );
    // Set-aside bytes are kept whole.
    final torn = await Directory(p.join(support.path, quarantineFolder))
        .list(recursive: true)
        .firstWhere((e) => p.basename(e.path) == 'compound-writes-torn.json');
    expect(await File(torn.path).readAsString(), '{"id": "to');
  });
}
