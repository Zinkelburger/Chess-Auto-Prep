import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/storage/master_book.dart';
import 'package:chess_auto_prep/v2/storage/master_corpus.dart';
import 'package:chess_auto_prep/v2/storage/twic_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
  late String cache;
  late File source;
  const corpus = SqliteMasterCorpus();
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('v2-corpus-');
    cache = p.join(temp.path, 'cache.db');
    source = File(p.join(temp.path, 'games.pgn'));
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
    'import commits games and opening counts once across retry and rename',
    () async {
      await source.writeAsString(game(1));
      final original = await source.readAsBytes();
      expect(importMasterPgn(cache, source.path), (1, 0));
      final renamed = await source.rename(p.join(temp.path, 'renamed.pgn'));
      expect(importMasterPgn(cache, renamed.path), (0, 0));
      expect(await renamed.readAsBytes(), original);
      final book = SqliteMasterBook(cache);
      addTearDown(book.close);
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
    importMasterPgn(cache, source.path);
    final first =
        await corpus.search(cache, const CorpusFilter())
            as CorpusRead<CorpusPage>;
    final second =
        await corpus.search(cache, const CorpusFilter(offset: 100))
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
              cache,
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
          await corpus.search(cache, query) as CorpusRead<CorpusPage>;
      expect(result.value.games, isEmpty);
    }
  });

  test(
    'bad import rolls back and a damaged source is a visible failure',
    () async {
      await source.writeAsString(game(1));
      importMasterPgn(cache, source.path);
      await source.writeAsString('not a PGN');
      final result = await corpus.importPgn(source.path, cache);
      expect(result, isA<CorpusFailure<(int, int)>>());
      final count = await corpus.size(cache) as CorpusRead<CorpusSize>;
      expect(count.value.games, 1);
      await File(cache).writeAsString('damaged');
      expect(
        await corpus.search(cache, const CorpusFilter()),
        isA<CorpusFailure<CorpusPage>>(),
      );
    },
  );

  test('absent database stays absent and counts as empty', () async {
    final size = await corpus.size(cache) as CorpusRead<CorpusSize>;
    expect(size.value, (games: 0, bytes: 0));
    expect(await File(cache).exists(), isFalse);
  });
}
