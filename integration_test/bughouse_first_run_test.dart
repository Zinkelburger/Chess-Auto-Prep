import 'dart:io';

import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_bundle.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/services/windows_loader_check.dart';
import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'app_test.dart' as app_smoke;

// Only the profile location is substituted. Assets, extraction, runtime DLL
// discovery and the engine process all come from the built desktop app.
class _FreshProfile extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FreshProfile(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled bughouse works on first use and repairs damage', (
    tester,
  ) async {
    final scratch = await Directory.systemTemp.createTemp(
      'bughouse-first-run-',
    );
    final profile = p.join(scratch.path, 'José 棋', 'Chess Auto Prep');
    final originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FreshProfile(profile);
    addTearDown(() async {
      PathProviderPlatform.instance = originalPaths;
      await scratch.delete(recursive: true);
    });

    expect(await Directory(profile).exists(), isFalse);
    // Deliberately fail rather than skip when a build omitted its assets.
    expect(await BughouseBundle.probeBundled(), isTrue);
    final executable = await BughouseBundle.ensureInstalled();
    final engineDir = p.join(profile, 'bughouse');
    expect(p.dirname(executable), engineDir);
    expect(
      BughouseBundle.expectedHashes.keys,
      containsAll(BughouseBundle.installedFileNames),
    );
    expect(
      await BughouseBundle.verifyExtraction(
        engineDir,
        BughouseBundle.expectedSizes,
        expectedHashes: BughouseBundle.expectedHashes,
      ),
      isEmpty,
    );

    if (Platform.isWindows) {
      // A hosted runner already has VC++. Require the app-local copies too,
      // or this test could pass while the portable ZIP fails on a clean PC.
      for (final name in WindowsLoaderCheck.appSuppliedDependencies) {
        final source = File(
          p.join(BughouseBundle.applicationDirectory().path, name),
        );
        final installed = File(p.join(engineDir, name));
        expect(await source.exists(), isTrue, reason: 'app must ship $name');
        expect(await installed.exists(), isTrue, reason: 'engine needs $name');
        expect(
          (await sha256.bind(installed.openRead()).first).toString(),
          (await sha256.bind(source.openRead()).first).toString(),
          reason: '$name must match the built app runtime',
        );
      }
    }

    Future<void> search() async {
      final engine = await BughouseEngine.launch(
        executablePath: await BughouseBundle.ensureInstalled(),
        modelPath: BughouseBundle.modelPath!,
        libraryPath: BughouseBundle.libraryPath,
      );
      try {
        expect(engine.backend, contains('ONNX Runtime'));
        await engine.configure(team: Side.white, hasTimeAdvantage: false);
        await engine.setPosition(BughouseState.initial());
        final result = await engine.search(nodes: 150);
        expect(result.best, isNotNull);
        expect(result.best!.a.isPass, isFalse);
        expect(result.best!.b.isPass, isTrue);
        expect(result.lastInfo?.nodes, greaterThan(1));
      } finally {
        await engine.dispose();
      }
    }

    await search();
    await search(); // A second launch reuses the same installed files.

    // Same-length corruption escaped the old size-only extraction check.
    // Damage the network after both processes exit, then exercise the repair
    // used by the failure reporter and start a real search again.
    final model = File(BughouseBundle.modelPath!);
    final bytes = await model.readAsBytes();
    bytes[0] ^= 0xff;
    await model.writeAsBytes(bytes, flush: true);
    final repair = await BughouseBundle.verifyAndRepair();
    expect(repair.damaged, ['hivemind.onnx']);
    await search();
  }, timeout: const Timeout(Duration(minutes: 5)));
  // One native process: launching separate integration executables in one
  // flutter test invocation can trigger the Windows single-instance handoff
  // before the second executable connects to the test runner.
  app_smoke.main();
}
