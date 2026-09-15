import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:chess_auto_prep/utils/log.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../storage/app_paths.dart';

/// Where [tools/fetch_assets.py] records upstream URLs and checksums.
const kStockfishLockAsset = 'tools/assets.lock.json';

/// The engine could not be installed from the bundle or the pinned release.
class StockfishInstallError extends StateError {
  StockfishInstallError(super.message);
}

/// File name of the extracted engine in the support directory (and of the
/// bundled `.gz` slot). macOS Apple Silicon and Intel share `stockfish-macos`;
/// [stockfishLockKey] says which upstream archive belongs in that slot.
String stockfishBinaryName() {
  if (Platform.isWindows) return 'stockfish-windows.exe';
  if (Platform.isMacOS) return 'stockfish-macos';
  if (Platform.isLinux) return 'stockfish-linux';
  throw UnsupportedError('Unsupported desktop platform');
}

/// Key in `tools/assets.lock.json` / `fetch_assets.py` TARGETS for this OS/arch.
String stockfishLockKey() {
  if (Platform.isWindows) return 'stockfish-windows';
  if (Platform.isLinux) return 'stockfish-linux';
  if (Platform.isMacOS) {
    return Abi.current() == Abi.macosArm64
        ? 'stockfish-macos-arm64'
        : 'stockfish-macos-x86_64';
  }
  throw UnsupportedError('Unsupported desktop platform');
}

/// Pull the engine out of an upstream Stockfish zip/tar/tar.gz archive.
Uint8List stockfishLargestArchiveMember(Uint8List bytes, String url) {
  final Archive archive;
  if (url.toLowerCase().endsWith('.zip')) {
    archive = ZipDecoder().decodeBytes(bytes);
  } else {
    archive = TarDecoder().decodeBytes(
      url.toLowerCase().endsWith('.gz') ? gzip.decode(bytes) : bytes,
    );
  }
  ArchiveFile? biggest;
  for (final f in archive) {
    if (!f.isFile) continue;
    if (biggest == null || f.size > biggest.size) biggest = f;
  }
  if (biggest == null) {
    throw StockfishInstallError('Stockfish archive from $url is empty');
  }
  return Uint8List.fromList(biggest.content);
}

/// One platform's entry in `tools/assets.lock.json`.
class _LockEntry {
  const _LockEntry({
    required this.key,
    required this.sourceSha256,
    required this.outputSha256,
    required this.url,
  });

  /// Decode the entry for [key]; both checksums are mandatory, the URL is
  /// only needed when the bundle has no engine.
  factory _LockEntry.fromLock(Map<String, dynamic> lock, String key) {
    final entry = lock[key];
    if (entry is! Map ||
        entry['source_sha256'] is! String ||
        entry['output_sha256'] is! String) {
      throw StockfishInstallError(
        'Missing Stockfish checksums for $key in $kStockfishLockAsset',
      );
    }
    return _LockEntry(
      key: key,
      sourceSha256: entry['source_sha256'] as String,
      outputSha256: entry['output_sha256'] as String,
      url: entry['url'] as String?,
    );
  }

  final String key;

  /// SHA-256 of the upstream archive; also the installed engine's identity.
  final String sourceSha256;

  /// SHA-256 of the bundled `.gz` asset.
  final String outputSha256;
  final String? url;

  /// What the `.origin` stamp next to the installed binary records.
  String get identity => '$key:$sourceSha256';
}

/// Extracts or downloads Stockfish into the app support directory.
class StockfishBundle {
  static String? _cachedPath;

  @visibleForTesting
  static void resetForTest() => _cachedPath = null;

  /// Resolve the Stockfish binary path, extracting from the asset bundle or
  /// downloading the pinned upstream release if the bundle has no engine.
  ///
  /// Cached after the first success. Must run on the main isolate (assets /
  /// path_provider). Subsequent pool workers should reuse the returned path.
  static Future<String> ensureExecutable() async {
    if (_cachedPath case final cached?) return cached;

    final binaryName = stockfishBinaryName();
    final entry = _LockEntry.fromLock(await _loadLock(), stockfishLockKey());
    final dir = await AppPaths.supportDirectory();
    final file = File(p.join(dir.path, binaryName));
    final stamp = File('${file.path}.origin');

    if (await file.exists()) {
      final stamped = await stamp.exists()
          ? (await stamp.readAsString()).trim()
          : null;
      if (stamped == entry.identity) return _cachedPath = file.path;
      log.i('Refreshing Stockfish ($stamped → ${entry.identity})');
      await file.delete();
    }

    await file.parent.create(recursive: true);
    log.i('Installing Stockfish to ${file.path}...');

    var downloaded = false;
    try {
      await _extractFromAssetBundle(binaryName, file.path, entry.outputSha256);
    } catch (e) {
      downloaded = true;
      log.i('Bundled Stockfish missing ($e); downloading ${entry.key}…');
      await _downloadFromLockfile(entry, file.path);
    }

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', file.path]);
    }
    await stamp.writeAsString(entry.identity);
    if (downloaded) log.i('Stockfish downloaded for local/unbundled run');
    return _cachedPath = file.path;
  }

  static Future<void> _extractFromAssetBundle(
    String binaryName,
    String targetPath,
    String expectedSha,
  ) async {
    final byteData = await rootBundle.load('assets/executables/$binaryName.gz');
    final compressed = Uint8List.fromList(
      byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ),
    );
    await Isolate.run(() {
      if (sha256.convert(compressed).toString() != expectedSha) {
        throw StockfishInstallError(
          'Bundled Stockfish does not match $kStockfishLockAsset',
        );
      }
      final decompressed = gzip.decode(compressed);
      File(targetPath).writeAsBytesSync(decompressed, flush: true);
    });
  }

  static Future<void> _downloadFromLockfile(
    _LockEntry entry,
    String targetPath,
  ) async {
    final url = entry.url;
    if (url == null || url.isEmpty) {
      throw StockfishInstallError('Lockfile ${entry.key} has no url');
    }

    final tmp = File('$targetPath.download');
    try {
      await _downloadTo(tmp, Uri.parse(url));
      await Isolate.run(() {
        _unpackDownloadedArchive(
          archivePath: tmp.path,
          targetPath: targetPath,
          url: url,
          expectedSha: entry.sourceSha256,
        );
      });
    } catch (e) {
      throw StockfishInstallError(
        'Could not install Stockfish. On a source checkout run '
        '`python3 tools/fetch_assets.py`, or check the network.\n$e',
      );
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  /// The lockfile from the asset bundle, or from the source tree when running
  /// unbundled (tests, `flutter run` from a checkout).
  static Future<Map<String, dynamic>> _loadLock() async {
    try {
      final json = await rootBundle.loadString(kStockfishLockAsset);
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      final fromSource = File(kStockfishLockAsset);
      if (await fromSource.exists()) {
        return jsonDecode(await fromSource.readAsString())
            as Map<String, dynamic>;
      }
      rethrow;
    }
  }

  static Future<void> _downloadTo(File dest, Uri url) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', url);
      request.headers['User-Agent'] = 'chess-auto-prep-fetch';
      final response = await client.send(request);
      if (response.statusCode != HttpStatus.ok) {
        throw StockfishInstallError(
          'Stockfish download HTTP ${response.statusCode} from $url',
        );
      }
      final sink = dest.openWrite();
      try {
        await response.stream.pipe(sink);
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }
}

/// Isolate entry: hash, unpack, write the engine. No Flutter.
void _unpackDownloadedArchive({
  required String archivePath,
  required String targetPath,
  required String url,
  required String expectedSha,
}) {
  final archiveBytes = File(archivePath).readAsBytesSync();
  final digest = sha256.convert(archiveBytes).toString();
  if (digest != expectedSha) {
    throw StockfishInstallError(
      'Stockfish checksum mismatch for $url\n'
      '  expected $expectedSha\n  got      $digest',
    );
  }
  final payload = stockfishLargestArchiveMember(
    Uint8List.fromList(archiveBytes),
    url,
  );
  File(targetPath).writeAsBytesSync(payload, flush: true);
}
