// The app's bughouse engine on first use, inside a built desktop app:
// the bundled assets read through rootBundle, installed into an empty
// profile whose path has spaces and non-ASCII characters, started through
// the app's own launch path (which proves the net loaded), asked for a
// real search, then damaged and started again.
//
// `flutter test integration_test/bughouse_first_run_test.dart -d windows`
// (or `-d linux`).
import 'dart:io';

import 'package:chess_auto_prep/app/native_engines.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/hypebeast_engine.dart';
import 'package:chess_auto_prep/engines/hypebeast_install.dart';
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
    scratch = await Directory.systemTemp.createTemp('bughouse-first-run-');
    profile = Directory(p.join(scratch.path, 'José 棋', 'Chess Auto Prep'));
    engines = EngineSupervisor();
  });

  tearDown(() async {
    await engines.dispose();
    await scratch.delete(recursive: true);
  });

  Future<HypeBeast> start() async {
    final started = await launchHypeBeast(support: profile, engines: engines);
    return switch (started) {
      HypeBeastStarted(:final engine) => engine,
      HypeBeastStartFailed(:final reason) => fail('did not start: $reason'),
    };
  }

  Future<void> searchesTheStart(HypeBeast engine) async {
    final answer = await engine.search((
      position: TablePosition.initial,
      played: null,
      board: BoardNumber.one,
      lines: 1,
      coordination: true,
      clocks: null,
      threads: 2,
      budget: const NodeBudget(20000),
    ));
    expect(answer, isA<HypeBeastSearched>(), reason: '$answer');
    final found = answer as HypeBeastSearched;
    expect(found.decision?.move, isNotNull);
    expect(found.report.main, isNotNull);
  }

  testWidgets('installs into a fresh profile, searches, and repairs damage', (
    tester,
  ) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    // Fail rather than skip: a release build without its engine is a bug.
    expect(HypeBeastInstall.bundledIn(manifest.listAssets()), isTrue);
    expect(await profile.exists(), isFalse);

    final first = await start();
    await searchesTheStart(first);
    await first.quit();

    final folder = Directory(p.join(profile.path, 'bughouse'));
    for (final name in HypeBeastInstall.installedNames) {
      expect(
        File(p.join(folder.path, name)).existsSync(),
        isTrue,
        reason: name,
      );
    }

    // Right size, wrong bytes: the case that once stuck for good.
    final net = File(p.join(folder.path, HypeBeastInstall.net));
    final bytes = net.readAsBytesSync();
    final middle = bytes.length ~/ 2;
    final original = bytes.sublist(middle, middle + 4096);
    bytes.fillRange(middle, middle + 4096, 0x5A);
    net.writeAsBytesSync(bytes, flush: true);
    expect(net.lengthSync(), bytes.length);

    final second = await start();
    await searchesTheStart(second);
    await second.quit();
    final repaired = net.readAsBytesSync();
    expect(repaired.sublist(middle, middle + 4096), original);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
