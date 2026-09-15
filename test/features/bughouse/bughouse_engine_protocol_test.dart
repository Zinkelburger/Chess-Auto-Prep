import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lines Hivemind prints, read without a process behind them.
void main() {
  group('parseInfo', () {
    test('reads every field of a ranked line', () {
      final info = BughouseEngineProtocol.parseInfo(
        'info depth 3 seldepth 5 multipv 2 score cp -230 nodes 800 nps 400 '
        'time 2000 pv (g1f3,pass) (e7e5,d7d5)',
        hadTimeAdvantage: true,
      )!;
      expect(info.depth, 3);
      expect(info.multipv, 2);
      expect(info.scoreCp, -230);
      expect(info.nodes, 800);
      expect(info.nps, 400);
      expect(info.timeMs, 2000);
      expect(info.mateIn, isNull);
      expect(info.hadTimeAdvantage, isTrue);
      expect(info.pv.map((m) => m.toString()), ['(g1f3,pass)', '(e7e5,d7d5)']);
    });

    test('a mate score carries its distance', () {
      final info = BughouseEngineProtocol.parseInfo(
        'info depth 4 score mate -2 nodes 50 pv (pass,e7e5)',
        hadTimeAdvantage: false,
      )!;
      expect(info.mateIn, -2);
      expect(info.scoreCp, 0);
    });

    test('the unvisited root prior is not a line', () {
      // Q = -1 before any node has been evaluated, printed on every search.
      expect(
        BughouseEngineProtocol.parseInfo(
          'info depth 1 score cp -16671 nodes 1 pv (g1f3,pass)',
          hadTimeAdvantage: false,
        ),
        isNull,
      );
      expect(
        BughouseEngineProtocol.parseInfo(
          'info depth 0 nodes 9',
          hadTimeAdvantage: false,
        ),
        isNull,
      );
    });

    test('only search lines qualify', () {
      expect(BughouseEngineProtocol.isSearchInfo('info depth 2 nodes 4'), true);
      expect(
        BughouseEngineProtocol.isSearchInfo('info string backend ONNX'),
        false,
      );
      expect(
        BughouseEngineProtocol.isSearchInfo('bestmove (pass,pass)'),
        false,
      );
    });
  });

  group('parseBestMove', () {
    test('reads the joint action and the ponder reply', () {
      final parsed = BughouseEngineProtocol.parseBestMove(
        'bestmove (d2d4,pass) ponder (d7d5,d2d4)',
      );
      expect(parsed.best.toString(), '(d2d4,pass)');
      expect(parsed.ponder.toString(), '(d7d5,d2d4)');
    });

    test('a ponder-less line and a (none) answer', () {
      final plain = BughouseEngineProtocol.parseBestMove(
        'bestmove (P@e5,pass)',
      );
      expect(plain.best.toString(), '(P@e5,pass)');
      expect(plain.ponder, isNull);
      expect(
        BughouseEngineProtocol.parseBestMove('bestmove (none)').best,
        isNull,
      );
    });
  });

  group('parseBackend', () {
    test('splits the backend from its readout', () {
      final parsed = BughouseEngineProtocol.parseBackend(
        'ONNX Runtime (CPU) model hivemind.onnx batch 8 workers 4 '
        'intra-op threads 5',
      );
      expect(parsed.backend, 'ONNX Runtime (CPU)');
      expect(parsed.detail, '4 workers · 5 threads · batch 8');
    });

    test('a part the engine stops reporting shortens the readout', () {
      final parsed = BughouseEngineProtocol.parseBackend('TensorRT workers 2');
      expect(parsed.backend, 'TensorRT workers 2');
      expect(parsed.detail, '2 workers');
    });
  });
}
