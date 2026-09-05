@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/features/master_games/services/master_practice_review.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'master_practice_fixtures.dart';

void main() {
  late Directory tmp;
  late MasterGamesDb db;
  late MasterPracticeReviewer reviewer;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('master_practice');
    final dbPath = '${tmp.path}/master_games.db';
    importPgnIntoMasterGames(
      MasterGamesImportRequest(
        dbPath: dbPath,
        pgnText: masterPgn,
        twicIssue: 1660,
      ),
    );
    db = MasterGamesDb.open(dbPath, readOnly: true);
    reviewer = MasterPracticeReviewer(lookup: db.bookMoves, gameById: db.game);
  });

  tearDown(() async {
    db.close();
    await tmp.delete(recursive: true);
  });

  test('finds the first move masters never played, and who played it', () {
    final report = reviewer.reportFor(myGames()[0])!;
    expect(report.isDeviation, isTrue);
    expect(report.byMe, isTrue);
    expect(report.matchedPlies, 10);
    expect(report.moveNumber, 6);
    expect(report.playedDisplay, '6. Bc4');
    expect(report.lastBookMoveDisplay, '5... a6');
    expect(report.pathSans.length, 10);
    expect(report.viewerPly, 11);
    // Most played first: Be3 twice, Bg5 once.
    expect(report.alternatives.map(report.alternativeSan), ['Be3', 'Bg5']);
    expect(report.positionGames, 3);
    // Be3: one White win and one draw, from White's point of view.
    expect(report.scoreForMover(report.alternatives.first), 0.75);
    expect(report.playedUci, 'f1c4');
    expect(report.alternativeUci(report.alternatives.first), 'c1e3');
  });

  test('the opponent leaving is reported from my side of the board', () {
    final report = reviewer.reportFor(myGames()[1])!;
    expect(report.byMe, isFalse);
    expect(report.playedDisplay, '6. Bc4');
  });

  test('a first move nobody here has played is a deviation at move 1', () {
    final report = reviewer.reportFor(myGames()[5])!;
    expect(report.isDeviation, isTrue);
    expect(report.matchedPlies, 0);
    expect(report.playedDisplay, '1. b4');
    expect(report.lastBookMoveDisplay, isNull);
    expect(report.lastBookMove, isNull);
    expect(report.alternatives.map(report.alternativeSan), ['e4', 'd4']);
  });

  test('outrunning every master game is the book ending, not a deviation', () {
    final report = reviewer.reportFor(myGames()[3])!;
    expect(report.isDeviation, isFalse);
    expect(report.bookEnded, isTrue);
    expect(report.reachedBookDepth, isFalse);
    expect(report.byMe, isNull);
    expect(report.matchedPlies, 14);
    expect(report.playedSan, 'f3');
    expect(report.lastBookMoveDisplay, '7... Be6');
    expect(report.lastBookMove, isNotNull);
    expect(report.viewerPly, 14);
  });

  test('a game that stays in theory to the book\'s depth says so', () {
    final report = reviewer.reportFor(myGames()[6])!;
    expect(report.bookEnded, isTrue);
    expect(report.reachedBookDepth, isTrue);
    expect(report.matchedPlies, kBookMaxPly);
  });

  test('games where my side is unknown cannot be walked', () {
    expect(reviewer.reportFor(myGames()[4]), isNull);
  });

  test(
    'the review groups games by branch point and keeps sides apart',
    () async {
      final review = await reviewer.review(myGames());
      expect(review.gamesChecked, 6);
      expect(review.gamesSkipped, 1);

      // Two of my 6.Bc4 games in one entry, ahead of the single 1.b4.
      expect(review.mine.length, 2);
      expect(review.mine.first.games.map((g) => g.record.dedupKey), ['a', 'c']);
      expect(review.mine.first.report.playedDisplay, '6. Bc4');
      expect(review.mine.last.report.playedDisplay, '1. b4');
      expect(review.mine.first.openingDisplay, contains('Najdorf'));

      // The opponent's 6.Bc4 is the same position and move, but not my mistake.
      expect(review.theirs.length, 1);
      expect(review.theirs.first.report.key, review.mine.first.report.key);
      expect(review.theirs.first.games.single.record.dedupKey, 'b');

      // The two games that never left: one outran the corpus, one hit the depth.
      expect(review.inBook.length, 2);
      expect(review.myGames, 3);
      expect(review.theirGames, 1);
      expect(review.inBookGames, 2);
    },
  );

  test(
    'key games are the strongest game per master move, then the latest',
    () async {
      final review = await reviewer.review(myGames());
      final keys = review.mine.first.keyGames;
      expect(keys.map((k) => k.moveSan).toSet(), {'Be3', 'Bg5'});
      final be3 = keys.firstWhere((k) => k.moveSan == 'Be3');
      expect(be3.players, 'Carlsen – Nakamura');
      expect(be3.reason, 'Strongest');
      expect(be3.where, 'Tata Steel 2026');
      expect(be3.topElo, 2830);
      final bg5 = keys.firstWhere((k) => k.moveSan == 'Bg5');
      expect(bg5.players, 'Novak – Svoboda');
      // No game is listed twice, whatever slots it fills.
      expect(keys.map((k) => k.game.id).toSet().length, keys.length);
    },
  );

  test('when the book ends, the key games are the ones in that line', () async {
    final review = await reviewer.review(myGames());
    final ranPast = review.inBook.firstWhere((e) => !e.report.reachedBookDepth);
    expect(ranPast.keyGames.map((k) => k.moveSan).toSet(), {'Be6'});
    expect(ranPast.keyGames.first.players, 'Carlsen – Nakamura');
    final breyer = review.inBook.firstWhere((e) => e.report.reachedBookDepth);
    expect(breyer.keyGames.single.players, 'Gukesh – Nepomniachtchi');
  });

  test('the headline says who left first and how often', () async {
    final review = await reviewer.review(myGames());
    final line = review.headline('last 7 games');
    expect(line, contains('6 games checked'));
    expect(line, contains('you left master practice first in 3'));
    expect(line, contains('your opponents in 1'));
    expect(line, contains('2 stayed in theory'));
    expect(line, contains('move ${kBookMaxPly ~/ 2}'));
    expect(review.averageLeaveMove, isNotNull);
  });

  test(
    'with nothing checkable the headline says so instead of zeroes',
    () async {
      final review = await reviewer.review([myGames()[4]]);
      expect(review.isEmpty, isTrue);
      expect(review.averageLeaveMove, isNull);
      expect(review.headline('last 1 game'), contains('could be checked'));
    },
  );

  test('a cancelled review reports what it managed', () async {
    var calls = 0;
    final review = await reviewer.review(
      myGames(),
      isCancelled: () => calls++ >= 2,
    );
    expect(review.gamesChecked + review.gamesSkipped, 2);
  });

  test('a lookup that throws reads as the book ending, not a crash', () {
    final broken = MasterPracticeReviewer(
      lookup: (_) => throw StateError('closed'),
      gameById: db.game,
    );
    final report = broken.reportFor(myGames()[0])!;
    expect(report.bookEnded, isTrue);
    expect(report.matchedPlies, 0);
  });
}
