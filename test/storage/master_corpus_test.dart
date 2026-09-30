import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/storage/master_book.dart';
import 'package:chess_auto_prep/storage/master_corpus.dart';
import 'package:chess_auto_prep/storage/master_games_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

String game(int i) =>
    '''
[Event "Club"]
[White "Alice $i"]
[Black "Bob"]
[Date "2026.09.27"]
[WhiteElo "2400"]
[BlackElo "2300"]
[ECO "C20"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
''';

void main() {
  late Directory temp;
  late String database;
  late File source;
  const corpus = SqliteMasterCorpus();
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('v2-corpus-');
    database = p.join(temp.path, 'database.db');
    source = File(p.join(temp.path, 'games.pgn'));
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
    'import commits games and opening counts once across retry and rename',
    () async {
      await source.writeAsString(game(1));
      final original = await source.readAsBytes();
      expect(importMasterPgn(database, source.path), (1, 0));
      final renamed = await source.rename(p.join(temp.path, 'renamed.pgn'));
      expect(importMasterPgn(database, renamed.path), (0, 0));
      expect(await renamed.readAsBytes(), original);
      final book = SqliteMasterBook(database);
      final answer =
          await book.lookup(Fen.initial, classicalOnly: false) as BookFound;
      expect(answer.answer.moves.single.games, 1);
      expect(await book.gamePgn('1'), contains('Alice 1'));
    },
  );

  test('filters are literal and pages do not overlap', () async {
    await source.writeAsString(
      [for (var i = 0; i < 103; i++) game(i)].join('\n'),
    );
    importMasterPgn(database, source.path);
    final first =
        await corpus.search(database, const CorpusFilter())
            as CorpusRead<CorpusPage>;
    final second =
        await corpus.search(database, const CorpusFilter(offset: 100))
            as CorpusRead<CorpusPage>;
    expect(first.value.games.length, 100);
    expect(first.value.more, isTrue);
    expect(second.value.games.length, 3);
    expect(second.value.more, isFalse);
    expect(
      first.value.games
          .map((g) => g.id)
          .toSet()
          .intersection(second.value.games.map((g) => g.id).toSet()),
      isEmpty,
    );
    final matching =
        await corpus.search(
              database,
              const CorpusFilter(
                player: 'Alice 102',
                minimumElo: 2300,
                eco: 'C20',
              ),
            )
            as CorpusRead<CorpusPage>;
    expect(matching.value.games.single.white, 'Alice 102');
    for (final query in [
      const CorpusFilter(player: "' OR 1=1 --"),
      const CorpusFilter(player: '%'),
      const CorpusFilter(minimumElo: 2400),
    ]) {
      final result =
          await corpus.search(database, query) as CorpusRead<CorpusPage>;
      expect(result.value.games, isEmpty);
    }
  });

  test(
    'bad import rolls back and a damaged source is a visible failure',
    () async {
      await source.writeAsString(game(1));
      importMasterPgn(database, source.path);
      await source.writeAsString('not a PGN');
      final result = await corpus.importPgn(source.path, database);
      expect(result, isA<CorpusFailure<(int, int)>>());
      final count = await corpus.size(database) as CorpusRead<CorpusSize>;
      expect(count.value.games, 1);
      await File(database).writeAsString('damaged');
      expect(
        await corpus.search(database, const CorpusFilter()),
        isA<CorpusFailure<CorpusPage>>(),
      );
    },
  );

  test('size says when the games were played and where they came from, '
      'ignoring unknown dates', () async {
    await source.writeAsString(
      [
        game(1).replaceFirst('2026.09.27', '2021.03.04'),
        game(2),
        game(3).replaceFirst('2026.09.27', '????.??.??'),
      ].join('\n'),
    );
    importMasterPgn(database, source.path);
    final size = await corpus.size(database) as CorpusRead<CorpusSize>;
    expect(size.value.games, 3);
    expect(size.value.firstDate, '2021.03.04');
    expect(size.value.lastDate, '2026.09.27');
    expect(size.value.imports, 1);
    expect(size.value.firstIssue, 0, reason: 'no TWIC issue downloaded');
  });

  test('absent database stays absent and counts as empty', () async {
    final size = await corpus.size(database) as CorpusRead<CorpusSize>;
    expect(size.value, emptyCorpus);
    expect(await File(database).exists(), isFalse);
  });

  test('listing the TWIC issues does not wait for a running import', () async {
    await source.writeAsString(game(1));
    importMasterPgn(database, source.path);
    final writer = sqlite3.open(database);
    addTearDown(writer.close);
    writer.execute('INSERT INTO twic_issues VALUES (1600, 1, 0)');
    writer.execute('BEGIN IMMEDIATE');
    writer.execute('INSERT INTO twic_issues VALUES (1601, 1, 0)');
    final started = DateTime.now();
    expect(masterGamesIssues(database).issues, {1600});
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 1)),
    );
    writer.execute('ROLLBACK');
  });

  test('set-asides in the same second keep every earlier copy', () async {
    final path = p.join(temp.path, 'master_games.db');
    final stamp = DateTime.utc(2026, 9, 30, 12);
    final written = <String>[];
    for (final text in ['first damaged file ', 'second damaged file ']) {
      written.add(text * 400);
      File(path).writeAsStringSync(written.last);
      expect(masterGamesIssues(path, now: () => stamp).setAside, isNotNull);
    }
    final copies = [
      for (final entry in temp.listSync())
        if (p.basename(entry.path) case final name
            when name.startsWith('master_games.db.unreadable-') &&
                !RegExp(r'-(wal|shm|journal)$').hasMatch(name))
          entry.path,
    ]..sort();
    expect(copies.map((copy) => File(copy).readAsStringSync()), written);
  });

  group('undated games', () {
    List<String> dates(CorpusResult<CorpusPage> result) => [
      for (final g in (result as CorpusRead<CorpusPage>).value.games) g.date,
    ];

    setUp(() async {
      await source.writeAsString(
        [
          game(1).replaceFirst('2026.09.27', '2021.03.04'),
          game(2).replaceFirst('2026.09.27', '????.??.??'),
          game(3),
        ].join('\n'),
      );
      importMasterPgn(database, source.path);
    });

    test('come after every dated game and never pass From date', () async {
      expect(dates(await corpus.search(database, const CorpusFilter())), [
        '2026.09.27',
        '2021.03.04',
        '????.??.??',
      ]);
      expect(
        dates(
          await corpus.search(
            database,
            const CorpusFilter(strongestFirst: true),
          ),
        ),
        ['2026.09.27', '2021.03.04', '????.??.??'],
      );
      expect(
        dates(
          await corpus.search(
            database,
            const CorpusFilter(since: '2022.01.01'),
          ),
        ),
        ['2026.09.27'],
      );
    });

    test('page after the dated games without gaps or repeats', () async {
      await source.writeAsString(
        [
          for (var i = 0; i < 250; i++)
            game(100 + i).replaceFirst(
              '2026.09.27',
              i.isEven
                  ? '2025.01.${(i % 28 + 1).toString().padLeft(2, '0')}'
                  : '????.??.??',
            ),
        ].join('\n'),
      );
      importMasterPgn(database, source.path);
      // 127 dated games, then 126 undated: the second page holds both.
      final seen = <int>[];
      final pages = <List<String>>[];
      for (var offset = 0; ; offset += 100) {
        final page =
            await corpus.search(database, CorpusFilter(offset: offset))
                as CorpusRead<CorpusPage>;
        seen.addAll(page.value.games.map((g) => g.id));
        pages.add(dates(page));
        if (!page.value.more) break;
      }
      expect(seen, hasLength(253));
      expect(seen.toSet(), hasLength(253));
      final all = pages.expand((page) => page).toList();
      expect(all.take(127).every((d) => !d.startsWith('?')), isTrue);
      expect(all.take(127), [...all.take(127)]..sort((a, b) => b.compareTo(a)));
      expect(all.skip(127).every((d) => d.startsWith('?')), isTrue);
      final beyond =
          await corpus.search(database, const CorpusFilter(offset: 300))
              as CorpusRead<CorpusPage>;
      expect(beyond.value.games, isEmpty);
      expect(beyond.value.more, isFalse);
    });
  });
}
