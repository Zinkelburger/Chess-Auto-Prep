import 'package:chess_auto_prep/features/bughouse/models/bughouse_rules.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_tournament.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_tournament_runner.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_bughouse_engine.dart';

const rescueFen =
    'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR[] w KQkq - 1 3|rnbqkbnr/ppp1pppp/8/3P4/8/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 2';

void main() {
  test('a promoted capture returns a pawn, which cannot block on rank 8', () {
    const checked = '5k1R/pppbrp2/2p1pQ2/8/2B1P3/2PN4/PPP3K1/8[RB] b - - 4 31';
    for (final promoted in [false, true]) {
      final piece = promoted ? 'q~' : 'q';
      final state = BughouseState.tryParseDualFen(
        '$checked|7k/8/8/8/8/8/8/${piece}3R2K[] w - - 0 1',
      )!;
      expect(state.boardA.isCheckmate, isTrue);
      expect(
        BughouseRules.losingBoard(state, Side.black),
        promoted ? BughouseBoard.a : null,
      );
    }
  });

  test('en passant on the partner board can supply a blocker', () {
    final checked = rescueFen.split('|').first;
    final state = BughouseState.tryParseDualFen(
      '$checked|4k3/8/8/8/3Pp3/8/8/4K3[] b - d3 0 1',
    )!;
    expect(BughouseRules.losingBoard(state, Side.white), isNull);
  });

  test('one stalemated board can wait while its partner plays', () {
    final state = BughouseState.tryParseDualFen(
      'k7/8/1Q6/8/8/8/8/1K6[] b - - 0 1',
    )!;
    expect(state.boardA.isStalemate, isTrue);
    expect(BughouseRules.losingBoard(state, Side.black), isNull);
    final both = state.withBoard(
      BughouseBoard.b,
      Crazyhouse.fromSetup(Setup.parseFen('8/8/8/8/8/1q6/2k5/K7[] w - - 0 1')),
    );
    expect(BughouseRules.losingBoard(both, Side.black), BughouseBoard.a);
    expect(
      BughouseRules.losingBoard(
        both.copyWith(team: Side.black, timeStance: BughouseTimeStance.ahead),
        Side.black,
      ),
      BughouseBoard.a,
    );
  });

  test('Qxd5 supplies P@g3 and prevents premature adjudication', () async {
    final start = BughouseState.tryParseDualFen(rescueFen)!;
    expect(start.boardA.isCheckmate, isTrue);
    expect(BughouseRules.losingBoard(start, Side.white), isNull);
    final captured = start.playMove(BughouseBoard.b, Move.parse('d8d5')!)!;
    expect(captured.boardA.isLegal(Move.parse('P@g3')!), isTrue);
    final engine = FakeBughouseEngine()
      ..script.add(scripted(best: '(pass,d8d5)'));
    final games = await BughouseTournamentRunner(
      engine: engine,
      config: BughouseTournamentConfig(
        name: 'Rescue',
        startDualFen: rescueFen,
        games: 1,
        maxPlies: 1,
        variety: BughouseVariety.none,
      ),
    ).run();
    expect(games.single.moves, ['2d8d5']);
    expect(games.single.termination, TerminationReason.maxMoves);
  });

  test('no capture and no guaranteed future capture are terminal', () {
    final start = BughouseState.tryParseDualFen(rescueFen)!;
    final noCapture = start.withBoard(BughouseBoard.b, Crazyhouse.initial);
    expect(BughouseRules.losingBoard(noCapture, Side.white), BughouseBoard.a);
    expect(
      BughouseRules.losingBoard(
        noCapture.copyWith(timeStance: BughouseTimeStance.ahead),
        Side.white,
      ),
      BughouseBoard.a,
    );
  });

  test(
    'failure records are delivered once and halt the remaining games',
    () async {
      final engine = FakeBughouseEngine()
        ..failNextSearch = BughouseEngineFailure('broken');
      final records = <BughouseGameRecord>[];
      final runner = BughouseTournamentRunner(
        engine: engine,
        config: BughouseTournamentConfig(
          name: 'Failure',
          startDualFen: BughouseState.initial().dualFen,
          games: 3,
        ),
        onGameFinished: records.add,
      );
      await expectLater(
        runner.run(),
        throwsA(isA<BughouseTournamentFailure>()),
      );
      expect(records, hasLength(1));
      expect(records.single.result, GameResult.unfinished);
      expect(records.single.termination, TerminationReason.engineFailure);
      expect(engine.searches, hasLength(1));
    },
  );
}
