import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/diagnostics/log.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late File people;
  final entries = <LogEntry>[];

  // Two good rows around four the app cannot show: not an object, no ID, a
  // name that is not text, and a second row under an ID already read.
  final bad = <Object?>[
    'not a row',
    {'name': 'No id'},
    {'id': 'p3', 'name': 7},
    {'id': 'p1', 'name': 'Second Ann', 'extra': true},
  ];
  final rows = <Object?>[
    {'id': 'p1', 'name': 'Ann', 'kept_field': 'x'},
    bad[0],
    bad[1],
    {'id': 'p2', 'name': 'Bo'},
    bad[2],
    bad[3],
  ];

  setUp(() async {
    entries.clear();
    log.install(entries.add);
    dir = await Directory.systemTemp.createTemp('player-files-test-');
    people = File(p.join(dir.path, 'people.json'));
    await people.writeAsString(
      jsonEncode({'format': 'chess-auto-prep/people@1', 'people': rows}),
    );
  });

  tearDown(() async {
    log.remove(entries.add);
    await dir.delete(recursive: true);
  });

  List<Object?> onDisk() =>
      (jsonDecode(people.readAsStringSync()) as Map)['people'] as List;

  test('bad rows in people.json leave the good ones readable, say so once '
      'and are logged', () async {
    final read = await PlayerFiles(dir).read();
    expect(read.players.map((player) => player.name), ['Ann', 'Bo']);
    expect(read.players.first.text('kept_field'), 'x');
    expect(read.warnings, [
      '4 players in people.json could not be read. '
          'They are kept in the file as they are.',
    ]);
    final line = entries.singleWhere((e) => e.action == 'read people.json');
    expect(line.level, LogLevel.warning);
    expect('${line.error}', contains('player p1 is listed twice'));
    expect(onDisk(), rows, reason: 'reading changes nothing');
  });

  test('saves, edits and removals keep the bad rows as they were', () async {
    final files = PlayerFiles(dir);
    final read = await files.read();
    final ann = read.players.first;
    final bo = read.players.last;
    final cy = Player.create('Cy');
    await files.savePlayer(cy);
    await files.savePlayer(ann.edited({'notes': 'n'}), expected: ann);
    await files.removePlayer(bo);
    final saved = onDisk();
    for (final row in bad) {
      expect(saved, contains(equals(row)));
    }
    expect(saved.where((row) => row is Map && row['id'] == 'p2'), isEmpty);
    final again = await files.read();
    expect(again.players.map((player) => player.name), ['Ann', 'Cy']);
    expect(again.players.first.text('notes'), 'n');
    expect(again.warnings, hasLength(1));
  });

  test('a people.json that is not JSON keeps its groups readable and is '
      'never written over', () async {
    await people.writeAsString('{not json');
    final groups = Directory(p.join(dir.path, 'tournaments'));
    await groups.create();
    await File(p.join(groups.path, 'open.json')).writeAsString(
      jsonEncode({
        'format': 'chess-auto-prep/tournament@1',
        'id': 'open',
        'name': 'Open',
        'entries': <Object?>[],
      }),
    );
    final files = PlayerFiles(dir);
    final read = await files.read();
    expect(read.players, isEmpty);
    expect(read.groups.single.id, 'open');
    expect(read.warnings.single, startsWith('Could not read people.json'));
    await expectLater(
      files.savePlayer(Player.create('Cy')),
      throwsA(isA<FormatException>()),
    );
    expect(await people.readAsString(), '{not json');
  });

  test('an edit of the first row stays one row', () async {
    final files = PlayerFiles(dir);
    final ann = (await files.read()).players.first;
    await files.savePlayer(ann.edited({'notes': 'n'}), expected: ann);
    expect(
      onDisk().where((row) => row is Map && row['notes'] == 'n'),
      hasLength(1),
    );
  });

  test('one unreadable player is said in the singular', () async {
    await people.writeAsString(
      jsonEncode({
        'format': 'chess-auto-prep/people@1',
        'people': [
          {'id': 'p1', 'name': 'Ann'},
          'not a row',
        ],
      }),
    );
    expect((await PlayerFiles(dir).read()).warnings, [
      '1 player in people.json could not be read. '
          'It is kept in the file as it is.',
    ]);
  });

  test('a people.json that is not an object is refused as a format', () async {
    await people.writeAsString('[]');
    await expectLater(
      PlayerFiles(dir).savePlayer(Player.create('Cy')),
      throwsA(isA<FormatException>()),
    );
    expect(await people.readAsString(), '[]');
  });

  group('groups', () {
    late Directory groups;
    setUp(() async {
      groups = await Directory(p.join(dir.path, 'tournaments')).create();
    });

    Map<String, Object?> open(List<Object?> entries) => {
      'format': 'chess-auto-prep/tournament@1',
      'id': 'open',
      'name': 'Open',
      'entries': entries,
    };

    test('other files beside them are not read as groups', () async {
      await File(p.join(groups.path, 'notes.txt')).writeAsString('hello');
      expect(
        (await PlayerFiles(dir).read()).warnings,
        everyElement(isNot(contains('notes.txt'))),
      );
    });

    test(
      'a member that is not a person ID makes the group unreadable',
      () async {
        await File(p.join(groups.path, 'open.json')).writeAsString(
          jsonEncode(
            open([
              {'person': 7},
            ]),
          ),
        );
        final read = await PlayerFiles(dir).read();
        expect(read.groups, isEmpty);
        expect(read.warnings, contains(startsWith('Could not read open.json')));
      },
    );

    test('a group as it was read is removed into .removed', () async {
      final group = PlayerGroup(open(const []));
      final files = PlayerFiles(dir);
      await files.saveGroup(group);
      await files.removeGroup(group);
      expect(File(p.join(groups.path, 'open.json')).existsSync(), isFalse);
      expect(
        Directory(p.join(dir.path, '.removed')).listSync().single.path,
        endsWith('.json'),
      );
    });
  });

  test('the first player or group saved makes the whole folder', () async {
    final root = Directory(p.join(dir.path, 'prep', 'players'));
    final files = PlayerFiles(root);
    await files.saveGroup(
      PlayerGroup({
        'format': 'chess-auto-prep/tournament@1',
        'id': 'open',
        'name': 'Open',
        'entries': <Object?>[],
      }),
    );
    await PlayerFiles(
      Directory(p.join(dir.path, 'other', 'players')),
    ).savePlayer(Player.create('Cy'));
    expect((await files.read()).groups.single.id, 'open');
    expect(
      (await PlayerFiles(
        Directory(p.join(dir.path, 'other', 'players')),
      ).read()).players.single.name,
      'Cy',
    );
  });
}
