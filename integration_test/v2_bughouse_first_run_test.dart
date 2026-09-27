// The v2 app's bughouse engine on first use, inside a built desktop app:
// the bundled assets read through rootBundle, installed into an empty
// profile whose path has spaces and non-ASCII characters, started through
// the app's own launch path, asked for a real search, then damaged and
// started again. On Windows this also covers the private ONNX Runtime and
// the Visual C++ DLLs copied beside the engine.
//
// `flutter test integration_test/v2_bughouse_first_run_test.dart -d windows`
// (or `-d linux`).
import 'dart:io';

import 'package:chess_auto_prep/v2/app/environment.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/v2/engines/hivemind_install.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory scratch;
  late Directory profile;
  late EngineSupervisor engines;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('v2-bughouse-first-run-');
    profile = Directory(p.join(scratch.path, 'José 棋', 'Chess Auto Prep'));
    engines = EngineSupervisor();
  });

  tearDown(() async {
    await engines.dispose();
    await scratch.delete(recursive: true);
  });

  Future<Hivemind> start() async {
    final started = await launchHivemind(
      support: profile,
      engines: engines,
      cores: 2,
    );
    return switch (started) {
      HivemindStarted(:final engine) => engine,
      HivemindStartFailed(:final reason) => fail('did not start: $reason'),
    };
  }

  Future<void> searchesTheStart(Hivemind engine) async {
    final answer = await engine.search((
      position: TablePosition.initial,
      team: Team.ab,
      maySit: false,
      mustMove: MustMove.either,
      lines: 2,
      budget: const NodeBudget(64),
    ));
    expect(answer, isA<HivemindSearched>(), reason: '$answer');
    final found = answer as HivemindSearched;
    expect(found.best, isNotNull);
    expect(found.lines, isNotEmpty);
  }

  testWidgets('installs into a fresh profile, searches, and repairs damage', (
    tester,
  ) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    // Fail rather than skip: a release build without its engine is a bug.
    expect(HivemindInstall.bundledIn(manifest.listAssets()), isTrue);
    expect(await profile.exists(), isFalse);

    final first = await start();
    await searchesTheStart(first);
    await first.quit();

    final folder = Directory(p.join(profile.path, 'bughouse'));
    for (final name in HivemindInstall.installedNames) {
      expect(
        File(p.join(folder.path, name)).existsSync(),
        isTrue,
        reason: name,
      );
    }
    if (Platform.isWindows) {
      final names = folder.listSync().map(
        (e) => p.basename(e.path).toLowerCase(),
      );
      expect(names, containsAll(['vcruntime140.dll', 'msvcp140.dll']));
      // The engine must never find a generic runtime by that name.
      expect(names, isNot(contains('onnxruntime.dll')));
    }

    // Right size, wrong bytes: the case that once stuck for good.
    final network = File(p.join(folder.path, 'hivemind.onnx'));
    final bytes = network.readAsBytesSync();
    final middle = bytes.length ~/ 2;
    final original = bytes.sublist(middle, middle + 4096);
    bytes.fillRange(middle, middle + 4096, 0x5A);
    network.writeAsBytesSync(bytes, flush: true);
    expect(network.lengthSync(), bytes.length);

    final second = await start();
    await searchesTheStart(second);
    await second.quit();
    final repaired = network.readAsBytesSync();
    expect(repaired.sublist(middle, middle + 4096), original);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
