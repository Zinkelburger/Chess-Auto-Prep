import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/app_paths.dart';
import '../../../utils/log.dart';

/// Resolves the three files Hivemind needs at runtime, extracting them from
/// the asset bundle on first use — the same shape as [StockfishBundle], with
/// one extra part: the ONNX Runtime shared library.
///
/// Why three files rather than one static binary: the upstream engine links
/// TensorRT, which is ~2 GB of NVIDIA redistributables and NVIDIA-only. Built
/// against ONNX Runtime instead, the engine is a 1.9 MB binary plus a 28 MB
/// runtime plus the network — and it runs on any desktop.
class BughouseBundle {
  static _Resolved? _cached;

  /// Extracted engine binary.
  static String? get executablePath => _cached?.executable;

  /// Extracted FP32 network.
  static String? get modelPath => _cached?.model;

  /// Directory containing libonnxruntime. Null only for a local build pointed
  /// at by [useLocalBuild] that did not name one — every shipped target
  /// carries the runtime as a separate file.
  static String? get libraryPath => _cached?.libraryDir;

  /// Whether this build actually carries an engine for this platform.
  ///
  /// Worth asking, rather than assuming from [Platform]: `assets/bughouse/` is
  /// declared in pubspec.yaml but filled in by `tools/fetch_bughouse.py` at
  /// release time rather than tracked in git, and Flutter treats a *missing*
  /// asset directory as a printed warning, not a build failure. So "compiled
  /// in, but with no engine behind it" is an ordinary state — every developer
  /// checkout is in it until the fetch script runs — and the mode has to be
  /// able to tell, instead of offering itself and then failing on first click.
  ///
  /// Null until [probeBundled] has run.
  static bool? _bundled;

  /// The answer [probeBundled] found. False before it has run.
  static bool get isBundled => _bundled ?? false;

  /// Looks for this platform's engine in the asset manifest. Cheap — it reads
  /// the manifest Flutter already ships, not the 43 MB behind it — and cached,
  /// so the mode menu can ask on every rebuild.
  static Future<bool> probeBundled() async {
    final cached = _bundled;
    if (cached != null) return cached;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      return _bundled = hasEngineAssets(manifest.listAssets());
    } catch (e) {
      log.w('Could not read the asset manifest for the bughouse engine: $e');
      return _bundled = false;
    }
  }

  /// The decision itself, over a list of asset keys.
  ///
  /// All three parts are required: a release job fetches one platform's pair,
  /// so a bundle can hold a Linux engine and no Windows one; the network is
  /// fetched separately from the pair; and the ONNX runtime is a third file
  /// that [ensureInstalled] extracts unconditionally. Leaving the runtime out
  /// of this check let a partial bundle offer the mode in the menu and then
  /// throw on the first click — exactly what the probe exists to prevent.
  @visibleForTesting
  static bool hasEngineAssets(Iterable<String> assetKeys) {
    final keys = assetKeys.toSet();
    return keys.contains('assets/bughouse/${_binaryName()}.gz') &&
        keys.contains('assets/bughouse/${_runtimeName()}.gz') &&
        keys.contains('assets/bughouse/hivemind.onnx.gz');
  }

  /// Test seam: pretend the engine is (or is not) bundled.
  @visibleForTesting
  static void setBundledForTesting(bool? value) => _bundled = value;

  static String _binaryName() {
    if (Platform.isWindows) return 'hivemind-windows.exe';
    if (Platform.isMacOS) return 'hivemind-macos';
    return 'hivemind-linux';
  }

  static String _runtimeName() {
    if (Platform.isWindows) return 'onnxruntime.dll';
    if (Platform.isMacOS) return 'libonnxruntime.dylib';
    return 'libonnxruntime.so.1';
  }

  /// Extracts everything into the support directory if it is not already
  /// there, and returns the engine path. Throws [BughouseBundleMissing] when
  /// the app was built without the bughouse assets, which is the normal state
  /// of a checkout that has not run `tools/fetch_bughouse.py`.
  static Future<String> ensureInstalled() {
    final cached = _cached;
    if (cached != null) return Future.value(cached.executable);
    // One extraction at a time. Two callers arriving together (the analysis
    // pump and a button press during the first launch) would otherwise write
    // the same 54 MB network concurrently.
    return _installing ??= _install().whenComplete(() => _installing = null);
  }

  static Future<String>? _installing;

  static Future<String> _install() async {
    final dir = await AppPaths.supportDirectory();
    final target = Directory(p.join(dir.path, 'bughouse'));
    await target.create(recursive: true);

    final manifest = await _loadManifest();
    final executable = p.join(target.path, _binaryName());
    final model = p.join(target.path, 'hivemind.onnx');
    final runtime = p.join(target.path, _runtimeName());

    // Sizes are keyed by extracted filename, so a checkout holding more than
    // one platform's pair describes each of them rather than only whichever
    // fetch ran last.
    for (final file in [executable, runtime, model]) {
      final name = p.basename(file);
      await _installAsset(
        asset: 'assets/bughouse/$name.gz',
        target: file,
        expectedSize: manifest[name],
      );
    }

    if (Platform.isWindows) {
      await installWindowsRuntime(
        source: applicationDirectory(),
        target: target,
      );
    } else {
      final chmod = await Process.run('chmod', ['+x', executable]);
      if (chmod.exitCode != 0) {
        throw BughouseBundleBroken(
          'Could not make $executable executable: ${chmod.stderr}',
        );
      }
    }

    _cached = _Resolved(
      executable: executable,
      model: model,
      libraryDir: target.path,
    );
    log.i('Bughouse engine installed at $executable');
    return executable;
  }

  /// The directory the app itself was launched from, which is where the
  /// Windows build deploys its shared libraries.
  ///
  /// Wrapped because [Platform.resolvedExecutable] is documented as able to
  /// throw, and a bughouse feature is not worth taking the app down over.
  @visibleForTesting
  static Directory applicationDirectory() {
    try {
      return File(Platform.resolvedExecutable).parent;
    } catch (_) {
      return Directory.current;
    }
  }

  /// Whether [fileName] is one of the Visual C++ runtime libraries the
  /// Windows build deploys beside the app.
  ///
  /// A prefix match rather than a fixed list on purpose: which of
  /// MSVCP140.dll / MSVCP140_1.dll / MSVCP140_2.dll / VCRUNTIME140.dll /
  /// VCRUNTIME140_1.dll / CONCRT140.dll CMake's `InstallRequiredSystemLibraries`
  /// actually emits varies with the toolchain, and a list here that drifts
  /// from what the build deploys fails in exactly the way this whole function
  /// exists to prevent.
  @visibleForTesting
  static bool isWindowsRuntimeLibrary(String fileName) {
    final name = fileName.toLowerCase();
    if (!name.endsWith('.dll')) return false;
    return name.startsWith('msvcp140') ||
        name.startsWith('vcruntime140') ||
        name.startsWith('concrt140');
  }

  /// Copies the Visual C++ runtime from [source] next to the engine in
  /// [target], and returns the names copied.
  ///
  /// This is the difference between the mode working on a fresh Windows
  /// machine and not working at all. `onnxruntime.dll` imports MSVCP140.dll,
  /// MSVCP140_1.dll, VCRUNTIME140.dll and VCRUNTIME140_1.dll, none of which is
  /// part of a clean Windows install — they come with the Visual C++
  /// redistributable, which most machines have only because some other program
  /// installed it. windows/CMakeLists.txt therefore deploys them beside
  /// `chess_auto_prep.exe`, and that is enough for the app itself and for the
  /// ONNX runtime it loads in-process.
  ///
  /// It is *not* enough for the bughouse engine, because that is a separate
  /// process: Windows resolves a process's imports against the directory of
  /// **its own** image, never the parent's. `hivemind.exe` lives in the
  /// support directory, so it looked for MSVCP140.dll there, in System32, and
  /// on PATH, found it in none of them, and was stopped by the loader before
  /// `main` — which the app saw as a live process that never answered `uci`.
  ///
  /// Copying rather than putting the app directory on the child's PATH
  /// because the engine's own directory is the *first* place the loader
  /// looks, ahead of every registry knob that can reorder the rest of the
  /// search, and because the runtime the engine ships is already installed
  /// there by the same step.
  ///
  /// Missing sources are not an error: a machine that has the redistributable
  /// system-wide runs fine without any of this, and the exit code the engine
  /// dies with says so plainly if it does not.
  @visibleForTesting
  static Future<List<String>> installWindowsRuntime({
    required Directory source,
    required Directory target,
  }) async {
    final copied = <String>[];
    if (!await source.exists()) return copied;
    await for (final entry in source.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!isWindowsRuntimeLibrary(name)) continue;
      final dest = File(p.join(target.path, name));
      final length = await entry.length();
      if (await dest.exists() && await dest.length() == length) {
        copied.add(name);
        continue;
      }
      try {
        await entry.copy(dest.path);
        copied.add(name);
      } catch (e) {
        // A locked or in-use DLL is survivable — the system copy may still
        // be there — so say so and carry on rather than failing the launch.
        log.w('Could not copy $name beside the bughouse engine: $e');
      }
    }
    if (copied.isEmpty) {
      log.w(
        'No Visual C++ runtime found in ${source.path} to place beside the '
        'bughouse engine; it will have to come from the system.',
      );
    }
    return copied;
  }

  /// Point the feature at a locally built engine instead of the bundle —
  /// what you want while developing the engine itself.
  static void useLocalBuild({
    required String executable,
    required String model,
    String? libraryDir,
  }) {
    _cached = _Resolved(
      executable: executable,
      model: model,
      libraryDir: libraryDir,
    );
  }

  static Future<Map<String, int>> _loadManifest() async {
    try {
      final raw = await rootBundle.loadString('assets/bughouse/manifest.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return json.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return const {};
    }
  }

  static Future<void> _installAsset({
    required String asset,
    required String target,
    int? expectedSize,
  }) async {
    final file = File(target);
    if (await file.exists()) {
      // Size is enough to catch a half-written extraction or a version bump;
      // hashing 54 MB on every launch is not worth the milliseconds.
      final length = await file.length();
      if (expectedSize == null || length == expectedSize) return;
      await file.delete();
    }

    final ByteData data;
    try {
      data = await rootBundle.load(asset);
    } catch (e) {
      throw BughouseBundleMissing(asset);
    }
    final compressed = Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    await Isolate.run(() {
      File(target).writeAsBytesSync(gzip.decode(compressed), flush: true);
    });
  }
}

/// The app was built without the bughouse assets.
class BughouseBundleMissing implements Exception {
  BughouseBundleMissing(this.asset);
  final String asset;

  @override
  String toString() =>
      'This build does not include the bughouse engine (missing $asset).';
}

/// The assets are there, but installing them did not produce a usable engine.
class BughouseBundleBroken implements Exception {
  BughouseBundleBroken(this.message);
  final String message;

  @override
  String toString() => message;
}

class _Resolved {
  const _Resolved({
    required this.executable,
    required this.model,
    this.libraryDir,
  });
  final String executable;
  final String model;
  final String? libraryDir;
}
