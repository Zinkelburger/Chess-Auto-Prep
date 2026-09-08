import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/app_paths.dart';
import '../../../utils/log.dart';
import 'bughouse_windows_runtime.dart';

/// Resolves the three files Hivemind needs at runtime, extracting them from
/// the asset bundle on first use — the same shape as [StockfishBundle], with
/// one extra part: the ONNX Runtime shared library.
///
/// Hivemind is Copyright (c) 2026 aminwoo, MIT licensed. Its full notice is
/// bundled at `assets/licenses/HIVEMIND_LICENSE.txt`; source and portable-build
/// provenance are recorded there and in `tools/bughouse.lock.json`.
///
/// Why three files rather than one static binary: the upstream engine links
/// TensorRT, which is ~2 GB of NVIDIA redistributables and NVIDIA-only. Built
/// against ONNX Runtime instead, the engine is a 1.9 MB binary plus a 28 MB
/// runtime plus the network — and it runs on any desktop.
class BughouseBundle {
  static _Resolved? _cached;

  static List<String> _installationDiagnostics = [];
  static List<String> get installationDiagnostics =>
      List.unmodifiable(_installationDiagnostics);

  /// Where [_install] put the files, or null before it has run — and null for
  /// a local build pointed at by [useLocalBuild], which came from somewhere
  /// this build's assets say nothing about and must never be compared to them.
  static String? _installDirectory;

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

  /// Required SHA-256 values for the extracted payloads in this build.
  static Map<String, String> get expectedHashes => _hashes;
  static Map<String, String> _hashes = const {};

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
    if (cached != null && _installDirectory == null) {
      return Future.value(cached.executable); // Explicit local-build override.
    }
    // One extraction at a time. Two callers arriving together (the analysis
    // pump and a button press during the first launch) would otherwise write
    // the same 54 MB network concurrently.
    return _installing ??= _install().whenComplete(() => _installing = null);
  }

  static Future<String>? _installing;

  static Future<String> _install() async {
    _cached = null;
    _installationDiagnostics = [];
    try {
      return await _installFiles();
    } catch (e) {
      if (e is BughouseRuntimeFailure) {
        _installationDiagnostics.addAll(e.lines);
      }
      _installationDiagnostics.add('Installation failed: $e');
      throw BughouseBundleBroken(
        'Engine dependency verification failed: $e',
        diagnostics: List.of(_installationDiagnostics),
      );
    }
  }

  static Future<String> _installFiles() async {
    final dir = await AppPaths.supportDirectory();
    final target = Directory(p.join(dir.path, 'bughouse'));
    await target.create(recursive: true);
    _installDirectory = target.path;
    _installationDiagnostics.add('Engine folder: ${target.path}');

    final manifest = await _loadManifest();
    _sizes = {
      for (final entry in manifest.entries) entry.key: entry.value.bytes,
    };
    _hashes = {
      for (final entry in manifest.entries) entry.key: ?entry.value.sha256,
    };
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
        expectedSize: manifest[name]?.bytes,
        expectedSha256: manifest[name]?.sha256,
      );
      _installationDiagnostics.add(
        '$name: verified SHA-256 ${manifest[name]!.sha256}',
      );
    }

    if (Platform.isWindows) {
      _installationDiagnostics.addAll(
        await installWindowsRuntime(
          source: applicationDirectory(),
          target: target,
        ),
      );
      for (final name in [_binaryName(), _runtimeName()]) {
        await BughouseWindowsRuntime.requireX64(
          File(p.join(target.path, name)),
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

    // Existing files were hashed above; new payloads are checked both before
    // writing and from the staged file before installation.
    final problems = await verifyExtraction(target.path, _sizes);
    if (problems.isNotEmpty) {
      throw BughouseBundleBroken(
        'The bughouse engine did not extract correctly:\n'
        '${problems.map((p) => '  $p').join('\n')}\n'
        'Delete ${target.path} and open Bughouse Lab again.',
      );
    }

    _installDirectory = target.path;
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
  /// Size and, when supplied, SHA-256. A damaged PE can retain its original
  /// length, and Windows reports that case as STATUS_INVALID_IMAGE_FORMAT —
  /// exactly the opaque 0xC000007B launch failure this validation must prevent.
  ///
  /// An empty [manifest] means the bundle shipped without one, which
  /// [hasEngineAssets] already refuses; there is nothing to check against, so
  /// nothing is reported.
  @visibleForTesting
  static Future<List<String>> verifyExtraction(
    String directory,
    Map<String, int> manifest, {
    Map<String, String> expectedHashes = const {},
  }) async {
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
        continue;
      }
      final expectedHash = expectedHashes[name];
      if (expectedHash != null) {
        final actualHash = await _hashOf(file.openRead());
        if (actualHash != expectedHash.toLowerCase()) {
          problems.add(
            '$name is corrupted (SHA-256 $actualHash, expected '
            '${expectedHash.toLowerCase()})',
          );
        }
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
  static bool isWindowsRuntimeLibrary(String name) =>
      BughouseWindowsRuntime.isRuntime(name);

  /// Returns the checks and repairs performed against this build's archive.
  @visibleForTesting
  static Future<List<String>> installWindowsRuntime({
    required Directory source,
    required Directory target,
  }) => BughouseWindowsRuntime.ensureInstalled(
    archive: BughouseWindowsRuntime.archiveDirectory(source),
    target: target,
  );

  /// After a failed launch, records content mismatches and removal results.
  /// The next launch independently verifies and restores managed files from
  /// this build's assets and private VC++ archive.
  static Future<ContentVerification> verifyAndRepair() async {
    final directory = _installDirectory;
    if (directory == null) return const ContentVerification.none();

    final lines = <String>[];
    final damaged = <String>[];

    Future<void> compare(String name, String? want, String reference) async {
      final file = File(p.join(directory, name));
      final label = '  ${name.padRight(28)}';
      if (!await file.exists()) {
        lines.add('$label MISSING');
        return;
      }
      final got = await _hashOf(file.openRead());
      if (want == null || got == null) {
        lines.add('$label could not be compared against $reference');
      } else if (got == want) {
        lines.add('$label matches $reference (SHA-256 $got)');
      } else {
        lines.add('$label DOES NOT MATCH $reference');
        lines.add('  ${' '.padRight(28)}on disk $got');
        lines.add('  ${' '.padRight(28)}should be $want');
        damaged.add(name);
      }
    }

    for (final name in installedFileNames) {
      await compare(
        name,
        await _hashOfAsset('assets/bughouse/$name.gz'),
        'the copy inside this build',
      );
    }

    if (Platform.isWindows) {
      try {
        final manifest = await BughouseWindowsRuntime.readManifest(
          BughouseWindowsRuntime.archiveDirectory(applicationDirectory()),
        );
        for (final entry in manifest.entries) {
          await compare(
            entry.key,
            entry.value.hash,
            'the bundled VC++ manifest',
          );
        }
      } catch (e) {
        lines.add('VC++ manifest check failed: $e');
      }
    }

    for (final name in damaged) {
      try {
        await File(p.join(directory, name)).delete();
        lines.add('  $name: removed; will be extracted on next launch');
      } catch (e) {
        lines.add('  $name: removal failed: $e');
        log.w('Could not remove the damaged $name: $e');
      }
    }
    if (damaged.isNotEmpty) {
      // Otherwise the next ensureInstalled hands back the paths it resolved
      // before any of this was known and never re-extracts a thing.
      _cached = null;
      log.w(
        'Removed ${damaged.join(', ')} from $directory; they did not match '
        'what this build carries and will be written again.',
      );
    }
    return ContentVerification(lines: lines, damaged: damaged);
  }

  /// SHA-256 of a byte stream, or null when it could not be read.
  ///
  /// Streamed rather than read whole because the network alone is 54 MB and
  /// this only ever runs on a machine that is already having a bad day.
  static Future<String?> _hashOf(Stream<List<int>> bytes) async {
    try {
      return (await sha256.bind(bytes).first).toString();
    } catch (_) {
      return null;
    }
  }

  /// SHA-256 of what a bundled asset decompresses to, without ever holding the
  /// decompressed copy.
  static Future<String?> _hashOfAsset(String asset) async {
    try {
      final data = await rootBundle.load(asset);
      final compressed = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return await _hashOf(gzip.decoder.bind(Stream.value(compressed)));
    } catch (_) {
      return null;
    }
  }

  /// Point the feature at a locally built engine instead of the bundle —
  /// what you want while developing the engine itself.
  static void useLocalBuild({
    required String executable,
    required String model,
    String? libraryDir,
  }) {
    _installDirectory = null;
    _installationDiagnostics = [];
    _cached = _Resolved(
      executable: executable,
      model: model,
      libraryDir: libraryDir,
    );
  }

  static Future<Map<String, _AssetIntegrity>> _loadManifest() async {
    final raw = await rootBundle.loadString('assets/bughouse/manifest.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final manifest = <String, _AssetIntegrity>{};
    for (final name in installedFileNames) {
      final record = json[name];
      if (record is! Map<String, dynamic> ||
          record['bytes'] is! int ||
          (record['bytes'] as int) <= 0 ||
          record['sha256'] is! String ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(record['sha256'] as String)) {
        throw FormatException(
          'Missing size/SHA-256 for $name in assets/bughouse/manifest.json',
        );
      }
      manifest[name] = _AssetIntegrity(
        bytes: record['bytes'] as int,
        sha256: (record['sha256'] as String).toLowerCase(),
      );
    }
    return manifest;
  }

  static Future<void> _installAsset({
    required String asset,
    required String target,
    int? expectedSize,
    String? expectedSha256,
  }) async {
    final file = File(target);
    if (await file.exists()) {
      final length = await file.length();
      final sizeMatches = expectedSize == null || length == expectedSize;
      final actualHash = sizeMatches && expectedSha256 != null
          ? await _hashOf(file.openRead())
          : null;
      final hashMatches =
          expectedSha256 == null || actualHash == expectedSha256.toLowerCase();
      if (sizeMatches && hashMatches) return;
      _installationDiagnostics.add(
        '${p.basename(target)}: mismatch ($length bytes, SHA-256 $actualHash); replacing',
      );
    }

    final ByteData data;
    try {
      data = await rootBundle.load(asset);
    } catch (e) {
      throw BughouseBundleBroken('Could not read bundled asset $asset: $e');
    }
    final compressed = Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    try {
      await Isolate.run(
        () => _extractVerifiedAsset(
          compressed: compressed,
          target: target,
          expectedSize: expectedSize,
          expectedSha256: expectedSha256,
        ),
      );
    } catch (e) {
      throw BughouseBundleBroken('Could not install ${p.basename(target)}: $e');
    }
  }
}

class _AssetIntegrity {
  const _AssetIntegrity({required this.bytes, this.sha256});

  final int bytes;
  final String? sha256;
}

void _extractVerifiedAsset({
  required Uint8List compressed,
  required String target,
  required int? expectedSize,
  required String? expectedSha256,
}) {
  final payload = gzip.decode(compressed);
  if (expectedSize != null && payload.length != expectedSize) {
    throw StateError('decoded ${payload.length} bytes; expected $expectedSize');
  }
  if (expectedSha256 != null) {
    final actual = sha256.convert(payload).toString();
    if (actual != expectedSha256.toLowerCase()) {
      throw StateError(
        'decoded SHA-256 is $actual; expected ${expectedSha256.toLowerCase()}',
      );
    }
  }

  final destination = File(target);
  final partial = File('$target.$pid.partial');
  try {
    if (partial.existsSync()) partial.deleteSync();
    partial.writeAsBytesSync(payload, flush: true);
    if (expectedSha256 != null &&
        sha256.convert(partial.readAsBytesSync()).toString() !=
            expectedSha256.toLowerCase()) {
      throw FileSystemException(
        'Staged payload failed SHA-256 verification',
        partial.path,
      );
    }
    if (destination.existsSync()) destination.deleteSync();
    partial.renameSync(target);
  } finally {
    if (partial.existsSync()) partial.deleteSync();
  }
}

/// What comparing the installed files against this build found.
@immutable
class ContentVerification {
  const ContentVerification({required this.lines, required this.damaged});

  /// Nothing to compare: a local engine build, or an install that never ran.
  const ContentVerification.none() : lines = const [], damaged = const [];

  /// One line per file compared, in the words the diagnostic report prints.
  final List<String> lines;

  /// The files whose bytes were wrong. Already deleted by
  /// [BughouseBundle.verifyAndRepair], so the next install writes them again.
  final List<String> damaged;

  bool get isEmpty => lines.isEmpty;

  /// The sentence to put in front of the user, or null when nothing is wrong.
  String? get repairedMessage {
    if (damaged.isEmpty) return null;
    return 'File mismatch: ${damaged.join(', ')}. '
        'See removal results above. Open Bughouse Lab again to retry extraction.';
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
  BughouseBundleBroken(this.message, {this.diagnostics = const []});
  final String message;
  final List<String> diagnostics;

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
