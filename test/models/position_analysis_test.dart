import 'package:chess_auto_prep/models/position_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PositionAnalysis.getSortedPositions', () {
    late PositionAnalysis analysis;

    setUp(() {
      analysis = PositionAnalysis()
        ..addPositionStats(
          PositionStats(fen: 'a', games: 4, wins: 4, evalCp: 150),
        )
        ..addPositionStats(
          PositionStats(fen: 'b', games: 5, losses: 5, evalCp: -300),
        )
        ..addPositionStats(PositionStats(fen: 'c', games: 3, draws: 3))
        ..addPositionStats(PositionStats(fen: 'd', games: 1, wins: 1));
    });

    List<String> fens(PositionSort sort) =>
        analysis.getSortedPositions(sortBy: sort).map((s) => s.fen).toList();

    test('drops positions below minGames and orders by win rate', () {
      expect(fens(PositionSort.winRate), ['b', 'c', 'a']);
      expect(fens(PositionSort.winRateDesc), ['a', 'c', 'b']);
    });

    test('eval orders keep only evaluated positions', () {
      expect(fens(PositionSort.evalBadWhite), ['b', 'a']);
      expect(fens(PositionSort.evalGoodBlack), ['b', 'a']);
      expect(fens(PositionSort.evalBadBlack), ['a', 'b']);
      expect(fens(PositionSort.evalGoodWhite), ['a', 'b']);
    });

    test('count orders are descending', () {
      expect(fens(PositionSort.games), ['b', 'a', 'c']);
      expect(fens(PositionSort.wins).first, 'a');
      expect(fens(PositionSort.losses).first, 'b');
    });
  });

  group('GameInfo.fromPgn', () {
    test('reads the headers it displays', () {
      const pgn =
          '[Event "Club"]\n[Site "https://lichess.org/abc"]\n'
          '[Date "2024.01.02"]\n[White "Ann"]\n[Black "Bob"]\n'
          '[Result "1-0"]\n[WhiteElo "1800"]\n[BlackElo "1750"]\n\n1. e4 *\n';
      final info = GameInfo.fromPgn(pgn);
      expect(info.title, 'Ann vs Bob');
      expect(info.eloDisplay, '1800 vs 1750');
      expect(info.subtitle, '2024.01.02 • 1-0');
      expect(info.gameUrl, 'https://lichess.org/abc');
      expect(info.event, 'Club');
      expect(info.pgnText, pgn);
    });

    test('missing headers read as empty', () {
      final info = GameInfo.fromPgn('1. e4 e5 *');
      expect(info.white, '');
      expect(info.title, 'Unknown Game');
      expect(info.gameUrl, isNull);
    });
  });
}
