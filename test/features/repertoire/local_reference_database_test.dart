import 'dart:io';

import 'package:chess_auto_prep/features/repertoire/services/local_reference_database.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late File source;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('reference-test-');
    source = File(p.join(temp.path, 'games.pgn'));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<ReferenceIndex> build(String text) async {
    source.writeAsStringSync(text);
    return buildReferenceIndex(
      ReferenceIndexRequest(source.path, p.join(temp.path, 'cache'), null),
    );
  }

  ReferencePosition query(
    ReferenceIndex index, {
    String? fen,
    String search = '',
    int offset = 0,
    int limit = 50,
  }) => queryReferencePosition((
    path: index.path,
    fen: fen ?? Chess.initial.fen,
    search: search,
    offset: offset,
    limit: limit,
  ));
  String game(
    String name,
    String moves, {
    String result = '1-0',
    String date = '2026.01.01',
  }) =>
      '[Event "Test"]\n[White "$name"]\n[Black "Opponent"]\n[Date "$date"]\n[Result "$result"]\n\n$moves $result\n\n';
  String after(List<String> moves) {
    Position pos = Chess.initial;
    for (final san in moves) {
      pos = pos.play(pos.parseSan(san)!);
    }
    return pos.fen;
  }

  test(
    'indexes moves once, keeps unknown results distinct, and pages searchable games',
    () async {
      final index = await build(
        game('Alice', '1. e4 e5', date: '2026.09.01') +
            game('Bob', '1. e4 c5', result: '*') +
            game('Carol', '1. d4 d5', result: '1/2-1/2'),
      );
      expect(index.games, 3);
      final root = query(index);
      expect(root.total, 3);
      expect(root.games.first.headers['White'], 'Alice');
      final e4 = root.moves.first;
      expect(e4.san, 'e4');
      expect(e4.games, 2);
      expect(e4.white, 1);
      expect(e4.draws, 0);
      expect(e4.black, 0);
      expect(
        query(index, search: 'alice').games.single.headers['White'],
        'Alice',
      );
      expect(
        query(index, search: '%').total,
        0,
      ); // literal text, not SQL wildcard
      final page = query(index, offset: 1, limit: 1);
      expect(page.total, 3);
      expect(page.games.single.headers['White'], 'Carol');
      expect(query(index, fen: after(['e4'])).total, 2);
    },
  );

  test(
    'merges transpositions and counts a repeated position once per game',
    () async {
      final index = await build(
        game('One', '1. Nf3 d5 2. g3 Nf6 3. Bg2') +
            game('Two', '1. g3 d5 2. Nf3 Nf6 3. Bg2') +
            game('Repeat', '1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6'),
      );
      final transposed = query(index, fen: after(['g3', 'd5', 'Nf3', 'Nf6']));
      expect(transposed.moves.single.games, 2);
      final root = query(index);
      expect(root.total, 3);
      expect(root.moves.firstWhere((m) => m.san == 'Nf3').games, 2);
    },
  );

  test(
    'preserves comments and variations without treating their lines as game boundaries',
    () async {
      final raw = game(
        'Annotated',
        '1. e4 {a comment\n[Event "not a game"]\n} e5 (1... c5) 2. Nf3',
      );
      final index = await build(raw);
      expect(index.games, 1);
      expect(
        query(index).games.single.pgnText,
        contains('[Event "not a game"]'),
      );
      expect(query(index, fen: after(['e4'])).moves.single.san, 'e5');
    },
  );

  test(
    'supports FEN starts and terminal positions, rejects illegal games without partial counts',
    () async {
      final start = after(['e4', 'e5']);
      final index = await build(
        '[Event "Position"]\n[FEN "$start"]\n[SetUp "1"]\n[Result "*"]\n\n2. Nf3 Nc6 *\n\n'
        '${game('Bad', '1. e4 e5 2. Qh8')}',
      );
      expect(index.games, 1);
      expect(index.skipped, 1);
      expect(query(index).total, 0);
      expect(query(index, fen: start).moves.single.san, 'Nf3');
      final end = query(index, fen: after(['e4', 'e5', 'Nf3', 'Nc6']));
      expect(end.total, 1);
      expect(end.moves, isEmpty);
    },
  );

  test('reuses completed cache and rebuilds when source changes', () async {
    final index = await build(game('Original', '1. e4 e5'));
    final stamp = File(index.path).lastModifiedSync();
    final cached = await buildReferenceIndex(
      ReferenceIndexRequest(source.path, p.join(temp.path, 'cache'), null),
    );
    expect(cached.path, index.path);
    expect(File(cached.path).lastModifiedSync(), stamp);
    final changed = await build(
      game('Replacement', '1. d4 d5') + game('Extra', '1. c4 e5'),
    );
    expect(changed.path, isNot(index.path));
    expect(query(changed).total, 2);
    expect(source.readAsStringSync(), contains('Replacement'));
  });

  test('accepts BOM, CRLF and tag order without requiring Event first', () async {
    final index = await build(
      '\uFEFF[White "A"]\r\n[Result "1-0"]\r\n\r\n1. e4 e5 1-0\r\n\r\n[White "B"]\r\n[Result "0-1"]\r\n\r\n1. d4 d5 0-1',
    );
    expect(index.games, 2);
  });
  test('large collection returns bounded pages and complete counts', () async {
    final text = List.generate(
      3000,
      (i) => game(
        'Player $i',
        '1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 Nf6 5. d3 d6',
      ),
    ).join();
    final timer = Stopwatch()..start();
    final index = await build(text);
    final importMs = timer.elapsedMilliseconds;
    timer.reset();
    final root = query(index, limit: 50);
    expect(root.total, 3000);
    expect(root.games.length, 50);
    expect(root.moves.single.games, 3000);
    // Diagnostic measurements, not machine-dependent timing assertions.
    // ignore: avoid_print
    print(
      'Reference index: 3000 games in ${importMs}ms; indexed page in ${timer.elapsedMilliseconds}ms',
    );
  });
  test(
    'castling uses standard king-destination UCI for board arrows',
    () async {
      final index = await build(
        game('Castle', '1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. O-O'),
      );
      final moves = query(
        index,
        fen: after(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5']),
      ).moves;
      expect(moves.single.uci, 'e1g1');
    },
  );

  test('rebuilds a damaged cache and removes failed build files', () async {
    final index = await build(game('Good', '1. d4 d5'));
    File(index.path).writeAsStringSync('damaged cache');
    final rebuilt = await buildReferenceIndex(
      ReferenceIndexRequest(source.path, p.join(temp.path, 'cache'), null),
    );
    expect(query(rebuilt).moves.single.san, 'd4');
    await expectLater(build('[Event "Invalid"]\n\n1. Qh8 *'), throwsStateError);
    expect(
      Directory(
        p.join(temp.path, 'cache'),
      ).listSync().where((f) => f.path.endsWith('.building')),
      isEmpty,
    );
  });
}
