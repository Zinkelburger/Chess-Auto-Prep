import 'dart:io';

import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/engines/hivemind_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The engine the app installed on this machine, when it has: the real
/// protocol, spoken through the supervisor, on a search of a few nodes.
final _installed = p.join(
  Platform.environment['HOME'] ?? '',
  '.local/share/com.example.chess_auto_prep/bughouse',
);

void main() {
  final binary = File(p.join(_installed, 'hivemind-linux'));
  test(
    'the installed Hivemind answers a search and quits with the app',
    () async {
      final engines = EngineSupervisor();
      final start = await engines.startHivemind((
        executable: binary.path,
        model: p.join(_installed, 'hivemind.onnx'),
        directory: _installed,
      ), cores: 2);
      final engine = (start as HivemindStarted).engine;
      final answer =
          await engine.search((
                position: TablePosition.initial,
                team: Team.ab,
                maySit: false,
                mustMove: MustMove.either,
                lines: 2,
                budget: const NodeBudget(40),
              ))
              as HivemindSearched;
      expect(answer.best, isNotNull);
      expect(answer.top!.cp, isNotNull);
      // After 1.e4 on board 1, C and D hold both moves: A + B has none.
      final none =
          await engine.search((
                position: TablePosition.initial
                    .play(BoardNumber.one, 'e2e4')!
                    .after,
                team: Team.ab,
                maySit: false,
                mustMove: MustMove.either,
                lines: 1,
                budget: const NodeBudget(40),
              ))
              as HivemindSearched;
      expect(none.best, isNull);
      await engines.dispose();
      expect(engines.pids, isEmpty);
    },
    skip: Platform.isLinux && binary.existsSync()
        ? false
        : 'no installed Hivemind on this machine',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
