import 'dart:async';

import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/crazyara_engine.dart';
import 'package:chess_auto_prep/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/engines/uci_process.dart';
import 'package:flutter_test/flutter_test.dart';

final class PolicyPipe implements UciProcess {
  final sent = <String>[];
  final output = StreamController<String>();
  String team = 'white';
  bool omitValue = false;
  bool killed = false;
  bool searched = false;
  @override
  int get pid => 1234;
  @override
  Stream<String> get lines => output.stream;
  @override
  void send(String line) {
    sent.add(line);
    if (line == 'uci') output.add('uciok');
    if (line == 'isready') output.add('readyok');
    if (line == 'setoption name Team value black') team = 'black';
    if (line == 'setoption name Team value white') team = 'white';
    if (line == 'policy' && !omitValue)
      output.add('Value: ${team == 'white' ? '-0.3' : '-0.7'}');
    if (line.startsWith('go ')) {
      if (searched) {
        output.add(
          'info depth 7 multipv 1 score cp -228 nodes 1523 nps 249 time 981 pv (e2e4,pass)',
        );
        output.add('bestmove (e2e4,pass)');
      } else {
        output.add('bestmove e2e4');
      }
    }
    if (line == 'root') {
      for (final (i, m)
          in TablePosition.initial.legalMoves(BoardNumber.one).indexed) {
        output.add('$i | ${m.san} | 1 | ${m.uci == 'e2e4' ? .81 : .01} | 0');
      }
    }
    if (line == 'quit') unawaited(output.close());
  }

  @override
  Future<void> kill() async {
    killed = true;
    await output.close();
  }
}

void main() {
  test(
    'Hivemind calibrates both seats with sitting off and no move search',
    () async {
      final pipe = PolicyPipe();
      final engine = (await HivemindProcess.start(pipe))!;
      expect(await engine.evaluate(TablePosition.initial), closeTo(.2, 1e-9));
      expect(await engine.evaluate(TablePosition.initial), closeTo(.2, 1e-9));
      expect(
        pipe.sent.where((l) => l == 'setoption name TimeAdvantage value false'),
        hasLength(4),
      );
      expect(pipe.sent.any((l) => l.startsWith('go')), isFalse);
      pipe.omitValue = true;
      await expectLater(
        engine.evaluate(TablePosition.initial),
        throwsA(isA<Exception>()),
      );
      await engine.quit();
    },
  );

  test(
    'searched values use the node budget, selected board and calibrated seat',
    () async {
      final pipe = PolicyPipe()..searched = true;
      final engine = (await HivemindProcess.start(pipe))!;
      final result = await engine.inspect(
        TablePosition.initial,
        BoardNumber.one,
        1500,
      );
      expect(result.best, 'e2e4');
      expect(result.nodes, 1523);
      expect(result.depth, 7);
      expect(result.value, inInclusiveRange(-1.0, 1.0));
      expect(pipe.sent, contains('go nodes 1500'));
      expect(pipe.sent, contains('setoption name RequireMoveOn value A'));
      expect(pipe.sent, contains('setoption name TimeAdvantage value false'));
      expect(pipe.sent, contains('stop'));
      await engine.quit();
    },
  );

  test(
    'CrazyAra reads policy, normalizes and softens without visit counts',
    () async {
      final pipe = PolicyPipe();
      final engine = await CrazyaraProcess.start(pipe);
      final distribution = await engine.policy(
        TablePosition.initial,
        BoardNumber.one,
      );
      expect(distribution, hasLength(20));
      expect(distribution.values.reduce((a, b) => a + b), closeTo(1, 1e-9));
      expect(distribution['e2e4'], closeTo(.4962985153, .00001));
      expect(
        pipe.sent,
        contains('setoption name Centi_Node_Temperature value 100'),
      );
      expect(pipe.sent, contains('setoption name Use_Raw_Network value false'));
      await engine.quit();
    },
  );

  test(
    'incomplete root output fails rather than inventing missing probabilities',
    () {
      expect(
        () => readCrazyaraPolicy(TablePosition.initial, BoardNumber.one, [
          '000 | e4 | 1 | 1 | 0',
        ]),
        throwsA(isA<Exception>()),
      );
    },
  );
}
