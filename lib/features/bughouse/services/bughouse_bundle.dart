import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/app_paths.dart';
import '../../../utils/log.dart';
import 'windows_loader_check.dart';

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

  /// The sizes the shipped manifest says each extracted file should be, or
  /// empty before an install has run. What a diagnostic compares the files on
  /// disk against.
  static Map<String, int> get expectedSizes => _sizes;
  static Map<String, int> _sizes = const {};

  /// The three files this platform extracts, by the names they are written
  /// under. Public so a failure report can say which of them is wrong.
  static List<String> get installedFileNames => [
    _binaryName(),
    _runtimeName(),
    'hivemind.onnx',
  ];

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
  ///
  /// The manifest counts as a fourth part, because without it [_installAsset]
  /// has no size to check an already-extracted file against and therefore
  /// trusts whatever is on disk forever. A half-written 16 MB DLL left behind
  /// by a killed launch would then never be replaced, and Windows rejects a
  /// truncated image with the same status it uses for a 32-bit one — which is
  /// as obscure a failure as this feature can produce.
  @visibleForTesting
  static bool hasEngineAssets(Iterable<String> assetKeys) {
    final keys = assetKeys.toSet();
    return keys.contains('assets/bughouse/${_binaryName()}.gz') &&
        keys.contains('assets/bughouse/${_runtimeName()}.gz') &&
        keys.contains('assets/bughouse/hivemind.onnx.gz') &&
        keys.contains('assets/bughouse/manifest.json');
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
    _sizes = manifest;
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
      final copied = await installWindowsRuntime(
        source: applicationDirectory(),
        target: target,
      );
      // Say so at install time, not at first search. Whether the engine then
      // starts depends on the machine having the redistributable system-wide,
      // which most do — so this is a warning rather than a failure, but it is
      // the single most useful line in the log when it does not.
      final absent = [
        for (final name in WindowsLoaderCheck.appSuppliedDependencies)
          if (!copied.any((c) => c.toLowerCase() == name.toLowerCase())) name,
      ];
      if (absent.isNotEmpty) {
        log.w(
          'The bughouse engine has no app-supplied copy of '
          '${absent.join(', ')} in ${target.path}. It will start only on a '
          'machine that has the Microsoft Visual C++ Redistributable (x64) '
          'installed system-wide.',
        );
      }
    } else {
      final chmod = await Process.run('chmod', ['+x', executable]);
      if (chmod.exitCode != 0) {
        throw BughouseBundleBroken(
          'Could not make $executable executable: ${chmod.stderr}',
        );
      }
    }

    // Check what actually landed, rather than assuming the writes above did
    // what they were told. A file that came out the wrong size is not a
    // theoretical worry here: Windows keeps its own `onnxruntime.dll` in
    // System32, so an engine whose copy is missing or half-written does not
    // fail to start — it silently loads the operating system's ONNX Runtime
    // instead, and fails somewhere far less legible.
    final problems = await verifyExtraction(target.path, manifest);
    if (problems.isNotEmpty) {
      throw BughouseBundleBroken(
        'The bughouse engine did not extract correctly:\n'
        '${problems.map((p) => '  $p').join('\n')}\n'
        'Delete ${target.path} and open Bughouse Lab again.',
      );
    }

    _cached = _Resolved(
      executable: executable,
      model: model,
      libraryDir: target.path,
    );
    log.i('Bughouse engine installed at $executable');
    return executable;
  }

  /// What is wrong with the extraction in [directory], one line each.
  ///
  /// Sizes only, and only the ones [manifest] describes: hashing 70 MB on every
  /// launch would cost more than it is worth, and a wrong size is what every
  /// failure mode this catches actually looks like — an interrupted write, a
  /// full disk, an antivirus that truncated the file it was scanning.
  ///
  /// An empty [manifest] means the bundle shipped without one, which
  /// [hasEngineAssets] already refuses; there is nothing to check against, so
  /// nothing is reported.
  @visibleForTesting
  static Future<List<String>> verifyExtraction(
    String directory,
    Map<String, int> manifest,
  ) async {
    if (manifest.isEmpty) return const [];
    final problems = <String>[];
    for (final name in installedFileNames) {
      final expected = manifest[name];
      if (expected == null) continue;
      final file = File(p.join(directory, name));
      if (!await file.exists()) {
        problems.add('$name is missing');
        continue;
      }
      final actual = await file.length();
      if (actual != expected) {
        problems.add(
          '$name is $actual bytes, but should be $expected '
          '(the extraction did not finish)',
        );
      }
    }
    return problems;
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
    } catch (e) {
      // Not fatal — the extraction still works — but it turns off the only
      // check that ever notices a half-written file, so it is worth a line.
      log.w(
        'The bughouse asset manifest could not be read ($e); an '
        'incomplete extraction will not be detected.',
      );
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
