import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:flutter_test/flutter_test.dart';

Player person(Map<String, Object?> fields) =>
    Player({'id': 'p', 'name': 'Someone', ...fields});

void main() {
  group('a hand-edited record', () {
    test('reads a field of the wrong type as absent and names it', () {
      final odd = person({
        'name': 'Someone',
        'aliases': 'Sam',
        'studies': [
          {'path': '/s/a.pgn', 'chapter': 7},
          3,
          {'path': '/s/b.pgn', 'chapter': 'Main line'},
        ],
        'download': {'max': '200', 'months': 6, 'speeds': 'blitz'},
      });
      expect(odd.strings('aliases'), isEmpty);
      expect(odd.names, ['Someone']);
      expect(odd.studies, [
        (path: '/s/a.pgn', chapter: null, at: 0),
        (path: '/s/b.pgn', chapter: 'Main line', at: 2),
      ]);
      expect(odd.unreadFields, [
        'aliases',
        'studies[0].chapter',
        'studies[1]',
        'download.max',
        'download.speeds',
      ]);
      expect(person({'studies': 'a.pgn'}).studies, isEmpty);
      expect(person({}).unreadFields, isEmpty);
    });

    test('a study link edit keeps every other entry as it was', () {
      final odd = person({
        'studies': [
          {'path': '/s/a.pgn', 'chapter': 7},
          3,
          {'path': '/s/b.pgn'},
        ],
      });
      expect(odd.withoutStudy(odd.studies.last).fields['studies'], [
        {'path': '/s/a.pgn', 'chapter': 7},
        3,
      ]);
      expect(
        person({'studies': 'a.pgn'}).withStudy('/s/c.pgn').fields['studies'],
        [
          'a.pgn',
          {'path': '/s/c.pgn'},
        ],
      );
    });

    test('a group reads a date, rounds or study of the wrong type as '
        'absent', () {
      final group = PlayerGroup({
        'id': 'g',
        'name': 4,
        'date': 20261010,
        'rounds': '5',
        'study': ['x'],
      });
      expect(group.name, '');
      expect(group.date, isNull);
      expect(group.rounds, isNull);
      expect(group.study, '');
      expect(group.unreadFields, ['name', 'date', 'study', 'rounds']);
      final good = PlayerGroup({'id': 'g', 'date': '2026-10-10', 'rounds': 5});
      expect((good.date, good.rounds), ('2026-10-10', 5));
      expect(good.unreadFields, isEmpty);
    });
  });

  group('a pasted roster', () {
    test('reads quoted CSV cells, commas and doubled quotes inside them', () {
      final players = readPlayerList(
        'Name,Rating,USCF ID\n'
        '"Smith, John",1800,12345678\n'
        '\n'
        '"Doe ""JD"" Jane",1500,\n',
      );
      expect(players.map((p) => p.name), ['Smith, John', 'Doe "JD" Jane']);
      expect(players.first.fields['rating'], 1800);
      expect(players.first.text('uscf_id'), '12345678');
    });

    test('reads a Markdown table, its rule line and outer bars left out', () {
      final players = readPlayerList(
        '| Name | Rating |\n|---|---|\n| Alice | 2000 |\n',
      );
      expect(players.single.name, 'Alice');
      expect(players.single.fields['rating'], 2000);
    });

    test('reads tab-separated rows and the column names exports use', () {
      final player = readPlayerList(
        'Player\tUSCF\tLichess\tClub\nBob\t123\tbobby\tCity\n',
      ).single;
      expect(player.name, 'Bob');
      expect(player.text('uscf_id'), '123');
      expect(player.text('lichess'), 'bobby');
      expect(player.fields.containsKey('club'), isFalse);
    });

    test('a quoted cell that ends the line is read', () {
      expect(
        readPlayerList('Name,Notes\nAl,"likes e4"\n').single.text('notes'),
        'likes e4',
      );
    });

    test('an empty first cell of a CSV row keeps its column', () {
      expect(readPlayerList('Rating,Name\n,Bob\n').single.name, 'Bob');
    });

    test('a table with bars only round its headings still reads', () {
      expect(
        readPlayerList('| Name | Rating |\nAlice | 2000\n').single.name,
        'Alice',
      );
    });

    test('passes over cells past the last heading', () {
      final player = readPlayerList('Name,Rating\nCarl,1900,extra\n').single;
      expect(player.name, 'Carl');
      expect(player.fields['rating'], 1900);
    });

    test('needs headings and a Name column', () {
      expect(() => readPlayerList('Name,Rating\n'), throwsFormatException);
      expect(() => readPlayerList('Rating\n1800\n'), throwsFormatException);
    });
  });

  group('two players are the same', () {
    test('by USCF id when both have one, whatever their names', () {
      expect(
        samePlayer(
          person({'name': 'A', 'uscf_id': '1'}),
          person({'name': 'A', 'uscf_id': '2'}),
        ),
        isFalse,
      );
      expect(
        samePlayer(
          person({'name': 'A', 'uscf_id': '1'}),
          person({'name': 'B', 'uscf_id': '1'}),
        ),
        isTrue,
      );
    });

    test('by an account on the same site, in any case', () {
      expect(
        samePlayer(
          person({'id': 'a', 'name': 'A', 'lichess': 'Bobby'}),
          person({'id': 'b', 'name': 'B', 'lichess': 'bobby'}),
        ),
        isTrue,
      );
      expect(
        samePlayer(
          person({'id': 'a', 'name': 'A', 'lichess': 'bobby'}),
          person({'id': 'b', 'name': 'B', 'chesscom': 'bobby'}),
        ),
        isTrue,
        reason: 'the username is one of each player\'s names',
      );
      expect(
        samePlayer(
          person({'id': 'a', 'name': 'A', 'lichess': 'aaa'}),
          person({'id': 'b', 'name': 'B', 'lichess': 'bbb'}),
        ),
        isFalse,
        reason: 'two accounts on one site are two players',
      );
    });

    test('by id, or by a name in any case', () {
      expect(
        samePlayer(
          person({'id': 'x', 'name': 'A'}),
          person({'id': 'x', 'name': 'B'}),
        ),
        isTrue,
      );
      expect(
        samePlayer(
          person({'id': 'x', 'name': 'Ann'}),
          person({'id': 'y', 'name': 'ann'}),
        ),
        isTrue,
      );
      expect(
        samePlayer(
          person({'id': 'x', 'name': 'Ann'}),
          person({'id': 'y', 'name': 'Bo'}),
        ),
        isFalse,
      );
    });
  });

  group('a tournament\'s players', () {
    final group = PlayerGroup.create(
      'Open',
    ).member('a', prepared: true).member('b');

    test('say who is prepared, one by one', () {
      expect(group.prepared('a'), isTrue);
      expect(group.prepared('b'), isFalse);
      expect(group.prepared('c'), isFalse);
    });

    test('change one player and keep the rest', () {
      final changed = group.member('b', prepared: true);
      expect(changed.contains('a'), isTrue);
      expect(changed.prepared('a'), isTrue);
      expect(changed.prepared('b'), isTrue);
      expect(group.member('a', remove: true).contains('b'), isTrue);
    });
  });
}
