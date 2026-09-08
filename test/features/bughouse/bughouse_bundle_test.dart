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
  const manifest = 'assets/bughouse/manifest.json';

  String runtimeKey() {
    if (Platform.isWindows) return 'assets/bughouse/onnxruntime.dll.gz';
    if (Platform.isMacOS) return 'assets/bughouse/libonnxruntime.dylib.gz';
    return 'assets/bughouse/libonnxruntime.so.1.gz';
  }

  tearDown(() => BughouseBundle.setBundledForTesting(null));

  test('engine, runtime, network and manifest mean the mode can run', () {
    expect(
      BughouseBundle.hasEngineAssets([
        engineKey(),
        runtimeKey(),
        network,
        manifest,
      ]),
      isTrue,
    );
  });

  test('a bundle missing the ONNX runtime does not count', () {
    // `ensureInstalled` extracts all three and throws over the runtime, so a
    // probe that ignored it let the mode offer itself and then fail on the
    // first click — the one thing the probe exists to prevent.
    expect(
      BughouseBundle.hasEngineAssets([engineKey(), network, manifest]),
      isFalse,
    );
  });

  /// Without it nothing ever checks an already-extracted file's size again, so
  /// a half-written DLL from a killed launch survives every later launch — and
  /// Windows rejects a truncated image with the same status it uses for a
  /// 32-bit one, which is the least diagnosable failure this feature has.
  test('a bundle with no size manifest does not count', () {
    expect(
      BughouseBundle.hasEngineAssets([engineKey(), runtimeKey(), network]),
      isFalse,
    );
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
      BughouseBundle.hasEngineAssets([
        foreign,
        runtimeKey(),
        network,
        manifest,
      ]),
      isFalse,
    );
  });

  test('no subset of the four is enough on its own', () {
    expect(BughouseBundle.hasEngineAssets([network]), isFalse);
    expect(BughouseBundle.hasEngineAssets([engineKey()]), isFalse);
    expect(BughouseBundle.hasEngineAssets([runtimeKey()]), isFalse);
    expect(BughouseBundle.hasEngineAssets([manifest]), isFalse);
    expect(
      BughouseBundle.hasEngineAssets([engineKey(), runtimeKey()]),
      isFalse,
    );
    expect(BughouseBundle.hasEngineAssets([runtimeKey(), network]), isFalse);
    expect(
      BughouseBundle.hasEngineAssets([engineKey(), runtimeKey(), manifest]),
      isFalse,
    );
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

  group('the Visual C++ runtime the Windows engine needs', () {
    // onnxruntime.dll imports MSVCP140.dll, MSVCP140_1.dll, VCRUNTIME140.dll
    // and VCRUNTIME140_1.dll. None of them is part of a clean Windows
    // install; windows/CMakeLists.txt deploys them beside the app, and the
    // engine is a separate process in a different directory, which resolves
    // its imports against its own directory and not its parent's. Without the
    // copy the engine is stopped by the loader before `main` — no stdout, no
    // stderr, no exit — and the app can only report a timeout.

    test('recognises every spelling CMake may deploy', () {
      for (final name in [
        'MSVCP140.dll',
        'msvcp140_1.dll',
        'MSVCP140_2.dll',
        'VCRUNTIME140.dll',
        'vcruntime140_1.dll',
        'concrt140.dll',
      ]) {
        expect(
          BughouseBundle.isWindowsRuntimeLibrary(name),
          isTrue,
          reason: name,
        );
      }
    });

    test('leaves everything else where it is', () {
      // Copying the app's own onnxruntime.dll (Maia's) beside the engine
      // would shadow the engine's own with a different build.
      for (final name in [
        'onnxruntime.dll',
        'flutter_windows.dll',
        'chess_auto_prep.exe',
        'msvcp140.txt',
        'notmsvcp140.dll',
      ]) {
        expect(
          BughouseBundle.isWindowsRuntimeLibrary(name),
          isFalse,
          reason: name,
        );
      }
    });
  });
}
