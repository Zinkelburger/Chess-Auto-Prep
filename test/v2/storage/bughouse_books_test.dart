import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_books.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// `tools/bughouse_db/hivemind_book.py`'s tables, as it creates them.
const _hivemindSchema = '''
CREATE TABLE position(pos INTEGER PRIMARY KEY, fen TEXT NOT NULL,
  line TEXT NOT NULL, ply INTEGER NOT NULL, priority REAL NOT NULL,
  status TEXT NOT NULL, nodes INTEGER, child_nodes INTEGER, seconds REAL,
  done_at TEXT);
CREATE TABLE pick(pos INTEGER NOT NULL, clock TEXT NOT NULL,
  team TEXT NOT NULL, best TEXT, score REAL, mate INTEGER, pv TEXT,
  offset REAL, PRIMARY KEY(pos, clock, team)) WITHOUT ROWID;
CREATE TABLE move(pos INTEGER NOT NULL, move TEXT NOT NULL,
  seat TEXT NOT NULL, uci TEXT NOT NULL, clock TEXT NOT NULL, score REAL,
  mate INTEGER, pv TEXT, child INTEGER NOT NULL,
  PRIMARY KEY(pos, move, clock)) WITHOUT ROWID;
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
''';

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

  /// A Hivemind book with the Python key for `A:e4` done, two moves on
  /// board 1 scored for even and one for `ahead`, in the old lettering
  /// unless [relabelled].
  String hivemindBook({bool relabelled = false}) {
    final path = p.join(dir.path, 'hivemind_book.db');
    final db = sqlite3.open(path)..execute(_hivemindSchema);
    final key = pythonCase('A:e4')['key'] as int;
    final queued = pythonCase('A:e4 B:d4')['key'] as int;
    db.execute(
      "INSERT INTO position VALUES(?, 'x', 'A:e4', 1, 0, 'done', 1500, 200, 1, '')",
      [key],
    );
    db.execute(
      "INSERT INTO position VALUES(?, 'x', 'A:e4 B:d4', 2, 0, 'queued', NULL, NULL, NULL, NULL)",
      [queued],
    );
    for (final row in [
      ['A:e5', 'C', 'e7e5', 'even', -0.12, null, 'C e5 · A Nf3'],
      ['A:c5', 'C', 'c7c5', 'even', 0.05, null, 'C c5 · A B@c4'],
      ['A:e5', 'C', 'e7e5', 'ahead', 2.3, null, 'C e5 · sit'],
      ['B:e4', 'D', 'e2e4', 'even', null, 4, 'D e4'],
    ]) {
      db.execute('INSERT INTO move VALUES(?, ?, ?, ?, ?, ?, ?, ?, 0)', [
        key,
        ...row,
      ]);
    }
    if (relabelled) db.execute("INSERT INTO meta VALUES('seats', 'AB/CD')");
    db.close();
    return path;
  }

  group('the Hivemind book', () {
    test('finds a position the Python tools stored, by any route', () async {
      final book = SqliteHivemindBook([hivemindBook(relabelled: true)]);
      final found = await book.lookup(afterLine('A:e4')) as HivemindFound;
      final e5 = found.moves[(BoardNumber.one, 'e7e5')]!;
      expect(e5[ClockCase.even]!.score.score, -0.12);
      expect(e5[ClockCase.abMaySit]!.pv, 'C e5 · sit');
      expect(e5[ClockCase.cdMaySit], isNull);
      final e4 = found.moves[(BoardNumber.two, 'e2e4')]![ClockCase.even]!;
      expect(e4.score.mate, 4);
      book.close();
    });

    test('reads a book in the old lettering with B and C swapped', () async {
      final book = SqliteHivemindBook([hivemindBook()]);
      final found = await book.lookup(afterLine('A:e4')) as HivemindFound;
      expect(
        found.moves[(BoardNumber.one, 'e7e5')]![ClockCase.even]!.pv,
        'B e5 · A Nf3',
      );
      // The B of a bishop drop is a piece, not a seat.
      expect(
        found.moves[(BoardNumber.one, 'c7c5')]![ClockCase.even]!.pv,
        'B c5 · A B@c4',
      );
      book.close();
    });

    test('a queued or unknown position is a miss', () async {
      final book = SqliteHivemindBook([hivemindBook()]);
      expect(
        await book.lookup(afterLine('A:e4 B:d4')),
        isA<HivemindNotFound>(),
      );
      expect(await book.lookup(TablePosition.initial), isA<HivemindNotFound>());
      book.close();
    });

    test('no file is absent; a damaged one is unreadable', () async {
      final missing = SqliteHivemindBook([p.join(dir.path, 'none.db')]);
      expect(
        await missing.lookup(TablePosition.initial),
        isA<HivemindAbsent>(),
      );
      final junk = p.join(dir.path, 'junk.db');
      await File(junk).writeAsString('not a database at all, ' * 100);
      final damaged = SqliteHivemindBook([junk]);
      expect(
        await damaged.lookup(TablePosition.initial),
        isA<HivemindUnreadable>(),
      );
      damaged.close();
    });

    HivemindEntry entry(TablePosition position, ClockCase clock) => (
      position: position,
      line: 'A:e4',
      ply: 1,
      clock: clock,
      picks: {
        Team.cd: (
          best: 'C e5',
          score: const TableScore(score: -0.2),
          pv: 'C e5 · A Nf3',
          offset: 0.5,
        ),
      },
      moves: {
        (BoardNumber.one, 'e7e5'): (
          score: const TableScore(score: -0.2),
          pv: 'C e5 · A Nf3',
        ),
        (BoardNumber.two, 'e2e4'): (
          score: const TableScore(mate: 3),
          pv: 'D e4',
        ),
      },
      nodes: 1500,
      childNodes: 200,
      took: const Duration(seconds: 3),
    );

    test('a blocked destination reports a failed save', () async {
      final blocked = p.join(dir.path, 'blocked');
      await File(blocked).writeAsString('not a directory');
      final book = SqliteHivemindBook([p.join(blocked, 'book.db')]);
      final outcome = await book.save(entry(afterLine('A:e4'), ClockCase.even));
      expect(outcome, isA<HivemindSaveFailed>());
      book.close();
    });

    test('takes a clock the engine scored, beside the builder’s', () async {
      final book = SqliteHivemindBook([hivemindBook(relabelled: true)]);
      await book.lookup(afterLine('A:e4'));
      await book.save(entry(afterLine('A:e4'), ClockCase.cdMaySit));
      final found = await book.lookup(afterLine('A:e4')) as HivemindFound;
      final e5 = found.moves[(BoardNumber.one, 'e7e5')]!;
      expect(e5[ClockCase.even]!.score.score, -0.12);
      expect(e5[ClockCase.cdMaySit]!.pv, 'C e5 · A Nf3');
      expect(
        found.moves[(BoardNumber.two, 'e2e4')]![ClockCase.cdMaySit]!.score.mate,
        3,
      );
      book.close();
    });

    test(
      'writes legacy labels into legacy books without mixing conventions',
      () async {
        final path = hivemindBook();
        final book = SqliteHivemindBook([path]);
        await book.save(entry(afterLine('A:e4'), ClockCase.cdMaySit));
        final found = await book.lookup(afterLine('A:e4')) as HivemindFound;
        final e5 = found.moves[(BoardNumber.one, 'e7e5')]!;
        expect(e5[ClockCase.even]!.pv, 'B e5 · A Nf3');
        expect(e5[ClockCase.cdMaySit]!.pv, 'C e5 · A Nf3');
        await book.save(entry(afterLine('A:e4'), ClockCase.cdMaySit));
        final again = await book.lookup(afterLine('A:e4')) as HivemindFound;
        expect(
          again.moves[(BoardNumber.one, 'e7e5')]![ClockCase.cdMaySit]!.pv,
          'C e5 · A Nf3',
        );
        book.close();
      },
    );

    test('a contended writer leaves the UI isolate responsive', () async {
      final path = hivemindBook(relabelled: true);
      final lock = sqlite3.open(path)..execute('BEGIN IMMEDIATE');
      final book = SqliteHivemindBook([path]);
      var released = false;
      final release = Future<void>.delayed(
        const Duration(milliseconds: 100),
        () {
          released = true;
          lock.execute('ROLLBACK');
          lock.close();
        },
      );
      await book.save(entry(afterLine('A:e4'), ClockCase.cdMaySit));
      expect(released, isTrue);
      await release;
      final found = await book.lookup(afterLine('A:e4')) as HivemindFound;
      expect(
        found.moves[(BoardNumber.one, 'e7e5')]!.containsKey(ClockCase.cdMaySit),
        isTrue,
      );
      book.close();
    });

    test('starts a book in the builder’s shape when there is none', () async {
      final path = p.join(dir.path, 'new', 'hivemind_book.db');
      final book = SqliteHivemindBook([path]);
      final table = afterLine('A:e4');
      await book.save(entry(table, ClockCase.even));
      final found = await book.lookup(table) as HivemindFound;
      // New lettering, so C stays C.
      expect(
        found.moves[(BoardNumber.one, 'e7e5')]![ClockCase.even]!.pv,
        'C e5 · A Nf3',
      );
      book.close();
      final db = sqlite3.open(path);
      final row = db.select('SELECT * FROM position').single;
      expect(row['status'], 'done');
      expect(row['line'], 'A:e4');
      expect(row['fen'], table.dualFen);
      expect(
        db
            .select("SELECT move, seat, child FROM move WHERE uci = 'e7e5'")
            .single,
        {
          'move': 'A:e5',
          'seat': 'C',
          'child': table.play(BoardNumber.one, 'e7e5')!.after.bookKey,
        },
      );
      expect(db.select('SELECT team FROM pick').single['team'], 'CD');
      db.close();
    });
  });

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
        'hivemind_book.db',
        environment: {'BUGHOUSE_DB_HOME': '/profile', 'HOME': '/home/me'},
        support: '/support',
      ),
      [p.join('/profile', 'hivemind_book.db')],
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

  // The user's own book, when this machine has one: its start position and
  // first move are there, keyed as the lab keys them. Read from a copy, so
  // not even SQLite's sidecar files appear beside the user's.
  final real = p.join(
    Platform.environment['HOME'] ?? '',
    '.local/share/chess-prep/bughouse-db/hivemind_book.db',
  );
  test(
    'the real Hivemind book answers the start and 1.e4',
    () async {
      final copy = p.join(dir.path, 'real.db');
      await File(real).copy(copy);
      final book = SqliteHivemindBook([copy]);
      for (final table in [TablePosition.initial, afterLine('A:e4')]) {
        final found = await book.lookup(table);
        expect(found, isA<HivemindFound>());
        expect((found as HivemindFound).moves, isNotEmpty);
      }
      book.close();
    },
    skip: File(real).existsSync() ? false : 'no Hivemind book on this machine',
  );
}
