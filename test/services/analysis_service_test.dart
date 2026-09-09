/// [AnalysisService] driven by a scripted engine: how a side-to-move score
/// for the position *after* a candidate move becomes a White-relative result
/// keyed by that move, what a mating move looks like, and what a cancel or a
/// superseding request leaves behind in the public notifiers.
library;

import 'dart:async';

import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/services/analysis_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show playUciMove;
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/services/engine/board_engine.dart';
import '../support/scripted_engine.dart';

const kInitialFEN = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

/// White to move, Rb8# available; the same with colours swapped.
const _whiteMatesIn1 = '6k1/5ppp/8/8/8/8/5PPP/1R4K1 w - - 0 1';
const _blackMatesIn1 = '1r4k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1';

void main() {
  late ScriptedEngine engine;
  late AnalysisService service;
  late BoardEngine boardEngine;

  /// Script the single-PV answer for the position reached by [uci] from
  /// [baseFen]. Scores are side-to-move relative, as the engine reports them.
  void scriptAfter(String baseFen, String uci, ScriptLine line) {
    final fen = playUciMove(baseFen, uci)!;
    engine.evals[normalizeFen(fen)] = line;
  }

  /// Pump the event loop until [done] holds, failing rather than hanging.
  Future<void> settle(bool Function() done, {String what = 'condition'}) async {
    for (var i = 0; i < 500; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail(
      'timed out waiting for $what; status=${service.poolStatus.value.phase}',
    );
  }

  Future<void> evaluate(String fen, List<String> moves) async {
    await service.startEvaluation(baseFen: fen, moveUcis: moves, evalDepth: 12);
    await settle(
      () => service.poolStatus.value.isComplete,
      what: 'evaluation to complete',
    );
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    // Interactive analysis uses a single injected process.
    EngineSettings.instance.cores = 1;
    engine = ScriptedEngine();
    boardEngine = BoardEngine(createConnection: () async => engine);
    service = AnalysisService.fresh(engine: boardEngine);
  });

  tearDown(() {
    service.dispose();
    boardEngine.dispose();
  });

  group('per-move evaluation', () {
    test(
      'White to move: the post-move score is negated into White terms',
      () async {
        scriptAfter(
          kInitialFEN,
          'e2e4',
          const ScriptLine.cp(-30, pv: ['e7e5', 'g1f3'], depth: 14),
        );
        scriptAfter(kInitialFEN, 'd2d4', const ScriptLine.cp(15, pv: ['d7d5']));
        await evaluate(kInitialFEN, ['e2e4', 'd2d4']);

        final results = service.results.value;
        expect(results.keys, unorderedEquals(['e2e4', 'd2d4']));
        expect(results['e2e4']!.scoreCp, 30);
        expect(results['e2e4']!.scoreMate, isNull);
        expect(results['e2e4']!.pv, [
          'e2e4',
          'e7e5',
          'g1f3',
        ], reason: 'move prepended');
        expect(results['e2e4']!.depth, 14);
        expect(results['d2d4']!.scoreCp, -15);

        final status = service.poolStatus.value;
        expect(status.phase, 'complete');
        expect(status.totalMoves, 2);
        expect(status.completedMoves, 2);
        expect(status.evaluatingUcis, isEmpty);
        expect(engine.evalSearches, hasLength(2));
        expect(engine.commands.where((c) => c == 'go depth 12'), hasLength(2));
      },
    );

    test(
      'Black to move: the post-move score is already White-relative',
      () async {
        scriptAfter(_afterE4, 'e7e5', const ScriptLine.cp(25));
        scriptAfter(_afterE4, 'c7c5', const ScriptLine.mate(-4));
        await evaluate(_afterE4, ['e7e5', 'c7c5']);

        expect(service.results.value['e7e5']!.scoreCp, 25);
        expect(
          service.results.value['c7c5']!.scoreMate,
          -4,
          reason: 'White gets mated',
        );
        expect(service.results.value['c7c5']!.scoreCp, isNull);
      },
    );

    test(
      'a forced mate for the mover flips to a positive White mate',
      () async {
        scriptAfter(
          kInitialFEN,
          'e2e4',
          const ScriptLine.mate(-2, pv: ['a7a6']),
        );
        await evaluate(kInitialFEN, ['e2e4']);
        expect(service.results.value['e2e4']!.scoreMate, 2);
        expect(service.results.value['e2e4']!.effectiveCp, greaterThan(9000));
      },
    );

    test('a mating move scores as mate for the mover, whoever moved', () async {
      // Stockfish answers a checkmated root with `score mate 0` and
      // `bestmove (none)`: the distance has no sign, so the service must
      // recover it from who moved.
      scriptAfter(_whiteMatesIn1, 'b1b8', const ScriptLine.mate(0));
      await evaluate(_whiteMatesIn1, ['b1b8']);
      final white = service.results.value['b1b8']!;
      expect(white.scoreMate, isNotNull);
      expect(white.scoreMate, greaterThan(0), reason: 'White delivered it');
      expect(
        white.effectiveCp,
        greaterThan(9000),
        reason: 'ranks above every cp score',
      );

      scriptAfter(_blackMatesIn1, 'b8b1', const ScriptLine.mate(0));
      await evaluate(_blackMatesIn1, ['b8b1']);
      final black = service.results.value['b8b1']!;
      expect(black.scoreMate, lessThan(0), reason: 'Black delivered it');
      expect(black.effectiveCp, lessThan(-9000));
    });

    test('an illegal move is skipped and still counted in the total', () async {
      scriptAfter(kInitialFEN, 'e2e4', const ScriptLine.cp(0));
      await evaluate(kInitialFEN, ['e2e5', 'e2e4']);
      expect(service.results.value.keys, ['e2e4']);
      expect(service.poolStatus.value.totalMoves, 2);
      expect(service.poolStatus.value.completedMoves, 1);
      expect(
        engine.evalSearches,
        hasLength(1),
        reason: 'no search for the illegal move',
      );
    });

    test('a search that reports no score still records the move', () async {
      // No script for the position: the engine answers `bestmove (none)`.
      await evaluate(kInitialFEN, ['e2e4']);
      final r = service.results.value['e2e4']!;
      expect(r.hasEval, isFalse);
      expect(r.pv, ['e2e4']);
      expect(service.poolStatus.value.completedMoves, 1);
    });

    test('no moves completes at once without touching the engine', () async {
      await service.startEvaluation(
        baseFen: kInitialFEN,
        moveUcis: const [],
        evalDepth: 12,
      );
      expect(service.poolStatus.value.phase, 'complete');
      expect(service.poolStatus.value.totalMoves, 0);
      expect(engine.commands.where((c) => c.startsWith('go ')), isEmpty);
    });

    test(
      'a new request supersedes the running one; its moves never land',
      () async {
        scriptAfter(kInitialFEN, 'e2e4', const ScriptLine.cp(-30));
        scriptAfter(_afterE4, 'e7e5', const ScriptLine.cp(10));
        var superseded = false;
        engine.onGo = (_) {
          if (superseded) return;
          superseded = true;
          unawaited(
            service.startEvaluation(
              baseFen: _afterE4,
              moveUcis: const ['e7e5'],
              evalDepth: 12,
            ),
          );
        };
        await evaluate(kInitialFEN, ['e2e4']);

        expect(service.results.value.keys, ['e7e5']);
        expect(service.results.value['e7e5']!.scoreCp, 10);
        expect(service.poolStatus.value.totalMoves, 1);
        expect(service.poolStatus.value.completedMoves, 1);
      },
    );

    test(
      'cancel mid-search clears results and returns the status to idle',
      () async {
        scriptAfter(kInitialFEN, 'e2e4', const ScriptLine.cp(-30));
        scriptAfter(kInitialFEN, 'd2d4', const ScriptLine.cp(-20));
        engine.onGo = (_) {
          engine.onGo = null;
          service.cancel();
        };
        await service.startEvaluation(
          baseFen: kInitialFEN,
          moveUcis: const ['e2e4', 'd2d4'],
          evalDepth: 12,
        );
        // Let the aborted worker loop unwind completely.
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(service.results.value, isEmpty);
        expect(
          engine.evalSearches,
          hasLength(1),
          reason: 'the queue was dropped',
        );
        expect(service.poolStatus.value.phase, 'idle');
        expect(service.poolStatus.value.evaluatingUcis, isEmpty);
      },
    );
  });

  group('discovery', () {
    void scriptDiscovery(String fen, List<ScriptLine> lines) =>
        engine.discovery[normalizeFen(fen)] = lines;

    test('White to move: lines keep their sign and order', () async {
      scriptDiscovery(kInitialFEN, const [
        ScriptLine.cp(30, pv: ['e2e4', 'e7e5'], depth: 18),
        ScriptLine.cp(20, pv: ['d2d4', 'd7d5'], depth: 18),
      ]);
      final result = await service.runDiscovery(
        fen: kInitialFEN,
        depth: 18,
        multiPv: 2,
      );
      expect(result.lines.map((l) => l.moveUci), ['e2e4', 'd2d4']);
      expect(result.lines.map((l) => l.scoreCp), [30, 20]);
      expect(result.lines.map((l) => l.pvNumber), [1, 2]);
      expect(result.depth, 18);
      expect(identical(service.discoveryResult.value, result), isTrue);
      expect(service.poolStatus.value.phase, 'discovering');
      expect(service.poolStatus.value.discoveryDepth, 18);
    });

    test(
      'Black to move: side-relative scores are negated into White terms',
      () async {
        scriptDiscovery(_afterE4, const [
          ScriptLine.cp(40, pv: ['e7e5']),
          ScriptLine.mate(2, pv: ['c7c5']),
        ]);
        final result = await service.runDiscovery(
          fen: _afterE4,
          depth: 18,
          multiPv: 2,
        );
        expect(result.lines[0].scoreCp, -40);
        expect(
          result.lines[1].scoreMate,
          -2,
          reason: 'Black mates: negative for White',
        );
      },
    );

    test('resets the previous evaluation results', () async {
      scriptAfter(kInitialFEN, 'e2e4', const ScriptLine.cp(0));
      await evaluate(kInitialFEN, ['e2e4']);
      expect(service.results.value, isNotEmpty);
      scriptDiscovery(_afterE4, const [
        ScriptLine.cp(0, pv: ['e7e5']),
      ]);
      await service.runDiscovery(fen: _afterE4, depth: 10, multiPv: 1);
      expect(service.results.value, isEmpty);
    });

    test('a cancel during the search yields an empty result', () async {
      scriptDiscovery(kInitialFEN, const [
        ScriptLine.cp(30, pv: ['e2e4']),
      ]);
      engine.onGo = (_) {
        engine.onGo = null;
        service.cancel();
      };
      final result = await service.runDiscovery(
        fen: kInitialFEN,
        depth: 18,
        multiPv: 1,
      );
      expect(result.lines, isEmpty);
      expect(service.discoveryResult.value.lines, isEmpty);
      expect(service.poolStatus.value.phase, 'idle');
    });
  });
}
