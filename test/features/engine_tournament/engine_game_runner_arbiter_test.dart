/// The arbiter's less-travelled paths: the endings the base test file does
/// not reach (stalemate, insufficient material, a pre-ended start position),
/// the real clock (increment, session refill, the forfeit margin, `movestogo`),
/// what goes on the wire (castling spelling, promotion), and the header
/// material of the PGN.
///
/// The scripted engine here records every `search` it is handed, which is
/// what lets the tests pin down what the *opponent* is told after each move
/// and not merely what the arbiter concludes.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/adjudication_rules.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/time_control.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/engine_game_runner.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/uci_engine.dart';
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:flutter_test/flutter_test.dart';

class _Engine implements PlayingEngine {
  _Engine(
    this.moves, {
    this.scoreCp = 0,
    this.scores = const [],
    this.scoreMate,
    this.elapsedMs = const [],
    this.defaultElapsedMs = 10,
    this.failNewGame = false,
  });

  final List<String> moves;

  /// Score for every move unless [scores] has an entry for that move.
  final int scoreCp;
  final List<int> scores;
  final int? scoreMate;

  /// Per-move think time; [defaultElapsedMs] past the end of the list.
  final List<int> elapsedMs;
  final int defaultElapsedMs;
  final bool failNewGame;

  /// What the arbiter handed to each `search`, in order.
  final List<List<String>> receivedMoves = [];
  final List<GoLimits> receivedLimits = [];
  int newGameCalls = 0;

  int _index = 0;
  bool _alive = true;

  @override
  bool get isAlive => _alive;

  @override
  Future<void> newGame() async {
    newGameCalls++;
    if (failNewGame) {
      _alive = false;
      throw UciFailure('would not start a game');
    }
  }

  @override
  Future<EngineSearch> search({
    required String startFen,
    required List<String> movesUci,
    required GoLimits limits,
    required Duration hardLimit,
  }) async {
    receivedMoves.add(List.of(movesUci));
    receivedLimits.add(limits);
    final i = _index++;
    final move = i < moves.length ? moves[i] : '(none)';
    final cp = i < scores.length ? scores[i] : scoreCp;
    return EngineSearch(
      bestMoveUci: move,
      elapsedMs: i < elapsedMs.length ? elapsedMs[i] : defaultElapsedMs,
      scoreCp: scoreMate == null ? cp : null,
      scoreMate: scoreMate,
      depth: 8,
    );
  }

  @override
  Future<void> quit() async => _alive = false;

  @override
  void dispose() => _alive = false;
}

EngineParticipant _participant(
  int index,
  PlayingEngine engine, {
  String? name,
}) => EngineParticipant(
  index: index,
  spec: EngineSpec(
    id: 'e$index',
    name: name ?? (index == 0 ? 'Alpha' : 'Beta'),
    executablePath: '/bin/e$index',
  ),
  engine: engine,
);

GamePgnContext _context({
  String fen = kStandardStartFen,
  TimeControl timeControl = const TimeControl.perMove(100),
  String openingLabel = '',
}) => GamePgnContext(
  event: 'Arbiter test',
  site: 'Test',
  round: 3,
  startFen: fen,
  timeControl: timeControl,
  openingLabel: openingLabel,
);

/// Every rule off except the ones a test turns on, and a ceiling low enough
/// that a scripted shuffle cannot run away.
const AdjudicationRules _noRules = AdjudicationRules(
  drawEnabled: false,
  resignEnabled: false,
  threefoldRepetition: false,
  fiftyMoveRule: false,
  maxMoves: 60,
);

List<String> _shuffle(String out, String home, int plies) => [
  for (var i = 0; i < plies; i++) i.isEven ? out : home,
];

Future<PlayedGame> _play({
  required _Engine white,
  required _Engine black,
  GamePgnContext? context,
  AdjudicationRules rules = _noRules,
  void Function(GameMoveEvent)? onMove,
}) => const EngineGameRunner().play(
  white: _participant(0, white),
  black: _participant(1, black),
  context: context ?? _context(),
  adjudication: rules,
  startedAt: DateTime(2026, 9, 8, 10, 30),
  onMove: onMove,
);

void main() {
  group('natural endings the base tests do not reach', () {
    test('stalemate is a draw with the right termination', () async {
      // Kg6 + Qf1 against a bare Kh8: Qf7 leaves Black no move and no check.
      final game = await _play(
        white: _Engine(['f1f7']),
        black: _Engine(const []),
        context: _context(fen: '7k/8/6K1/8/8/8/8/5Q2 w - - 0 1'),
      );
      expect(game.result, GameResult.draw);
      expect(game.termination, TerminationReason.stalemate);
      expect(game.plies, 1);
      expect(game.pgn, contains('[Result "1/2-1/2"]'));
      expect(game.pgn, contains('[Termination "normal"]'));
      expect(game.pgn.trimRight(), endsWith('1/2-1/2'));
    });

    test('capturing down to a bare minor piece ends the game', () async {
      final game = await _play(
        white: _Engine(['h1g3']),
        black: _Engine(['e8d8']),
        context: _context(fen: '4k3/8/8/8/8/6p1/8/4K2N w - - 0 1'),
      );
      expect(game.result, GameResult.draw);
      expect(game.termination, TerminationReason.insufficientMaterial);
      expect(game.sanMoves, ['Nxg3']);
    });

    test('a start position that is already over asks nobody to move', () async {
      // The final position of the fool's mate, White to move and mated.
      const fen =
          'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3';
      final white = _Engine(['a2a3']);
      final black = _Engine(['a7a6']);
      final game = await _play(
        white: white,
        black: black,
        context: _context(fen: fen),
      );
      expect(game.result, GameResult.blackWins);
      expect(game.termination, TerminationReason.checkmate);
      expect(game.plies, 0);
      expect(white.receivedMoves, isEmpty);
      expect(black.receivedMoves, isEmpty);
      expect(game.pgn, contains('[FEN "$fen"]'));
      expect(game.pgn.split('\n\n').last.trim(), '{Checkmate} 0-1');
    });
  });

  group('what a misbehaving engine costs', () {
    test('"bestmove (none)" in a live position loses for that side', () async {
      final game = await _play(
        white: _Engine(['e2e4', 'g1f3']),
        black: _Engine(const []),
      );
      expect(game.result, GameResult.whiteWins);
      expect(game.termination, TerminationReason.illegalMove);
      expect(game.detail, contains('Beta'));
      expect(game.detail, contains('(none)'));
      expect(game.plies, 1);
    });

    test('Black dying before the first move is a loss for Black', () async {
      final white = _Engine(['e2e4']);
      final black = _Engine(['e7e5'], failNewGame: true);
      final game = await _play(white: white, black: black);
      expect(game.result, GameResult.whiteWins);
      expect(game.termination, TerminationReason.engineFailure);
      expect(game.detail, startsWith('Beta:'));
      expect(game.plies, 0);
      expect(white.newGameCalls, 1);
      expect(white.receivedMoves, isEmpty);
    });

    test('Black flagging on the clock is a win for White', () async {
      final game = await _play(
        white: _Engine(_shuffle('g1f3', 'f3g1', 4)),
        black: _Engine(_shuffle('g8f6', 'f6g8', 4), defaultElapsedMs: 3000),
        context: _context(timeControl: const TimeControl.clock(baseMs: 2000)),
      );
      expect(game.result, GameResult.whiteWins);
      expect(game.termination, TerminationReason.timeForfeit);
      expect(game.detail, startsWith('Beta used 3.0s'));
      expect(game.plies, 1);
    });

    test(
      'a pawn reaching the last rank without a promotion piece is illegal',
      () async {
        // BUG (see report): dartchess `isLegal` accepts `a7a8` with no
        // promotion and `playUnchecked` leaves a pawn standing on a8. Before
        // the fix the arbiter accepted the move, put an unpromotable pawn on
        // the eighth rank, and wrote `a8` — not `a8=Q` — into the PGN.
        final game = await _play(
          white: _Engine(['a7a8']),
          black: _Engine(['h7h6']),
          context: _context(fen: '8/P6k/8/8/8/8/8/4K3 w - - 0 1'),
        );
        expect(game.termination, TerminationReason.illegalMove);
        expect(game.result, GameResult.blackWins);
        expect(game.detail, contains('a7a8'));
        expect(game.plies, 0);
      },
    );

    test('a promotion with a piece is played and forwarded as sent', () async {
      final black = _Engine(['h7h6']);
      final game = await _play(
        white: _Engine(['a7a8q']),
        black: black,
        context: _context(fen: '8/P6k/8/8/8/8/8/4K3 w - - 0 1'),
      );
      expect(game.sanMoves.first, 'a8=Q');
      expect(black.receivedMoves.first, ['a7a8q']);
    });
  });

  group('the wire', () {
    test('king-takes-rook castling goes to the opponent as e1g1', () async {
      // dartchess spells castling as king-takes-own-rook; a standard engine
      // replaying `position … moves e1h1` would reject it.
      final black = _Engine(['e8c8']);
      final white = _Engine(['e1h1', 'a1a2']);
      final game = await _play(
        white: white,
        black: black,
        context: _context(fen: 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1'),
      );
      expect(game.sanMoves.take(2), ['O-O', 'O-O-O']);
      expect(black.receivedMoves.first, ['e1g1']);
      // The two-squares spelling an ordinary engine sends passes through.
      expect(white.receivedMoves[1], ['e1g1', 'e8c8']);
    });

    test('per-move control sends movetime and no clocks', () async {
      final white = _Engine(['e2e4']);
      final events = <GameMoveEvent>[];
      await _play(
        white: white,
        black: _Engine(const []),
        context: _context(timeControl: const TimeControl.perMove(250)),
        onMove: events.add,
      );
      final limits = white.receivedLimits.single;
      expect(limits.toCommand(), 'go movetime 250');
      expect(events.single.whiteClockMs, isNull);
      expect(events.single.blackClockMs, isNull);
    });

    test('fixed depth never forfeits, however slow', () async {
      final white = _Engine(['e2e4', 'g1f3'], defaultElapsedMs: 120000);
      final game = await _play(
        white: white,
        black: _Engine(['e7e5']),
        context: _context(timeControl: const TimeControl.fixedDepth(7)),
      );
      expect(white.receivedLimits.first.toCommand(), 'go depth 7');
      expect(game.termination, TerminationReason.illegalMove);
      expect(game.plies, 3);
    });
  });

  group('the clock', () {
    test('increment, session refill and movestogo all line up', () async {
      final white = _Engine(_shuffle('g1f3', 'f3g1', 6), defaultElapsedMs: 100);
      final black = _Engine(_shuffle('g8f6', 'f6g8', 6), defaultElapsedMs: 100);
      final whiteClocks = <int?>[];
      await _play(
        white: white,
        black: black,
        context: _context(
          timeControl: const TimeControl.clock(
            baseMs: 1000,
            incrementMs: 50,
            movesPerSession: 2,
          ),
        ),
        rules: _noRules.copyWith(maxMoves: 3),
        onMove: (e) {
          if (e.byWhite) whiteClocks.add(e.whiteClockMs);
        },
      );
      // 1000 → -100 +50 = 950; → 900, then the session refill of 1000; → 1850.
      expect(whiteClocks, [950, 1900, 1850]);
      expect(white.receivedLimits.map((l) => l.whiteTimeMs), [1000, 950, 1900]);
      expect(white.receivedLimits.map((l) => l.movesToGo), [2, 1, 2]);
      expect(white.receivedLimits.first.whiteIncrementMs, 50);
      // Black's clock is untouched by White's thinking.
      expect(white.receivedLimits.map((l) => l.blackTimeMs), [1000, 950, 1900]);
    });

    test(
      'overspending inside the margin empties the clock, not the game',
      () async {
        final events = <GameMoveEvent>[];
        final game = await _play(
          white: _Engine(['e2e4', 'g1f3'], elapsedMs: const [1400, 10]),
          black: _Engine(['e7e5', 'b8c6']),
          context: _context(
            timeControl: const TimeControl.clock(
              baseMs: 1000,
              incrementMs: 100,
            ),
          ),
          onMove: events.add,
        );
        expect(game.termination, isNot(TerminationReason.timeForfeit));
        // -400 ms is inside the 500 ms margin: the clock floors at 0 + increment.
        expect(events.first.whiteClockMs, 100);
        expect(events[2].whiteClockMs, 190);
      },
    );

    test('a clock that has hit zero is still sent as 1 ms, never 0', () async {
      final white = _Engine(['e2e4', 'g1f3'], elapsedMs: const [1100, 10]);
      await _play(
        white: white,
        black: _Engine(['e7e5', 'b8c6']),
        context: _context(timeControl: const TimeControl.clock(baseMs: 1000)),
      );
      // Sudden death, no increment: 1000 − 1100 floors at 0, sent as 1.
      expect(white.receivedLimits[1].whiteTimeMs, 1);
    });
  });

  group('adjudication corners', () {
    test('a draw waits for the move number even with the streak met', () async {
      final game = await _play(
        white: _Engine(_shuffle('g1f3', 'f3g1', 30)),
        black: _Engine(_shuffle('g8f6', 'f6g8', 30)),
        rules: _noRules.copyWith(
          drawEnabled: true,
          drawMoveNumber: 10,
          drawMoveCount: 1,
        ),
      );
      expect(game.termination, TerminationReason.drawAdjudication);
      // Move 10 is reached after Black's ninth move.
      expect(game.plies, 18);
    });

    test('a pawn move restarts the draw count', () async {
      final game = await _play(
        white: _Engine(['e2e4', 'g1f3', 'f3g1', 'g1f3']),
        black: _Engine(_shuffle('g8f6', 'f6g8', 4)),
        rules: _noRules.copyWith(
          drawEnabled: true,
          drawMoveNumber: 1,
          drawMoveCount: 2,
        ),
      );
      expect(game.termination, TerminationReason.drawAdjudication);
      // Four quiet plies are needed; e4 does not count, so the fifth ends it.
      expect(game.plies, 5);
    });

    test('announced mates resign the game through the cp axis', () async {
      final game = await _play(
        white: _Engine(_shuffle('g1f3', 'f3g1', 10), scoreMate: -4),
        black: _Engine(_shuffle('g8f6', 'f6g8', 10), scoreMate: 4),
        rules: _noRules.copyWith(resignEnabled: true, resignMoveCount: 2),
      );
      expect(game.result, GameResult.blackWins);
      expect(game.termination, TerminationReason.resignAdjudication);
      // White's second losing move is ply 3; Black's second winning move is
      // ply 4; White's next move is the first at which both streaks hold.
      expect(game.plies, 5);
    });

    test('one-sided resignation needs only the loser\'s word', () async {
      final game = await _play(
        white: _Engine(_shuffle('g1f3', 'f3g1', 10), scoreCp: -1500),
        black: _Engine(_shuffle('g8f6', 'f6g8', 10), scoreCp: 0),
        rules: _noRules.copyWith(
          resignEnabled: true,
          resignMoveCount: 2,
          twoSidedResign: false,
        ),
      );
      expect(game.result, GameResult.blackWins);
      expect(game.termination, TerminationReason.resignAdjudication);
      expect(game.plies, 3);
    });

    test('one hopeful score breaks the losing streak', () async {
      final game = await _play(
        white: _Engine(
          _shuffle('g1f3', 'f3g1', 12),
          scores: const [-1500, -1500, 0, -1500, -1500, -1500],
        ),
        black: _Engine(_shuffle('g8f6', 'f6g8', 12)),
        rules: _noRules.copyWith(
          resignEnabled: true,
          resignMoveCount: 3,
          twoSidedResign: false,
        ),
      );
      expect(game.termination, TerminationReason.resignAdjudication);
      // Without the reset the third bad score (ply 5) would have ended it.
      expect(game.plies, 11);
    });
  });

  group('PGN and events', () {
    test('move numbers count from the start FEN, Black first', () async {
      final seen = <String>[];
      await _play(
        white: _Engine(['e5d4']),
        black: _Engine(['d8d6', 'd6e6']),
        context: _context(
          fen: '3r2k1/p4p2/7p/3pB1p1/8/P3P2P/1P3PP1/6K1 b - - 0 31',
        ),
        onMove: (e) => seen.add('${e.ply}:${e.moveNumber}:${e.byWhite}'),
      );
      expect(seen, ['1:31:false', '2:32:true', '3:32:false']);
    });

    test(
      'headers carry the count, control, opening and escaped names',
      () async {
        final game = await const EngineGameRunner().play(
          white: _participant(0, _Engine(['e2e4', 'g1f3']), name: 'Say "hi"'),
          black: _participant(1, _Engine(['e7e5']), name: r'C:\sf'),
          context: _context(
            timeControl: const TimeControl.clock(
              baseMs: 60000,
              incrementMs: 600,
              movesPerSession: 40,
            ),
            openingLabel: 'Open game',
          ),
          adjudication: _noRules,
          startedAt: DateTime(2026, 9, 8),
        );
        expect(game.pgn, contains(r'[White "Say \"hi\""]'));
        expect(game.pgn, contains(r'[Black "C:\\sf"]'));
        expect(game.pgn, contains('[Round "3"]'));
        expect(game.pgn, contains('[Date "2026.09.08"]'));
        expect(game.pgn, contains('[TimeControl "40/60+0.6"]'));
        expect(game.pgn, contains('[Opening "Open game"]'));
        expect(game.pgn, contains('[PlyCount "3"]'));
        expect(game.pgn, contains('[Termination "rules infraction"]'));
      },
    );

    test(
      'an unplayable start FEN is filed as aborted without a crash',
      () async {
        final white = _Engine(['e2e4']);
        final game = await _play(
          white: white,
          black: _Engine(['e7e5']),
          context: _context(fen: 'this is not a fen'),
        );
        expect(game.result, GameResult.unfinished);
        expect(game.termination, TerminationReason.aborted);
        expect(game.detail, startsWith('unplayable start position'));
        expect(white.newGameCalls, 0);
        expect(game.pgn, isNot(contains('[FEN ')));
        expect(game.pgn.trimRight(), endsWith('*'));
      },
    );
  });
}
