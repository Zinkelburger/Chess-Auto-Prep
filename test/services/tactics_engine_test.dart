import 'dart:async';
import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/services/tactics_database.dart';
import 'package:chess_auto_prep/services/tactics_engine.dart';
import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/services/engine/eval_worker.dart';
import 'package:chess_auto_prep/services/maia_factory.dart';
import 'package:chess_auto_prep/services/maia_service.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Test fixtures ────────────────────────────────────────────────────────────

const _scholarsMateFen =
    'r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

const _afterE4E5Nf3Nc6 =
    'r1bqkb1r/pppp1ppp/2n2n2/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 4';

TacticsPosition _position({
  required String fen,
  required List<String> correctLine,
}) {
  return TacticsPosition(
    fen: fen,
    userMove: '??',
    correctLine: correctLine,
    mistakeType: '??',
    mistakeAnalysis: 'test',
    positionContext: 'Move 1, White to play',
    gameWhite: 'White',
    gameBlack: 'Black',
    gameResult: '1-0',
    gameDate: '2024.01.01',
    gameId: 'test',
  );
}

// ── Mock MaiaEvaluator ───────────────────────────────────────────────────────

/// A controllable Maia evaluator for unit tests.
///
/// Call [enqueue] to set the policy that will be returned for the next
/// [evaluate] call. Policies are consumed in FIFO order.
class MockMaiaEvaluator implements MaiaEvaluator {
  final _results = <MaiaResult>[];

  void enqueue(Map<String, double> policy, {double winProb = 0.5}) {
    _results.add(MaiaResult(policy: policy, winProbability: winProb));
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<MaiaResult> evaluate(String fen, int elo) async {
    if (_results.isEmpty) {
      return const MaiaResult(policy: {}, winProbability: 0.5);
    }
    return _results.removeAt(0);
  }

  @override
  void dispose() {}
}

/// Noop engine connection whose stdout never emits.
class _DummyConnection implements EngineConnection {
  @override
  Stream<String> get stdout => const Stream.empty();
  @override
  Future<void> waitForReady() async {}
  @override
  void sendCommand(String command) {}
  @override
  void dispose() {}
}

/// Minimal stub for EvalWorker that returns a canned PV from [evaluateFen].
class _StubEvalWorker extends EvalWorker {
  final List<EvalResult> _evalResults = [];

  _StubEvalWorker() : super(_DummyConnection());

  void enqueue(EvalResult result) => _evalResults.add(result);

  @override
  Future<EvalResult> evaluateFen(String fen, int depth) async {
    if (_evalResults.isEmpty) {
      return EvalResult(scoreCp: 0, pv: const [], depth: depth);
    }
    return _evalResults.removeAt(0);
  }
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late TacticsEngine engine;

  setUp(() {
    engine = TacticsEngine();
  });

  group('TacticsEngine.checkMoveAtIndex', () {
    test('returns correct for mate-in-1 from non-start FEN', () {
      final position = _position(
        fen: _scholarsMateFen,
        correctLine: const ['Qxf7#'],
      );

      final result = engine.checkMoveAtIndex(
        position,
        'h5f7',
        _scholarsMateFen,
        0,
      );

      expect(result, TacticsResult.correct);
    });

    test('returns correct for first move of multi-move puzzle', () {
      final position = _position(
        fen: _startFen,
        correctLine: const ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4'],
      );

      final result = engine.checkMoveAtIndex(position, 'e2e4', _startFen, 0);

      expect(result, TacticsResult.correct);
    });

    test('returns correct for last move of multi-move puzzle', () {
      final position = _position(
        fen: _startFen,
        correctLine: const ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4'],
      );

      final result = engine.checkMoveAtIndex(
        position,
        'f1c4',
        _afterE4E5Nf3Nc6,
        4,
      );

      expect(result, TacticsResult.correct);
    });

    test('returns incorrect for wrong move', () {
      final position = _position(
        fen: _scholarsMateFen,
        correctLine: const ['Qxf7#'],
      );

      final result = engine.checkMoveAtIndex(
        position,
        'h5h4',
        _scholarsMateFen,
        0,
      );

      expect(result, TacticsResult.incorrect);
    });

    test('returns incorrect for illegal move string', () {
      final position = _position(fen: _startFen, correctLine: const ['e4']);

      expect(
        engine.checkMoveAtIndex(position, 'e2e9', _startFen, 0),
        TacticsResult.incorrect,
      );
      expect(
        engine.checkMoveAtIndex(position, 'abc', _startFen, 0),
        TacticsResult.incorrect,
      );
    });

    test('handles UCI format (e2e4) and SAN format (e4) equivalently', () {
      final uciPosition = _position(
        fen: _startFen,
        correctLine: const ['e2e4'],
      );
      final sanPosition = _position(fen: _startFen, correctLine: const ['e4']);

      expect(
        engine.checkMoveAtIndex(uciPosition, 'e2e4', _startFen, 0),
        TacticsResult.correct,
      );
      expect(
        engine.checkMoveAtIndex(sanPosition, 'e2e4', _startFen, 0),
        TacticsResult.correct,
      );
    });

    test('is insensitive to check/mate annotations (Qh7 vs Qh7+ vs Qh7#)', () {
      for (final expected in ['Qxf7', 'Qxf7+', 'Qxf7#']) {
        final annotated = _position(
          fen: _scholarsMateFen,
          correctLine: [expected],
        );
        expect(
          engine.checkMoveAtIndex(annotated, 'h5f7', _scholarsMateFen, 0),
          TacticsResult.correct,
          reason: 'expected SAN $expected should accept h5f7',
        );
      }
    });

    test(
      'moveIndex out of range always returns incorrect without side effects',
      () {
        final position = _position(fen: _startFen, correctLine: const ['e4']);

        expect(
          engine.checkMoveAtIndex(position, 'e2e4', _startFen, 1),
          TacticsResult.incorrect,
        );
        expect(position.correctLine, ['e4']);
      },
    );
  });

  group('TacticsEngine SAN normalization via checkMoveAtIndex', () {
    test('strips +, #, !, ? annotations from expected SAN', () {
      const fenAfterE4E5 =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2';

      for (final annotated in ['Nf3+', 'Nf3#', 'Nf3!', 'Nf3?', 'Nf3!?']) {
        final position = _position(fen: fenAfterE4E5, correctLine: [annotated]);

        expect(
          engine.checkMoveAtIndex(position, 'g1f3', fenAfterE4E5, 0),
          TacticsResult.correct,
          reason: 'annotation variant $annotated',
        );
      }
    });

    test('preserves piece prefix and coordinates', () {
      const fenAfterE4E5 =
          'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2';

      final position = _position(fen: fenAfterE4E5, correctLine: const ['Nf3']);

      expect(
        engine.checkMoveAtIndex(position, 'g1f3', fenAfterE4E5, 0),
        TacticsResult.correct,
      );
      expect(
        engine.checkMoveAtIndex(position, 'b1c3', fenAfterE4E5, 0),
        TacticsResult.incorrect,
      );
    });

    test(
      'getSolution returns full line after user has finished the puzzle',
      () {
        final position = _position(
          fen: _scholarsMateFen,
          correctLine: const ['Qxf7#'],
        );

        expect(engine.getSolution(position, fromIndex: 1), 'Qxf7#');
      },
    );

    test('correctLineToSan converts UCI and SAN tokens', () {
      final position = _position(
        fen: _startFen,
        correctLine: const ['e2e4', 'e7e5', 'Nf3'],
      );

      expect(engine.correctLineToSan(position), ['e4', 'e5', 'Nf3']);
    });

    test('empty expected SAN never matches a legal move', () {
      final position = _position(fen: _startFen, correctLine: const ['']);

      expect(
        engine.checkMoveAtIndex(position, 'e2e4', _startFen, 0),
        TacticsResult.incorrect,
      );
    });
  });

  // ── buildTrainableLine fallback (no Maia) ──────────────────────────────────

  group('buildTrainableLine fallback (no Maia)', () {
    test('keeps tactical combos up to max user moves', () async {
      const pv = ['Nxe5', 'dxe5', 'Qh5+', 'g6', 'Qxh7#'];
      expect(await TacticsEngine.buildTrainableLine(pv), [
        'Nxe5',
        'dxe5',
        'Qh5+',
        'g6',
        'Qxh7#',
      ]);
    });

    test('stops when next user move is quiet', () async {
      const pv = ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4'];
      expect(await TacticsEngine.buildTrainableLine(pv), ['e4']);
    });

    test('returns empty list for empty PV', () async {
      expect(await TacticsEngine.buildTrainableLine([]), isEmpty);
    });

    test('single-move PV returns that move', () async {
      expect(await TacticsEngine.buildTrainableLine(['Nf3']), ['Nf3']);
    });
  });

  // ── buildTrainableLine with Maia ───────────────────────────────────────────

  group('buildTrainableLine with Maia', () {
    late MockMaiaEvaluator mockMaia;

    setUp(() {
      mockMaia = MockMaiaEvaluator();
    });

    test('agreement path extends from PV', () async {
      // PV: e4 e5 Nf3 (user=e4, opp=e5, user=Nf3)
      // Maia says e7e5 at 90% for the opponent reply — matches PV[1]
      mockMaia.enqueue({'e7e5': 0.90, 'd7d5': 0.05, 'c7c5': 0.05});

      final line = await TacticsEngine.buildTrainableLine(
        ['e4', 'e5', 'Nf3'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: _startFen,
      );

      expect(line, ['e4', 'e5', 'Nf3']);
    });

    test('agreement path chains multiple extensions up to 6 ply', () async {
      // Start position, PV = [d4, d5, c4, dxc4, e3]
      // After d4: black to play, Maia top = d7d5 at 92% → matches PV d5
      // After d4 d5 c4: black to play, Maia top = d5c4 at 88% → matches PV dxc4
      mockMaia.enqueue({'d7d5': 0.92, 'g8f6': 0.04, 'e7e6': 0.04});
      mockMaia.enqueue({'d5c4': 0.88, 'e7e6': 0.06, 'c7c6': 0.06});

      final line = await TacticsEngine.buildTrainableLine(
        ['d4', 'd5', 'c4', 'dxc4', 'e3'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: _startFen,
      );

      expect(line, ['d4', 'd5', 'c4', 'dxc4', 'e3']);
    });

    test('low confidence stops at single move', () async {
      // Maia gives e7e5 at only 40% — below 85% threshold
      mockMaia.enqueue({'e7e5': 0.40, 'd7d5': 0.30, 'c7c5': 0.30});

      final line = await TacticsEngine.buildTrainableLine(
        ['e4', 'e5', 'Nf3'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: _startFen,
      );

      expect(line, ['e4']);
    });

    test('disagreement produces 3-ply tactic with fresh SF eval', () async {
      // PV: e4, e5, Nf3 but Maia says d7d5 at 90% (disagrees with e7e5)
      mockMaia.enqueue({'d7d5': 0.90, 'e7e5': 0.05, 'c7c5': 0.05});

      final stubWorker = _StubEvalWorker();
      // After e4 d5, Stockfish says best reply is e4e5 → but let's say
      // exd5 is best. UCI for exd5 from e4 capturing on d5 is e4d5.
      stubWorker.enqueue(EvalResult(scoreCp: 50, pv: ['e4d5'], depth: 14));

      final line = await TacticsEngine.buildTrainableLine(
        ['e4', 'e5', 'Nf3'],
        maia: mockMaia,
        worker: stubWorker,
        maiaElo: 1500,
        startFen: _startFen,
      );

      // [user: e4, opp(maia): d5, user(SF): exd5]
      expect(line.length, 3);
      expect(line[0], 'e4');
      expect(line[1], 'd5');
      expect(line[2], 'exd5');
    });

    test('disagreement without worker stops at 2 ply', () async {
      // Maia disagrees but no worker available for SF re-eval
      mockMaia.enqueue({'d7d5': 0.90, 'e7e5': 0.05, 'c7c5': 0.05});

      final line = await TacticsEngine.buildTrainableLine(
        ['e4', 'e5', 'Nf3'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: _startFen,
      );

      expect(line, ['e4', 'd5']);
    });

    test('respects maxMaiaLinePly limit', () async {
      // All opponent moves agree at high prob, PV is long
      // Max is 6 ply: 3 user + 2 opponent auto + 1
      mockMaia.enqueue({'d7d5': 0.95, 'e7e6': 0.05});
      mockMaia.enqueue({'d5c4': 0.92, 'e7e6': 0.08});
      mockMaia.enqueue({'b7b5': 0.90, 'e7e6': 0.10});

      final line = await TacticsEngine.buildTrainableLine(
        ['d4', 'd5', 'c4', 'dxc4', 'e3', 'b5', 'a4'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: _startFen,
      );

      expect(line.length, lessThanOrEqualTo(TacticsEngine.maxMaiaLinePly));
    });

    test('empty PV returns empty with Maia', () async {
      final line = await TacticsEngine.buildTrainableLine(
        [],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: _startFen,
      );
      expect(line, isEmpty);
    });

    test('single-move PV returns single move with Maia', () async {
      final line = await TacticsEngine.buildTrainableLine(
        ['e4'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: _startFen,
      );
      expect(line, ['e4']);
    });

    test('Maia returning empty policy stops at single move', () async {
      // Maia returns no moves (edge case)
      mockMaia.enqueue({});

      final line = await TacticsEngine.buildTrainableLine(
        ['e4', 'e5', 'Nf3'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: _startFen,
      );

      expect(line, ['e4']);
    });

    test('agreement then low confidence stops mid-line', () async {
      // First opponent: agrees at 90%
      mockMaia.enqueue({'e7e5': 0.90, 'd7d5': 0.10});
      // Second opponent: low confidence at 40%
      mockMaia.enqueue({'b8c6': 0.40, 'd7d6': 0.30, 'g8f6': 0.30});

      final line = await TacticsEngine.buildTrainableLine(
        ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: _startFen,
      );

      // Extends through first agreement, stops at second
      expect(line, ['e4', 'e5', 'Nf3']);
    });

    test('capture below 85% but above 50% extends the line', () async {
      // After 1.e4 d5, PV: exd5 Qxd5 Nc3
      // Maia says d8d5 (Qxd5 = recapture) at 60% — below 85% but a capture
      const scandinavianFen =
          'rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2';
      mockMaia.enqueue({'d8d5': 0.60, 'g8f6': 0.25, 'e7e6': 0.15});

      final line = await TacticsEngine.buildTrainableLine(
        ['exd5', 'Qxd5', 'Nc3'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: scandinavianFen,
      );

      // Should extend because Qxd5 is a capture (lower threshold applies)
      expect(line, ['exd5', 'Qxd5', 'Nc3']);
    });

    test('non-capture below 85% does NOT extend the line', () async {
      // After e4, Maia says e7e5 at 60% — below 85% and NOT a capture
      mockMaia.enqueue({'e7e5': 0.60, 'd7d5': 0.25, 'c7c5': 0.15});

      final line = await TacticsEngine.buildTrainableLine(
        ['e4', 'e5', 'Nf3'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: _startFen,
      );

      // Should NOT extend because e5 is not a capture
      expect(line, ['e4']);
    });

    test('capture below 50% does NOT extend the line', () async {
      // After 1.e4 d5, Maia says d8d5 (Qxd5) at only 40% — too low even for
      // capture threshold
      const scandinavianFen =
          'rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2';
      mockMaia.enqueue({'d8d5': 0.40, 'g8f6': 0.35, 'e7e6': 0.25});

      final line = await TacticsEngine.buildTrainableLine(
        ['exd5', 'Qxd5', 'Nc3'],
        maia: mockMaia,
        maiaElo: 1500,
        startFen: scandinavianFen,
      );

      // Should NOT extend — even a capture at 40% is below the 50% threshold
      expect(line, ['exd5']);
    });
  });
}
