import 'dart:io';

import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/engines/hivemind_install.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The engine named by `HIVEMIND_BIN` / `HIVEMIND_MODEL` / `HIVEMIND_LIB`
/// (the bughouse release gate extracts one on Linux and Windows), else the
/// one the app installed on this Linux machine: the real protocol, spoken
/// through the supervisor, on a search of a few nodes.
final _env = Platform.environment;
final _installed = p.join(
  _env['HOME'] ?? '',
  '.local/share/com.example.chess_auto_prep/bughouse',
);
final HivemindFiles _files = switch (_env['HIVEMIND_BIN']) {
  final bin? when bin.isNotEmpty => (
    executable: p.absolute(bin),
    model: p.absolute(
      _env['HIVEMIND_MODEL'] ?? p.join(p.dirname(bin), 'hivemind.onnx'),
    ),
    directory: p.absolute(_env['HIVEMIND_LIB'] ?? p.dirname(bin)),
  ),
  _ => (
    executable: p.join(_installed, 'hivemind-linux'),
    model: p.join(_installed, 'hivemind.onnx'),
    directory: _installed,
  ),
};

void main() {
  final named = _env['HIVEMIND_BIN']?.isNotEmpty ?? false;
  final binary = File(_files.executable);
  test(
    'the installed Hivemind answers a search and quits with the app',
    () async {
      final engines = EngineSupervisor();
      final start = await engines.startHivemind(_files, cores: 2);
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
    // A gate that names an engine must run it, never skip.
    skip: named || Platform.isLinux && binary.existsSync()
        ? false
        : 'no installed Hivemind on this machine',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
