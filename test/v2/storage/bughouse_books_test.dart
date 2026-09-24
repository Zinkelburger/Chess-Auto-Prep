import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_books.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// `tools/bughouse_db/schema.py`'s tables.
const _ficsSchema = '''
CREATE TABLE edge(pos INTEGER NOT NULL, move TEXT NOT NULL,
  games INTEGER NOT NULL, team_a INTEGER NOT NULL, team_b INTEGER NOT NULL,
  draws INTEGER NOT NULL, unknown INTEGER NOT NULL, elo_sum INTEGER NOT NULL,
  elo_n INTEGER NOT NULL, max_elo INTEGER NOT NULL,
  last_year INTEGER NOT NULL, top_game INTEGER NOT NULL,
  PRIMARY KEY(pos, move)) WITHOUT ROWID;
CREATE TABLE node(pos INTEGER PRIMARY KEY, games INTEGER NOT NULL,
  team_a INTEGER NOT NULL, team_b INTEGER NOT NULL, draws INTEGER NOT NULL,
  unknown INTEGER NOT NULL, moves INTEGER NOT NULL) WITHOUT ROWID;
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
''';

/// A position the Python tools played, by line, with the key they gave it.
Map<String, Object?> pythonCase(String line) {
  final cases =
      (jsonDecode(
                File(
                  'test/fixtures/v2_bughouse/python_positions.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>)['cases']!
          as List<Object?>;
  return cases.cast<Map<String, Object?>>().firstWhere(
    (c) => c['line'] == line,
  );
}

TablePosition afterLine(String line) {
  var table = TablePosition.initial;
  for (final tag in line.split(' ').where((t) => t.isNotEmpty)) {
    final board = tag.startsWith('A') ? BoardNumber.one : BoardNumber.two;
    final move = table
        .legalMoves(board)
        .firstWhere((m) => m.san == tag.substring(2));
    table = table.play(board, move.uci)!.after;
  }
  return table;
}

void main() {
  late Directory dir;

  setUp(
    () async => dir = await Directory.systemTemp.createTemp('v2-bughouse-'),
  );
  tearDown(() => dir.delete(recursive: true));

  group('the FICS archive', () {
    String ficsBook() {
      final path = p.join(dir.path, 'bughouse_book.db');
      final db = sqlite3.open(path)..execute(_ficsSchema);
      final key = pythonCase('')['key'] as int;
      db.execute('INSERT INTO node VALUES(?, 1240, 600, 500, 40, 100, 2)', [
        key,
      ]);
      db.execute(
        "INSERT INTO edge VALUES(?, 'A:e4', 900, 450, 380, 20, 50, 1800000, 900, 2400, 2020, 7)",
        [key],
      );
      db.execute(
        "INSERT INTO edge VALUES(?, 'B:d4', 300, 150, 120, 20, 10, 0, 0, 0, 2019, 9)",
        [key],
      );
      for (final (k, v) in [
        ('games', '1000000'),
        ('years', '2001,2021,2010'),
        ('max_ply', '12'),
        ('min_games', '3'),
      ]) {
        db.execute('INSERT INTO meta VALUES(?, ?)', [k, v]);
      }
      db.close();
      return path;
    }

    test('lists the continuations, most played first, team results', () async {
      final book = SqliteFicsBook([ficsBook()]);
      expect(await book.available(), isTrue);
      final found = await book.explore(TablePosition.initial) as FicsFound;
      expect(found.archive.years, '2001–2021');
      expect(found.archive.maxPly, 12);
      expect(found.position.games, 1240);
      final e4 = found.position.moves.first;
      expect(
        (e4.board, e4.mover, e4.san, e4.abWins, e4.cdWins),
        (BoardNumber.one, Side.white, 'e4', 450, 380),
      );
      expect(e4.averageElo, 2000);
      expect(found.position.moves.last.averageElo, isNull);
      book.close();
    });

    test('a machine without it has none to offer', () async {
      final book = SqliteFicsBook([p.join(dir.path, 'none.db')]);
      expect(await book.available(), isFalse);
      expect(await book.explore(TablePosition.initial), isA<FicsAbsent>());
    });
  });

  test('BUGHOUSE_DB_HOME alone is looked in when it is set', () {
    expect(
      bughouseBookPlaces(
        'bughouse_book.db',
        environment: {'BUGHOUSE_DB_HOME': '/profile', 'HOME': '/home/me'},
        support: '/support',
      ),
      [p.join('/profile', 'bughouse_book.db')],
    );
    expect(
      bughouseBookPlaces(
        'b.db',
        environment: {'HOME': '/home/me'},
        support: '/support',
      ),
      [
        p.join(
          '/home/me',
          '.local',
          'share',
          'chess-prep',
          'bughouse-db',
          'b.db',
        ),
        p.join('/support', 'b.db'),
      ],
    );
  });
}
