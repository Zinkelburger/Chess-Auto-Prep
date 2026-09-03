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

  String runtimeKey() {
    if (Platform.isWindows) return 'assets/bughouse/onnxruntime.dll.gz';
    if (Platform.isMacOS) return 'assets/bughouse/libonnxruntime.dylib.gz';
    return 'assets/bughouse/libonnxruntime.so.1.gz';
  }

  tearDown(() => BughouseBundle.setBundledForTesting(null));

  test('engine, runtime and network together mean the mode can run', () {
    expect(
      BughouseBundle.hasEngineAssets([engineKey(), runtimeKey(), network]),
      isTrue,
    );
  });

  test('a bundle missing the ONNX runtime does not count', () {
    // `ensureInstalled` extracts all three and throws over the runtime, so a
    // probe that ignored it let the mode offer itself and then fail on the
    // first click — the one thing the probe exists to prevent.
    expect(BughouseBundle.hasEngineAssets([engineKey(), network]), isFalse);
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
    expect(
      BughouseBundle.hasEngineAssets([foreign, runtimeKey(), network]),
      isFalse,
    );
  });

  test('no two of the three are enough on their own', () {
    expect(BughouseBundle.hasEngineAssets([network]), isFalse);
    expect(BughouseBundle.hasEngineAssets([engineKey()]), isFalse);
    expect(BughouseBundle.hasEngineAssets([runtimeKey()]), isFalse);
    expect(
      BughouseBundle.hasEngineAssets([engineKey(), runtimeKey()]),
      isFalse,
    );
    expect(BughouseBundle.hasEngineAssets([runtimeKey(), network]), isFalse);
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
