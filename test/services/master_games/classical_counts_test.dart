@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/services/master_games/master_book_rebuild.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two classical games and one Titled Tuesday, all Sicilians; the online one
/// is the only Black win.
const _pgn = '''
[Event "Tata Steel"]
[Site "Wijk aan Zee"]
[Date "2026.01.21"]
[White "Carlsen,Magnus"]
[Black "Nakamura,Hikaru"]
[Result "1-0"]
[WhiteElo "2830"]
[BlackElo "2790"]

1. e4 c5 2. Nf3 d6 1-0

[Event "Titled Tue 3rd Feb"]
[Site "chess.com INT"]
[Date "2026.02.03"]
[White "Blitzer,A"]
[Black "Blitzer,B"]
[Result "0-1"]
[WhiteElo "2900"]
[BlackElo "2850"]

1. e4 c5 2. Nf3 Nc6 0-1

[Event "Prague Open"]
[Site "Prague"]
[Date "2026.01.20"]
[White "Novak,Jan"]
[Black "Svoboda,Petr"]
[Result "1/2-1/2"]
[WhiteElo "2410"]
[BlackElo "2505"]

1. e4 c5 2. Nc3 1/2-1/2
''';

const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _afterC5 = 'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

void main() {
  late Directory tmp;
  late MasterGamesDb db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('classical_counts');
    final path = '${tmp.path}/master_games.db';
    importPgnIntoMasterGames(
      MasterGamesImportRequest(dbPath: path, pgnText: _pgn, twicIssue: 1660),
    );
    db = MasterGamesDb.open(path);
  });

  tearDown(() async {
    db.close();
    await tmp.delete(recursive: true);
  });

  BookMove move(String fen, String uci) =>
      db.bookMoves(fen).firstWhere((m) => m.uci == uci);

  test('the import keeps the classical split beside the full counts', () {
    final e4 = move(_start, 'e2e4');
    expect(e4.games, 3);
    expect(e4.classicalGames, 2);
    expect(e4.classicalWhiteWins, 1);
    expect(e4.classicalDraws, 1);
    expect(e4.classicalBlackWins, 0);

    final nf3 = move(_afterC5, 'g1f3');
    expect(nf3.games, 2);
    expect(nf3.blackWins, 1, reason: 'the online game is a Black win');
    expect(nf3.classicalGames, 1);
    expect(nf3.classicalBlackWins, 0);
  });

  test('a fresh database has complete counts by construction', () {
    expect(db.classicalCountsComplete, isTrue);
  });

  test('the classical-only view is the same row without the online games', () {
    final nf3 = move(_afterC5, 'g1f3').classicalOnly!;
    expect(nf3.uci, 'g1f3');
    expect(nf3.games, 1);
    expect(nf3.whiteWins, 1);
    expect(nf3.blackWins, 0);
    expect(nf3.whiteScore, 1.0);
    // The citation is the classical game even though the blitz one is
    // higher rated.
    final cited = db.game(nf3.topGameId)!;
    expect(cited.white, 'Carlsen,Magnus');
  });

  test('a move only ever played online has no classical-only view', () {
    // Add a game whose second move nobody classical has played.
    importPgnIntoMasterGames(
      MasterGamesImportRequest(
        dbPath: db.path,
        pgnText: '''
[Event "Titled Tue 10th Feb"]
[Site "chess.com INT"]
[Result "1-0"]

1. e4 c5 2. b3 1-0
''',
        twicIssue: 1661,
      ),
    );
    expect(move(_afterC5, 'b2b3').classicalOnly, isNull);
  });

  test('the rebuild reproduces what the import wrote', () async {
    resetClassicalCounts(db);
    expect(db.classicalCountsComplete, isFalse);
    expect(move(_start, 'e2e4').classicalGames, 0);

    final result = await rebuildClassicalCitations(db);
    expect(result.done, isTrue);
    expect(result.gamesScanned, 2);
    expect(db.classicalCountsComplete, isTrue);
    final e4 = move(_start, 'e2e4');
    expect(e4.classicalGames, 2);
    expect(e4.classicalWhiteWins, 1);
    expect(e4.classicalDraws, 1);
  });

  test('running the rebuild twice does not double the counts', () async {
    await rebuildClassicalCitations(db);
    await rebuildClassicalCitations(db);
    expect(move(_start, 'e2e4').classicalGames, 2);
  });

  test('the rebuild can be walked in chunks and continued', () async {
    final first = await rebuildClassicalCitations(db, maxGames: 1);
    expect(first.gamesScanned, 1);
    expect(first.done, isFalse);
    expect(db.classicalCountsComplete, isFalse);
    expect(move(_start, 'e2e4').classicalGames, 1);

    final second = await rebuildClassicalCitations(
      db,
      afterId: first.lastId,
      maxGames: 1,
    );
    expect(second.gamesScanned, 1);
    expect(second.done, isFalse, reason: 'the cap was hit, not the end');

    final third = await rebuildClassicalCitations(
      db,
      afterId: second.lastId,
      maxGames: 1,
    );
    expect(third.gamesScanned, 0);
    expect(third.done, isTrue);
    expect(db.classicalCountsComplete, isTrue);
    expect(move(_start, 'e2e4').classicalGames, 2);
  });

  test('a cancelled rebuild leaves the counts marked incomplete', () async {
    final result = await rebuildClassicalCitations(
      db,
      batch: 1,
      isCancelled: () => true,
    );
    expect(result.cancelled, isTrue);
    expect(db.classicalCountsComplete, isFalse);
  });

  test('refreshing authorities throws the counts away too', () {
    refreshAuthorities(db);
    expect(db.classicalCountsComplete, isFalse);
    expect(move(_start, 'e2e4').classicalGames, 0);
  });
}
