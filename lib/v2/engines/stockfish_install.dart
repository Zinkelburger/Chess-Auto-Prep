import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';

sealed class StockfishLocation {
  const StockfishLocation();
}

final class StockfishReady extends StockfishLocation {
  const StockfishReady(this.path);

  final String path;
}

final class StockfishMissing extends StockfishLocation {
  const StockfishMissing(this.reason);

  final String reason;
}

/// Puts the bundled Stockfish where it can run.
///
/// The build ships the engine gzipped as an asset, with its checksums in
/// `tools/assets.lock.json`. The first run writes it to the support folder
/// beside a stamp naming the release, so a new release replaces it and an
/// unchanged one costs one stat. The old app keeps the same file and
/// stamp, so both apps share one copy.
///
/// Nothing here throws: a damaged lock file, an unreadable stamp, a corrupt
/// asset or a support folder that cannot be written come back as
/// [StockfishMissing], because the workspace has to be able to say "no
/// engine" and carry on. A release that ships a bad asset says so and leaves
/// the engine already installed where it is.
final class StockfishInstall {
  StockfishInstall({required this.supportDirectory, required this.readAsset});

  final Directory supportDirectory;

  /// Reads a bundled asset, or null when the build has none by that name.
  final Future<Uint8List?> Function(String asset) readAsset;

  Future<StockfishLocation> locate() async {
    final bytes = await readAsset(_lockAsset);
    if (bytes == null) {
      return const StockfishMissing('This build has no Stockfish checksums');
    }
    final _Release? release;
    try {
      release = _release(bytes);
    } on FormatException catch (e) {
      log.e('read $_lockAsset', e);
      return StockfishMissing('$_lockAsset is damaged: $e');
    }
    if (release == null) {
      return StockfishMissing(
        'This build has no Stockfish checksums for $_lockKey',
      );
    }
    final binary = File(p.join(supportDirectory.path, _binaryName));
    final stamp = File('${binary.path}.origin');
    final bool installed;
    try {
      installed =
          await binary.exists() && await _stamped(stamp) == release.identity;
    } on FileSystemException catch (e) {
      log.e('read ${stamp.path}', e);
      return StockfishMissing(
        'Could not read the Stockfish stamp: ${e.message}',
      );
    }
    if (installed) return StockfishReady(binary.path);
    return _install(release, binary, stamp);
  }

  /// Throws [FormatException] when the asset is not the JSON it should be.
  _Release? _release(Uint8List bytes) {
    final lock = jsonDecode(utf8.decode(bytes));
    final entry = lock is Map ? lock[_lockKey] : null;
    if (entry is! Map) return null;
    final source = entry['source_sha256'];
    final asset = entry['output_sha256'];
    if (source is! String || asset is! String) return null;
    return _Release(key: _lockKey, sourceSha256: source, assetSha256: asset);
  }

  Future<StockfishLocation> _install(
    _Release release,
    File binary,
    File stamp,
  ) async {
    final compressed = await readAsset('assets/executables/$_binaryName.gz');
    if (compressed == null) {
      return const StockfishMissing(
        'This build has no bundled Stockfish; run tools/fetch_assets.py',
      );
    }
    final kept = await binary.exists();
    try {
      final result = await _write(release, binary.path, stamp, compressed);
      return switch (result) {
        StockfishMissing(:final reason) => StockfishMissing(
          _kept(reason, kept),
        ),
        StockfishReady() => result,
      };
    } catch (e) {
      // A corrupt asset, a full disk, a read-only support folder: the pane
      // says so and starts without an engine rather than hanging.
      log.e('install $_binaryName', e);
      return StockfishMissing(
        _kept('Could not install $_binaryName: $e', kept),
      );
    }
  }

  /// Unpacks and checks the whole engine under a temporary name, and only
  /// then puts it in place and stamps it.
  ///
  /// Nothing the build already has is touched until the new engine is known
  /// to be sound, because a release that ships a bad asset would otherwise
  /// disown the working engine on the disk and fail the same way at every
  /// later launch. The stamp is the claim that the binary is installed, so
  /// it goes last: an install interrupted between the two leaves the old
  /// stamp, which does not match, and the next launch installs again.
  Future<StockfishLocation> _write(
    _Release release,
    String target,
    File stamp,
    Uint8List compressed,
  ) async {
    await supportDirectory.create(recursive: true);
    final partial = File('$target.part');
    try {
      final expected = release.assetSha256;
      final problem = await Isolate.run(
        () => _unpack(compressed, expected, partial.path),
      );
      if (problem != null) return StockfishMissing(problem);
      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', ['+x', partial.path]);
        if (chmod.exitCode != 0) {
          return StockfishMissing(
            'Could not make $_binaryName runnable: ${chmod.stderr}',
          );
        }
      }
      await partial.rename(target);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
    await stamp.writeAsString(release.identity);
    return StockfishReady(target);
  }

  /// [reason], saying as well that the engine on the disk still runs.
  String _kept(String reason, bool kept) =>
      kept ? '$reason; the engine already installed is untouched' : reason;
}

/// Hashes and inflates 80 MB, so it runs in its own isolate. Returns the
/// problem, or null; anything else it hits is thrown to [StockfishInstall],
/// which turns it into a [StockfishMissing]. Writes to [partial], which is
/// nothing the app runs, so a failure here leaves the installed engine and
/// its stamp exactly as they were.
String? _unpack(Uint8List compressed, String expectedSha256, String partial) {
  if (sha256.convert(compressed).toString() != expectedSha256) {
    return 'The bundled Stockfish does not match tools/assets.lock.json';
  }
  File(partial).writeAsBytesSync(gzip.decode(compressed), flush: true);
  return null;
}

Future<String?> _stamped(File stamp) async =>
    await stamp.exists() ? (await stamp.readAsString()).trim() : null;

final class _Release {
  const _Release({
    required this.key,
    required this.sourceSha256,
    required this.assetSha256,
  });

  final String key;

  /// SHA-256 of the upstream archive: the release's identity.
  final String sourceSha256;

  /// SHA-256 of the bundled `.gz` asset.
  final String assetSha256;

  /// What the `.origin` stamp beside the installed binary says.
  String get identity => '$key:$sourceSha256';
}

const _lockAsset = 'tools/assets.lock.json';

String get _binaryName {
  if (Platform.isWindows) return 'stockfish-windows.exe';
  if (Platform.isMacOS) return 'stockfish-macos';
  return 'stockfish-linux';
}

/// The lock file has one Stockfish per OS, two for macOS.
String get _lockKey {
  if (Platform.isWindows) return 'stockfish-windows';
  if (!Platform.isMacOS) return 'stockfish-linux';
  return Abi.current() == Abi.macosArm64
      ? 'stockfish-macos-arm64'
      : 'stockfish-macos-x86_64';
}
