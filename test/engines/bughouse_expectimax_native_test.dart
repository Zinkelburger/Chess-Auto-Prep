import 'dart:io';

import 'package:chess_auto_prep/chess/bughouse/expectimax.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/bughouse_backend.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/hivemind_install.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native CrazyAra and Hivemind complete the same tree the Lab runs',
    () async {
      final supervisor = EngineSupervisor();
      final temp = await Directory.systemTemp.createTemp(
        'bughouse-expectimax-',
      );
      try {
        final install = HivemindInstall(
          supportDirectory: temp,
          readAsset: (asset) async =>
              File(asset).existsSync() ? File(asset).readAsBytes() : null,
        );
        final location = await install.locate() as HivemindReady;
        final backend = await BughouseBackend.start(
          crazyara: () => supervisor.startCrazyara(temp.path),
          hivemind: () => supervisor.startHivemind(location.files, cores: 2),
        );
        final search = BughouseExpectimax(
          board: BoardNumber.one,
          team: Team.ab,
          policy: backend.policy,
          evaluate: backend.evaluate,
          options: const BughouseSearchOptions(),
          cancelled: () => false,
        );
        final watch = Stopwatch()..start();
        final rows = await search.search(TablePosition.initial).toList();
        expect(rows.length, 20);
        expect(
          rows.every(
            (r) => r.child.expected.isFinite && r.child.branches.isNotEmpty,
          ),
          isTrue,
        );
        rows.sort((a, b) => b.child.expected.compareTo(a.child.expected));
        // Kept in the test log as reproducible evidence of real inference.
        print(
          'Native: ${search.positions} positions in ${watch.elapsed}; best ${rows.first.move.san}, Q=${rows.first.child.expected}',
        );
        await backend.close();
      } finally {
        await supervisor.dispose();
        await temp.delete(recursive: true);
      }
    },
    skip: Platform.environment['BUGHOUSE_EXPECTIMAX_NATIVE'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
