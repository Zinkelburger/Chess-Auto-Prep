import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/adjudication_rules.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/time_control.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_game.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/engine_game_runner.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/uci_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// An engine that plays from a fixed list of moves and reports a fixed score.
///
/// Everything the arbiter decides — mate, repetition, adjudication, forfeits
/// — is a function of the moves and scores it is handed, so a scripted
/// opponent is enough to pin all of it down without a process in sight.
class _ScriptedEngine implements PlayingEngine {
  _ScriptedEngine(
    this.moves, {
    this.scoreCp = 0,
    this.scoreMate,
    this.elapsedMs = 10,
    this.failOnMove,
  });

  final List<String> moves;
  final int scoreCp;
  final int? scoreMate;
  final int elapsedMs;

  /// 0-based index of this engine's own move at which it dies.
  final int? failOnMove;

  int _index = 0;
  bool _alive = true;

  @override
  bool get isAlive => _alive;

  @override
  Future<void> newGame() async {}

  @override
  Future<EngineSearch> search({
    required String startFen,
    required List<String> movesUci,
    required GoLimits limits,
    required Duration hardLimit,
  }) async {
    if (failOnMove != null && _index >= failOnMove!) {
      _alive = false;
      throw UciFailure('scripted failure');
    }
    final move = _index < moves.length ? moves[_index] : '(none)';
    _index++;
    return EngineSearch(
      bestMoveUci: move,
      elapsedMs: elapsedMs,
      scoreCp: scoreMate == null ? scoreCp : null,
      scoreMate: scoreMate,
      depth: 12,
    );
  }

  @override
  Future<void> quit() async => _alive = false;

  @override
  void dispose() => _alive = false;
}

EngineParticipant _participant(int index, PlayingEngine engine) =>
    EngineParticipant(
      index: index,
      spec: EngineSpec(
        id: 'e$index',
        name: index == 0 ? 'White engine' : 'Black engine',
        executablePath: '/bin/e$index',
      ),
      engine: engine,
    );

GamePgnContext _context({
  String fen = kStandardStartFen,
  TimeControl timeControl = const TimeControl.perMove(100),
  bool annotateMoves = false,
}) => GamePgnContext(
  event: 'Test match',
  site: 'Test',
  round: 1,
  startFen: fen,
  timeControl: timeControl,
  annotateMoves: annotateMoves,
);

Future<PlayedGame> _play({
  required List<String> whiteMoves,
  required List<String> blackMoves,
  AdjudicationRules rules = AdjudicationRules.none,
  int whiteScore = 0,
  int blackScore = 0,
  int? whiteMate,
  int whiteElapsedMs = 10,
  int? whiteFailsOnMove,
  String fen = kStandardStartFen,
  TimeControl timeControl = const TimeControl.perMove(100),
  bool annotateMoves = false,
}) {
  return const EngineGameRunner().play(
    white: _participant(
      0,
      _ScriptedEngine(
        whiteMoves,
        scoreCp: whiteScore,
        scoreMate: whiteMate,
        elapsedMs: whiteElapsedMs,
        failOnMove: whiteFailsOnMove,
      ),
    ),
    black: _participant(1, _ScriptedEngine(blackMoves, scoreCp: blackScore)),
    context: _context(
      fen: fen,
      timeControl: timeControl,
      annotateMoves: annotateMoves,
    ),
    adjudication: rules,
    startedAt: DateTime(2026, 8, 22),
  );
}

/// Knights out and back, forever — the cheapest legal way to make nothing
/// happen.
List<String> _shuffle(String out, String home, int plies) => [
  for (var i = 0; i < plies; i++) i.isEven ? out : home,
];

void main() {
  group('natural endings', () {
    test('checkmate ends the game and names the winner', () async {
      final game = await _play(
        whiteMoves: ['f2f3', 'g2g4'],
        blackMoves: ['e7e5', 'd8h4'],
      );
      expect(game.result, GameResult.blackWins);
      expect(game.termination, TerminationReason.checkmate);
      expect(game.sanMoves.last, 'Qh4#');
      expect(game.pgn, contains('[Result "0-1"]'));
      expect(game.pgn, contains('[Termination "normal"]'));
      expect(game.pgn.trimRight(), endsWith('0-1'));
    });

    test('a threefold repetition is a draw', () async {
      final game = await _play(
        whiteMoves: _shuffle('g1f3', 'f3g1', 8),
        blackMoves: _shuffle('g8f6', 'f6g8', 8),
        rules: const AdjudicationRules(
          drawEnabled: false,
          resignEnabled: false,
        ),
      );
      expect(game.result, GameResult.draw);
      expect(game.termination, TerminationReason.threefoldRepetition);
      // Start, then two more occurrences: the eighth ply completes the third.
      expect(game.plies, 8);
    });

    test('a hundred quiet plies is a fifty-move draw', () async {
      final game = await _play(
        whiteMoves: _shuffle('g1f3', 'f3g1', 50),
        blackMoves: _shuffle('g8f6', 'f6g8', 50),
        rules: const AdjudicationRules(
          drawEnabled: false,
          resignEnabled: false,
          threefoldRepetition: false,
        ),
      );
      expect(game.result, GameResult.draw);
      expect(game.termination, TerminationReason.fiftyMoveRule);
      expect(game.plies, 100);
    });
  });

  group('adjudication', () {
    test('level scores for long enough are called a draw', () async {
      final game = await _play(
        whiteMoves: _shuffle('g1f3', 'f3g1', 8),
        blackMoves: _shuffle('g8f6', 'f6g8', 8),
        rules: const AdjudicationRules(
          drawMoveNumber: 1,
          drawMoveCount: 2,
          resignEnabled: false,
          threefoldRepetition: false,
        ),
      );
      expect(game.result, GameResult.draw);
      expect(game.termination, TerminationReason.drawAdjudication);
      expect(game.plies, 4);
      expect(game.pgn, contains('[Termination "adjudication"]'));
    });

    test('a lost position both engines agree on is resigned', () async {
      final game = await _play(
        whiteMoves: _shuffle('g1f3', 'f3g1', 8),
        blackMoves: _shuffle('g8f6', 'f6g8', 8),
        whiteScore: -1200,
        blackScore: 1200,
        rules: const AdjudicationRules(
          drawEnabled: false,
          resignMoveCount: 2,
          resignScoreCp: 900,
          threefoldRepetition: false,
        ),
      );
      expect(game.result, GameResult.blackWins);
      expect(game.termination, TerminationReason.resignAdjudication);
    });

    test('one engine\'s pessimism alone does not end the game', () async {
      final game = await _play(
        whiteMoves: _shuffle('g1f3', 'f3g1', 8),
        blackMoves: _shuffle('g8f6', 'f6g8', 8),
        whiteScore: -1200,
        // Black does not believe it is winning, so two-sided resign holds.
        blackScore: 0,
        rules: const AdjudicationRules(
          drawEnabled: false,
          resignMoveCount: 2,
          resignScoreCp: 900,
        ),
      );
      expect(game.termination, TerminationReason.threefoldRepetition);
    });

    test('a forced mate is never mistaken for a level position', () async {
      // White shuffles while announcing mate against itself; a draw call
      // here would throw away a decided game.
      final game = await _play(
        whiteMoves: _shuffle('g1f3', 'f3g1', 8),
        blackMoves: _shuffle('g8f6', 'f6g8', 8),
        whiteMate: -3,
        rules: const AdjudicationRules(
          drawMoveNumber: 1,
          drawMoveCount: 2,
          resignEnabled: false,
          threefoldRepetition: false,
          fiftyMoveRule: false,
          maxMoves: 6,
        ),
      );
      expect(game.termination, isNot(TerminationReason.drawAdjudication));
      expect(game.termination, TerminationReason.maxMoves);
    });

    test('the move ceiling stops a game that will not end', () async {
      final game = await _play(
        whiteMoves: _shuffle('g1f3', 'f3g1', 20),
        blackMoves: _shuffle('g8f6', 'f6g8', 20),
        rules: const AdjudicationRules(
          drawEnabled: false,
          resignEnabled: false,
          threefoldRepetition: false,
          fiftyMoveRule: false,
          maxMoves: 5,
        ),
      );
      expect(game.result, GameResult.draw);
      expect(game.termination, TerminationReason.maxMoves);
      expect(game.plies, 10);
    });
  });

  group('misbehaviour is a loss, not a crash', () {
    test('an illegal move forfeits the game', () async {
      final game = await _play(whiteMoves: ['e2e5'], blackMoves: ['e7e5']);
      expect(game.result, GameResult.blackWins);
      expect(game.termination, TerminationReason.illegalMove);
      expect(game.detail, contains('e2e5'));
      expect(game.plies, 0);
    });

    test('an engine that dies loses', () async {
      final game = await _play(
        whiteMoves: ['e2e4', 'g1f3'],
        blackMoves: ['e7e5', 'g8f6'],
        whiteFailsOnMove: 1,
      );
      expect(game.result, GameResult.blackWins);
      expect(game.termination, TerminationReason.engineFailure);
      expect(game.detail, contains('scripted failure'));
    });

    test('blowing the per-move budget is a time forfeit', () async {
      final game = await _play(
        whiteMoves: ['e2e4'],
        blackMoves: ['e7e5'],
        // 175% of 100 ms plus the margin is the ceiling; 5 s is not close.
        whiteElapsedMs: 5000,
      );
      expect(game.result, GameResult.blackWins);
      expect(game.termination, TerminationReason.timeForfeit);
      expect(game.pgn, contains('[Termination "time forfeit"]'));
    });

    test('a clock that runs out is a time forfeit', () async {
      final game = await _play(
        whiteMoves: ['e2e4', 'g1f3'],
        blackMoves: ['e7e5', 'g8f6'],
        whiteElapsedMs: 3000,
        timeControl: const TimeControl.clock(baseMs: 2000),
      );
      expect(game.termination, TerminationReason.timeForfeit);
      expect(game.result, GameResult.blackWins);
    });
  });

  group('PGN', () {
    test('a mid-game start emits FEN/SetUp and numbers from there', () async {
      const fen = '3r2k1/p4p2/7p/3pB1p1/8/P3P2P/1P3PP1/6K1 b - - 0 1';
      final game = await _play(
        whiteMoves: ['e5d4'],
        blackMoves: ['d8d6', 'd6e6'],
        fen: fen,
        rules: const AdjudicationRules(
          drawEnabled: false,
          resignEnabled: false,
        ),
      );
      expect(game.pgn, contains('[FEN "$fen"]'));
      expect(game.pgn, contains('[SetUp "1"]'));
      // Black moves first from this position, so the movetext opens `1...`.
      expect(game.pgn, contains('1... Rd6'));
      expect(game.pgn, contains('2. Bd4'));
    });

    test('the standard start needs no FEN header', () async {
      final game = await _play(
        whiteMoves: ['f2f3', 'g2g4'],
        blackMoves: ['e7e5', 'd8h4'],
      );
      expect(game.pgn, isNot(contains('[FEN ')));
      expect(game.pgn, contains('1. f3'));
    });

    test('each move carries the score, depth, and time when asked', () async {
      final game = await _play(
        whiteMoves: ['e2e4'],
        blackMoves: ['e7e5'],
        whiteScore: 31,
        whiteFailsOnMove: 1,
        annotateMoves: true,
      );
      expect(game.pgn, contains('e4 {+0.31/12 0.010s}'));
    });

    test('by default no move carries a comment', () async {
      final game = await _play(
        whiteMoves: ['e2e4', 'g1f3'],
        blackMoves: ['e7e5', 'b8c6'],
        whiteScore: 31,
        whiteFailsOnMove: 2,
      );
      final movetext = game.pgn.split('\n\n').last;
      expect(movetext, contains('1. e4 e5 2. Nf3 Nc6'));
      expect(movetext, isNot(contains('0.010s')));
    });

    test('the reason the game stopped leads the movetext', () async {
      final game = await _play(whiteMoves: ['e2e5'], blackMoves: const []);
      expect(game.pgn, contains('{Illegal move: White engine played "e2e5"'));
    });

    test('a failure message cannot break out of its comment', () async {
      // Engine failure details carry raw stderr, which is where stray braces
      // and newlines come from.
      final game = await const EngineGameRunner().play(
        white: _participant(0, _ScriptedEngine(const [], failOnMove: 0)),
        black: _participant(1, _ScriptedEngine(const [])),
        context: _context(),
        adjudication: AdjudicationRules.none,
      );
      final movetext = game.pgn.split('\n\n').last;
      expect(movetext.indexOf('{'), movetext.lastIndexOf('{'));
      expect(movetext.indexOf('}'), movetext.lastIndexOf('}'));
      expect(movetext.indexOf('{'), lessThan(movetext.indexOf('}')));
    });
  });

  test('every move is reported as it is played', () async {
    final seen = <String>[];
    await const EngineGameRunner().play(
      white: _participant(0, _ScriptedEngine(['f2f3', 'g2g4'])),
      black: _participant(1, _ScriptedEngine(['e7e5', 'd8h4'])),
      context: _context(),
      adjudication: AdjudicationRules.none,
      onMove: (move) => seen.add('${move.ply}:${move.moveNumber}:${move.san}'),
    );
    expect(seen, ['1:1:f3', '2:1:e5', '3:2:g4', '4:2:Qh4#']);
  });

  test('cancelling stops the game where it stands', () async {
    var moves = 0;
    final game = await const EngineGameRunner().play(
      white: _participant(0, _ScriptedEngine(_shuffle('g1f3', 'f3g1', 20))),
      black: _participant(1, _ScriptedEngine(_shuffle('g8f6', 'f6g8', 20))),
      context: _context(),
      adjudication: AdjudicationRules.none,
      onMove: (_) => moves++,
      isCancelled: () => moves >= 3,
    );
    expect(game.result, GameResult.unfinished);
    expect(game.termination, TerminationReason.aborted);
    expect(game.plies, 3);
    expect(game.pgn.trimRight(), endsWith('*'));
  });
}
