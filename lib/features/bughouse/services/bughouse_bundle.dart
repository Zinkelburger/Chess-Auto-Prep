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

  /// Directory containing libonnxruntime, or null when the platform links it
  /// statically / the engine was found on PATH.
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
  /// Both halves are required: a release job fetches one platform's engine, so
  /// a bundle can hold a Linux engine and no Windows one, and the network is
  /// fetched separately from the pair and could be the piece that is missing.
  @visibleForTesting
  static bool hasEngineAssets(Iterable<String> assetKeys) {
    final keys = assetKeys.toSet();
    return keys.contains('assets/bughouse/${_binaryName()}.gz') &&
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
  static Future<String> ensureInstalled() async {
    final cached = _cached;
    if (cached != null) return cached.executable;

    final dir = await AppPaths.supportDirectory();
    final target = Directory(p.join(dir.path, 'bughouse'));
    await target.create(recursive: true);

    final manifest = await _loadManifest();
    final executable = p.join(target.path, _binaryName());
    final model = p.join(target.path, 'hivemind.onnx');
    final runtime = p.join(target.path, _runtimeName());

    await _installAsset(
      asset: 'assets/bughouse/${_binaryName()}.gz',
      target: executable,
      expectedSize: manifest['engine'],
    );
    await _installAsset(
      asset: 'assets/bughouse/${_runtimeName()}.gz',
      target: runtime,
      expectedSize: manifest['runtime'],
    );
    await _installAsset(
      asset: 'assets/bughouse/hivemind.onnx.gz',
      target: model,
      expectedSize: manifest['model'],
    );

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', executable]);
    }

    _cached = _Resolved(
      executable: executable,
      model: model,
      libraryDir: target.path,
    );
    log.i('Bughouse engine installed at $executable');
    return executable;
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
