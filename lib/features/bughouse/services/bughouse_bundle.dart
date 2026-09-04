import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
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

  /// SHA-256 values for the extracted payloads. New release manifests carry
  /// these; old integer-only manifests stay readable for in-place upgrades.
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
    //
    // Sizes only. Content is already settled by the time we get here:
    // [_installAsset] returns either because the file on disk hashed correctly
    // or because [_extractVerifiedAsset] hashed the decoded payload before
    // writing it — which is the check that catches the right-sized corrupt
    // file the size test cannot see. Passing [_hashes] here as well re-read
    // and re-hashed the whole ~82 MB payload a second time on every launch,
    // for a comparison that had already been made and could not fail.
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
    final libraries = <File>[];
    await for (final entry in source.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!isWindowsRuntimeLibrary(name)) continue;
      libraries.add(entry);
    }

    // The installer deliberately omits loose VC++ DLLs after installing the
    // centrally serviced Microsoft prerequisite. Remove fallback DLLs copied
    // by an older portable/app-local build: a DLL beside Hivemind wins over
    // the repaired central copy and could preserve 0xC000007B across upgrades.
    if (libraries.isEmpty) {
      if (await target.exists()) {
        await for (final entry in target.list(followLinks: false)) {
          if (entry is! File ||
              !isWindowsRuntimeLibrary(p.basename(entry.path))) {
            continue;
          }
          try {
            await entry.delete();
            log.i('Removed stale app-local VC++ runtime ${entry.path}');
          } catch (e) {
            log.w('Could not remove stale VC++ runtime ${entry.path}: $e');
          }
        }
      }
      return copied;
    }

    for (final entry in libraries) {
      final name = p.basename(entry.path);
      final dest = File(p.join(target.path, name));
      try {
        final sourceHash = await _hashOf(entry.openRead());
        if (sourceHash == null) {
          throw FileSystemException('could not hash source file', entry.path);
        }
        if (await dest.exists() &&
            await dest.length() == await entry.length() &&
            await _hashOf(dest.openRead()) == sourceHash) {
          copied.add(name);
          continue;
        }

        final partial = File('${dest.path}.$pid.partial');
        if (await partial.exists()) await partial.delete();
        try {
          await entry.copy(partial.path);
          if (await _hashOf(partial.openRead()) != sourceHash) {
            throw FileSystemException('checksum changed while copying', name);
          }
          if (await dest.exists()) await dest.delete();
          await partial.rename(dest.path);
        } finally {
          if (await partial.exists()) await partial.delete();
        }
        copied.add(name);
      } catch (e) {
        // A locked or in-use DLL is survivable — the system copy may still
        // be there — so say so and carry on rather than failing the launch.
        log.w('Could not copy $name beside the bughouse engine: $e');
      }
    }
    return copied;
  }

  /// Whether the installed files are still the bytes this build carries, and
  /// removal of any that are not.
  ///
  /// [verifyExtraction] compares sizes, which catches every write that stopped
  /// early — a full disk, a killed launch, an antivirus that truncated the
  /// file it was scanning. It cannot catch the one failure that looks like
  /// nothing at all: a file of exactly the right length holding the wrong
  /// bytes. Windows refuses such an image with STATUS_INVALID_IMAGE_FORMAT,
  /// the same status it uses for a 32-bit library, and its PE header still
  /// parses — so the architecture reads back as x64 and every other line of
  /// the diagnostic calls the file healthy. Worse, [_installAsset] re-extracts
  /// only when the size differs, so nothing the user can do from inside the
  /// app — no upgrade, no reinstall — ever replaces it. That is the state this
  /// exists to end.
  ///
  /// The comparison needs no shipped hash and so cannot drift: the reference
  /// for an extracted file is the compressed asset in this very build, and for
  /// a Visual C++ library it is the app's own copy beside the running
  /// executable, which this process has by definition already loaded. A file
  /// that differs from either is wrong, full stop — so it is deleted, the
  /// resolved paths are dropped, and the next [ensureInstalled] writes it
  /// again.
  ///
  /// Deliberately not on the launch path: it hashes about 70 MB. It runs once,
  /// after a launch has already failed.
  static Future<ContentVerification> verifyAndRepair() async {
    final directory = _installDirectory;
    if (directory == null) return const ContentVerification.none();

    final lines = <String>[];
    final damaged = <String>[];

    Future<void> compare(String name, String? want, String reference) async {
      final file = File(p.join(directory, name));
      if (!await file.exists()) return;
      final label = '  ${name.padRight(28)}';
      final got = await _hashOf(file.openRead());
      if (want == null || got == null) {
        lines.add('$label could not be compared against $reference');
      } else if (got == want) {
        lines.add('$label matches $reference');
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
      final appDir = applicationDirectory();
      if (await appDir.exists()) {
        await for (final entry in appDir.list(followLinks: false)) {
          if (entry is! File) continue;
          final name = p.basename(entry.path);
          if (!isWindowsRuntimeLibrary(name)) continue;
          await compare(
            name,
            await _hashOf(entry.openRead()),
            "the app's own copy of it",
          );
        }
      }
    }

    for (final name in damaged) {
      try {
        await File(p.join(directory, name)).delete();
      } catch (e) {
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
    _cached = _Resolved(
      executable: executable,
      model: model,
      libraryDir: libraryDir,
    );
  }

  static Future<Map<String, _AssetIntegrity>> _loadManifest() async {
    try {
      final raw = await rootBundle.loadString('assets/bughouse/manifest.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return json.map((name, value) {
        // Integer-only manifests shipped before payload hashes were added.
        if (value is num) {
          return MapEntry(name, _AssetIntegrity(bytes: value.toInt()));
        }
        final record = value as Map<String, dynamic>;
        return MapEntry(
          name,
          _AssetIntegrity(
            bytes: (record['bytes'] as num).toInt(),
            sha256: (record['sha256'] as String?)?.toLowerCase(),
          ),
        );
      });
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
    final what = damaged.length == 1
        ? "The engine's ${damaged.single} was damaged"
        : '${damaged.length} of the engine\'s files were damaged';
    return '$what on disk — the bytes did not match the copy inside this '
        'build, which is why Windows refused to load it. It has been removed. '
        'Open Bughouse Lab again and the app will write a fresh one.';
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
