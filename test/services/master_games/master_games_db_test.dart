@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/services/master_games/master_model_games.dart';
import 'package:chess_auto_prep/services/master_games/movetext_codec.dart';
import 'package:chess_auto_prep/services/master_games/position_key.dart';
import 'package:chess_auto_prep/services/master_games/twic_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../generation/generation_test_helpers.dart';

const _pgn = '''
[Event "Test Open"]
[Site "Testville"]
[Date "2025.03.01"]
[Round "1"]
[White "Carlsen,M"]
[Black "Nakamura,Hi"]
[Result "1-0"]
[WhiteElo "2830"]
[BlackElo "2790"]
[ECO "C50"]
[WhiteFideId "1503014"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 Nf6 1-0

[Event "Test Open"]
[Site "Testville"]
[Date "2025.03.02"]
[Round "2"]
[White "So,W"]
[Black "Caruana,F"]
[Result "1/2-1/2"]
[WhiteElo "2760"]
[BlackElo "2800"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 {comment} 4. Ba4 (4. Bxc6) Nf6 1/2-1/2

[Event "Broken"]
[White "A"]
[Black "B"]
[Result "*"]

1. e4 e5 2. Qh5 Zz9 3. Nf3 *
''';

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mgdb');
    dbPath = '${tmp.path}/master_games.db';
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('positionKey ignores move counters and is stable', () {
    const a = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
    const b = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 5 9';
    expect(positionKey(a), positionKey(b));
    expect(positionKey(a), isNot(positionKey(a.replaceFirst(' b ', ' w '))));
    // Reference values shared with the Python side
    // (tools/mcp/chess_prep/master_games.py) — both must agree forever.
    expect(
      positionKey('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'),
      -1777514259035056900,
    );
    expect(positionKey(a), 3107432833210105763);
  });

  test('import aggregates the book and stores games', () {
    final r = importPgnIntoMasterGames(
      MasterGamesImportRequest(dbPath: dbPath, pgnText: _pgn, twicIssue: 1600),
    );
    expect(r.gamesImported, 3);

    final db = MasterGamesDb.open(dbPath, readOnly: true);
    addTearDown(db.close);

    final stats = db.stats();
    expect(stats.games, 3);
    expect(stats.issues, 1);
    expect(stats.firstIssue, 1600);

    // After 1.e4 e5 2.Nf3 Nc6 both real games continue; Bc4 once, Bb5 once.
    const afterNc6 =
        'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';
    final moves = db.bookMoves(afterNc6);
    expect(moves.map((m) => m.uci).toSet(), {'f1c4', 'f1b5'});
    final bc4 = moves.firstWhere((m) => m.uci == 'f1c4');
    expect(bc4.games, 1);
    expect(bc4.whiteWins, 1);
    expect(bc4.maxElo, 2830);
    expect(bc4.lastYear, 2025);

    // Start position: e4 played three times (the broken game too).
    const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final e4 = db.bookMoves(start).single;
    expect(e4.uci, 'e2e4');
    expect(e4.games, 3);
    expect(e4.draws, 1);
    // Strongest game is cited.
    final top = db.game(e4.topGameId)!;
    expect(top.white, 'Carlsen,M');
    expect(top.citation, 'Carlsen–Nakamura, Testville 2025');
    expect(top.whiteFideId, 1503014);

    // Comments and variations are stripped, numbering rebuilt.
    final so = db.gamesByPlayer('So').single;
    expect(so.movetext, '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6');
    expect(so.toPgn(), contains('[Result "1/2-1/2"]'));

    // The broken game stops at the bad SAN but the prefix still counts.
    const afterQh5 =
        'rnbqkbnr/pppp1ppp/8/4p2Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2';
    expect(db.bookMoves(afterQh5), isEmpty);
  });

  test('movetext is stored compressed with a dictionary kept in meta', () {
    importPgnIntoMasterGames(
      MasterGamesImportRequest(dbPath: dbPath, pgnText: _pgn, twicIssue: 1),
    );
    final db = MasterGamesDb.open(dbPath, readOnly: true);
    addTearDown(db.close);
    final dict = db.metaBlob(kMovetextDictKey);
    expect(dict, isNotNull);
    expect(dict, isNotEmpty);
    // The raw column is a blob, not the text — and shorter than it.
    final raw = db.raw
        .select('SELECT movetext FROM games WHERE white = ?', ['So,W'])
        .first
        .columnAt(0);
    expect(raw, isA<List<int>>());
    expect(
      (raw as List<int>).length,
      lessThan('1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6'.length),
    );
    // A codec built from the stored dictionary decodes it; the plain codec
    // does not — the dictionary is load-bearing.
    expect(
      MovetextCodec(dict!).decode(raw),
      '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6',
    );
    expect(() => MovetextCodec.plain.decode(raw), throwsA(anything));
  });

  test('codec round-trips with and without a dictionary', () {
    const text = '1. d4 Nf6 2. c4 e6 3. Nc3 Bb4 4. Qc2 O-O 5. a3 Bxc3+';
    expect(MovetextCodec.plain.decode(MovetextCodec.plain.encode(text)), text);
    final dict = MovetextCodec.buildDictionary(['1. d4 Nf6 2. c4 e6 3. Nc3']);
    final c = MovetextCodec(dict);
    expect(c.decode(c.encode(text)), text);
    expect(
      c.encode(text).length,
      lessThan(MovetextCodec.plain.encode(text).length),
    );
    // Dictionaries never exceed zlib's window.
    final big = MovetextCodec.buildDictionary(
      List.filled(2000, '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7'),
    );
    expect(big.length, kMovetextDictBytes);
  });

  test('a v1 database is rebuilt from scratch on open', () {
    final v1 = MasterGamesDb.open(dbPath);
    v1.raw.execute('''
      DROP TABLE IF EXISTS meta;
      DROP TABLE IF EXISTS games;
      CREATE TABLE games(id INTEGER PRIMARY KEY, movetext TEXT NOT NULL);
      INSERT INTO games(movetext) VALUES('1. e4');
      INSERT INTO twic_issues(issue, games, imported_at) VALUES(1500, 1, 0);
      PRAGMA user_version = 1;
    ''');
    v1.close();
    final db = MasterGamesDb.open(dbPath);
    addTearDown(db.close);
    expect(db.stats().games, 0);
    expect(db.importedIssues(), isEmpty);
    expect(db.raw.select('PRAGMA user_version').first.columnAt(0), 4);
    // Importing into the rebuilt file works and stores blobs.
    importPgnIntoMasterGames(
      MasterGamesImportRequest(dbPath: dbPath, pgnText: _pgn, twicIssue: 1),
    );
    expect(db.stats().games, 3);
  });

  test('re-importing an issue is a no-op unless replace is set', () {
    final req = MasterGamesImportRequest(
      dbPath: dbPath,
      pgnText: _pgn,
      twicIssue: 1600,
    );
    importPgnIntoMasterGames(req);
    final again = importPgnIntoMasterGames(req);
    expect(again.alreadyImported, isTrue);
    final db = MasterGamesDb.open(dbPath, readOnly: true);
    addTearDown(db.close);
    expect(db.stats().games, 3);
  });

  test('model-game candidates follow the repertoire moves', () {
    importPgnIntoMasterGames(
      MasterGamesImportRequest(dbPath: dbPath, pgnText: _pgn, twicIssue: 1600),
    );
    final db = MasterGamesDb.open(dbPath, readOnly: true);
    addTearDown(db.close);

    // White repertoire: 1.e4 e5 2.Nf3 Nc6 3.Bc4 — only the Carlsen game
    // played Bc4; the So game went Bb5.
    resetNodeIds();
    final root = makeNode(
      fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      san: '',
      ply: 0,
      isWhiteToMove: true,
    );
    final e4 = makeNode(
      fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
      san: 'e4',
      uci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
      parent: root,
    )..isRepertoireMove = true;
    final e5 = makeNode(
      fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
      san: 'e5',
      uci: 'e7e5',
      ply: 2,
      isWhiteToMove: true,
      parent: e4,
    );
    final nf3 = makeNode(
      fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2',
      san: 'Nf3',
      uci: 'g1f3',
      ply: 3,
      isWhiteToMove: false,
      parent: e5,
    )..isRepertoireMove = true;
    final nc6 = makeNode(
      fen: 'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3',
      san: 'Nc6',
      uci: 'b8c6',
      ply: 4,
      isWhiteToMove: true,
      parent: nf3,
    );
    makeNode(
      fen: 'r1bqkbnr/pppp1ppp/2n5/2B1p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3',
      san: 'Bc4',
      uci: 'f1c4',
      ply: 5,
      isWhiteToMove: false,
      parent: nc6,
    ).isRepertoireMove = true;

    final candidates = masterGameCandidates(
      db,
      BuildTree(root: root),
      playAsWhite: true,
    );
    // Deepest first: the Bc4 game leads; the So game (e4/Nf3 only) follows.
    expect(candidates.first.white, 'Carlsen,M');
    expect(candidates.first.movesSan.take(5), [
      'e4',
      'e5',
      'Nf3',
      'Nc6',
      'Bc4',
    ]);
    expect(candidates.map((c) => c.white), contains('So,W'));
    // The strength floor drops the unrated broken game.
    expect(
      masterGameCandidates(
        db,
        BuildTree(root: root),
        playAsWhite: true,
        minElo: 2700,
      ).map((c) => c.white),
      isNot(contains('A')),
    );
  });

  test('TWIC issue arithmetic', () {
    expect(twicIssueEstimateFor(DateTime.utc(2026, 8, 17)), 1658);
    expect(twicIssueEstimateFor(DateTime.utc(2026, 8, 24)), 1659);
    expect(twicIssueYearsBack(5, now: DateTime.utc(2026, 8, 19)), 1398);
    expect(
      twicIssueYearsBack(50, now: DateTime.utc(2026, 8, 19)),
      kTwicFirstPgnIssue,
    );
    expect(
      twicZipUri(1500).toString(),
      'https://theweekinchess.com/zips/twic1500g.zip',
    );
  });

  test(
    'benchmark: import a real TWIC issue (set TWIC_PGN=/path/twicNNNN.pgn)',
    () {
      final path = Platform.environment['TWIC_PGN'];
      if (path == null) {
        markTestSkipped('TWIC_PGN not set');
        return;
      }
      final text = File(path).readAsStringSync();
      final sw = Stopwatch()..start();
      final r = importPgnIntoMasterGames(
        MasterGamesImportRequest(dbPath: dbPath, pgnText: text, twicIssue: 0),
      );
      sw.stop();
      final db = MasterGamesDb.open(dbPath, readOnly: true);
      addTearDown(db.close);
      final s = db.stats();
      final book =
          db.raw.select('SELECT COUNT(*) FROM book').first.columnAt(0) as int;
      // ignore: avoid_print
      print(
        'imported ${r.gamesImported} games (${r.gamesSkipped} skipped) in '
        '${sw.elapsedMilliseconds} ms; book rows $book; '
        'db ${(s.fileBytes / 1e6).toStringAsFixed(1)} MB',
      );
      expect(r.gamesImported, greaterThan(1000));
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
