/// Coverage is a fraction of game counts: what share of the master games that
/// reach your root the repertoire still answers.
///
/// The counts come from the local master-games (TWIC) book rather than the
/// Lichess Explorer, because a run asks the question at every node of a tree —
/// thousands of lookups — and the Explorer fetch path was mothballed for
/// exactly that reason. These pin the two halves of that: the book actually
/// drives the numbers, and with no book the run refuses instead of reporting
/// "0.0% covered" for a repertoire of any size.
library;

import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart'
    show BookMove;
import 'package:flutter_test/flutter_test.dart';

const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

BookMove _move(
  String uci, {
  required int games,
  int white = 0,
  int draws = 0,
  int black = 0,
}) => BookMove(
  uci: uci,
  games: games,
  whiteWins: white,
  draws: draws,
  blackWins: black,
  averageElo: 2500,
  maxElo: 2700,
  lastYear: 2026,
  topGameId: 0,
  recentGameId: 0,
  topClassicalGameId: 0,
);

void main() {
  group('with no master book wired', () {
    final service = CoverageService();

    test('reports that it has no position data', () {
      expect(service.hasPositionData, isFalse);
    });

    test('every derived count is zero', () async {
      expect(await service.getGameCount(_start), 0);
      expect(await service.getMovesWithCounts(_start), isEmpty);
    });

    test('a run refuses rather than reporting zeros', () async {
      await expectLater(
        service.analyzeOpeningTree(
          OpeningTree(),
          targetPercent: 95,
          isWhiteRepertoire: true,
        ),
        throwsA(isA<StateError>()),
        reason:
            'a zeroed CoverageResult tells the user their repertoire covers '
            'nothing, which is not what happened',
      );
    });

    test(
      'the refusal names the missing database, not the repertoire',
      () async {
        try {
          await service.analyzeOpeningTree(
            OpeningTree(),
            targetPercent: 95,
            isWhiteRepertoire: true,
          );
          fail('expected a StateError');
        } on StateError catch (e) {
          expect(e.message, contains('master-games'));
          expect(e.message, contains('Settings'));
        }
      },
    );
  });

  group('with a master book wired', () {
    CoverageService serviceFor(Map<String, List<BookMove>> book) =>
        CoverageService(masterBook: (fen) => book[fen] ?? const []);

    test('has position data', () {
      expect(serviceFor(const {}).hasPositionData, isTrue);
    });

    test('game count is the games over every move played from here', () async {
      final service = serviceFor({
        _start: [
          _move('e2e4', games: 600, white: 200, draws: 300, black: 100),
          _move('d2d4', games: 400, white: 150, draws: 200, black: 50),
        ],
      });

      expect(await service.getGameCount(_start), 1000);
    });

    test('a position the book has never seen counts zero', () async {
      expect(await serviceFor(const {}).getGameCount(_start), 0);
    });

    test('moves come back as SAN with their W/D/L split', () async {
      final service = serviceFor({
        _start: [_move('e2e4', games: 600, white: 200, draws: 300, black: 100)],
      });

      final moves = await service.getMovesWithCounts(_start);
      expect(moves, hasLength(1));
      expect(moves.single['san'], 'e4');
      expect(moves.single['uci'], 'e2e4');
      expect(moves.single['white'], 200);
      expect(moves.single['draws'], 300);
      expect(moves.single['black'], 100);
    });

    test('most-played order is preserved', () async {
      final service = serviceFor({
        _start: [
          _move('e2e4', games: 600),
          _move('d2d4', games: 400),
          _move('g1f3', games: 200),
        ],
      });

      final moves = await service.getMovesWithCounts(_start);
      expect(moves.map((m) => m['san']), ['e4', 'd4', 'Nf3']);
    });

    /// A move that cannot be rendered as SAN here would never match a
    /// repertoire SAN, so reporting it would show a gap the user can never
    /// close no matter what they add.
    test(
      'a move illegal in the position is dropped, not reported raw',
      () async {
        final service = serviceFor({
          _start: [
            _move('e2e4', games: 600),
            _move('e2e5', games: 5), // not legal from the start
            _move('nonsense', games: 3),
          ],
        });

        final moves = await service.getMovesWithCounts(_start);
        expect(moves.map((m) => m['san']), ['e4']);
      },
    );

    test('the dropped moves still count towards the position total', () async {
      // getGameCount sums the book rows, which is what the book itself says
      // reached this position — filtering is a rendering concern.
      final service = serviceFor({
        _start: [_move('e2e4', games: 600), _move('e2e5', games: 5)],
      });

      expect(await service.getGameCount(_start), 605);
    });
  });
}
