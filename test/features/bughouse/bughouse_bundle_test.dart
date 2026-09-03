import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_bundle.dart';

/// Whether a build carries the bughouse engine decides whether the mode is
/// offered at all, so the decision is tested over asset keys rather than over
/// whatever this particular checkout happens to have fetched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String engineKey() {
    if (Platform.isWindows) return 'assets/bughouse/hivemind-windows.exe.gz';
    if (Platform.isMacOS) return 'assets/bughouse/hivemind-macos.gz';
    return 'assets/bughouse/hivemind-linux.gz';
  }

  const network = 'assets/bughouse/hivemind.onnx.gz';

  tearDown(() => BughouseBundle.setBundledForTesting(null));

  test('engine and network together mean the mode can run', () {
    expect(BughouseBundle.hasEngineAssets([engineKey(), network]), isTrue);
  });

  test('a checkout that never ran the fetch script has neither', () {
    expect(
      BughouseBundle.hasEngineAssets(const [
        'assets/bughouse/.gitkeep',
        'assets/executables/stockfish-linux.gz',
      ]),
      isFalse,
    );
  });

  test('another platform\'s engine does not count as this one\'s', () {
    // Release jobs fetch one platform each, so a bundle really can hold an
    // engine that this build cannot execute.
    final foreign = Platform.isWindows
        ? 'assets/bughouse/hivemind-linux.gz'
        : 'assets/bughouse/hivemind-windows.exe.gz';
    expect(BughouseBundle.hasEngineAssets([foreign, network]), isFalse);
  });

  test('the network alone is not enough, nor the engine alone', () {
    expect(BughouseBundle.hasEngineAssets([network]), isFalse);
    expect(BughouseBundle.hasEngineAssets([engineKey()]), isFalse);
  });

  test('the probe caches, so the mode menu can ask on every rebuild', () async {
    BughouseBundle.setBundledForTesting(true);
    expect(await BughouseBundle.probeBundled(), isTrue);
    expect(BughouseBundle.isBundled, isTrue);
  });

  test('the missing-bundle error names the asset it looked for', () {
    expect(
      BughouseBundleMissing(
        'assets/bughouse/hivemind-windows.exe.gz',
      ).toString(),
      contains('hivemind-windows.exe.gz'),
    );
  });
}
