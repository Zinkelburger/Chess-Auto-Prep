import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:chess_auto_prep/utils/log.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../storage/app_paths.dart';

/// Where [tools/fetch_assets.py] records upstream URLs and checksums.
const kStockfishLockAsset = 'tools/assets.lock.json';

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

/// Pull the engine out of an upstream Stockfish zip/tar (largest regular file).
Uint8List stockfishLargestArchiveMember(Uint8List bytes, String url) {
  final Archive archive;
  if (url.toLowerCase().endsWith('.zip')) {
    archive = ZipDecoder().decodeBytes(bytes);
  } else {
    archive = TarDecoder().decodeBytes(bytes);
  }
  ArchiveFile? biggest;
  for (final f in archive) {
    if (!f.isFile) continue;
    if (biggest == null || f.size > biggest.size) biggest = f;
  }
  if (biggest == null) {
    throw StateError('Stockfish archive from $url is empty');
  }
  return Uint8List.fromList(biggest.content);
}

/// Extracts or downloads Stockfish into the app support directory.
class StockfishBundle {
  static String? _cachedPath;

  /// Resolve the Stockfish binary path, extracting from the asset bundle or
  /// downloading the pinned upstream release if the bundle has no engine.
  ///
  /// Cached after the first success. Must run on the main isolate (assets /
  /// path_provider). Subsequent pool workers should reuse the returned path.
  static Future<String> ensureExecutable() async {
    if (_cachedPath != null) return _cachedPath!;

    final binaryName = stockfishBinaryName();
    final key = stockfishLockKey();
    final dir = await AppPaths.supportDirectory();
    final file = File(p.join(dir.path, binaryName));
    final stamp = File('${file.path}.origin');

    if (await file.exists()) {
      final stamped = await stamp.exists()
          ? (await stamp.readAsString()).trim()
          : null;
      if (stamped == key) {
        _cachedPath = file.path;
        return _cachedPath!;
      }
      if (stamped == null && !Platform.isMacOS) {
        await stamp.writeAsString(key);
        _cachedPath = file.path;
        return _cachedPath!;
      }
      log.i('Refreshing Stockfish ($stamped → $key)');
      await file.delete();
    }

    await file.parent.create(recursive: true);
    log.i('Installing Stockfish to ${file.path}...');

    Object? bundleError;
    try {
      await _extractFromAssetBundle(binaryName, file.path);
    } catch (e) {
      bundleError = e;
      log.i(
        'Bundled Stockfish missing ($e); downloading ${stockfishLockKey()}…',
      );
      await _downloadFromLockfile(key, file.path);
    }

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', file.path]);
    }
    await stamp.writeAsString(key);
    _cachedPath = file.path;
    if (bundleError != null) {
      log.i('Stockfish downloaded for local/unbundled run');
    }
    return _cachedPath!;
  }

  static Future<void> _extractFromAssetBundle(
    String binaryName,
    String targetPath,
  ) async {
    final byteData = await rootBundle.load('assets/executables/$binaryName.gz');
    final compressed = Uint8List.fromList(
      byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ),
    );
    await Isolate.run(() {
      final decompressed = gzip.decode(compressed);
      File(targetPath).writeAsBytesSync(decompressed, flush: true);
    });
  }

  static Future<void> _downloadFromLockfile(
    String key,
    String targetPath,
  ) async {
    final lock = await _loadLock();
    final entry = lock[key];
    if (entry is! Map) {
      throw StateError(
        'No $key in $kStockfishLockAsset. Run: python3 tools/fetch_assets.py',
      );
    }
    final url = entry['url'] as String?;
    if (url == null || url.isEmpty) {
      throw StateError('Lockfile $key has no url');
    }
    final expectedSha = entry['source_sha256'] as String?;

    final tmp = File('$targetPath.download');
    try {
      await _downloadTo(tmp, Uri.parse(url));
      await Isolate.run(() {
        _unpackDownloadedArchive(
          archivePath: tmp.path,
          targetPath: targetPath,
          url: url,
          expectedSha: expectedSha,
        );
      });
    } catch (e) {
      throw StateError(
        'Could not install Stockfish. On a source checkout run '
        '`python3 tools/fetch_assets.py`, or check the network.\n$e',
      );
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

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
      if (response.statusCode != 200) {
        throw StateError(
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
  required String? expectedSha,
}) {
  final archiveBytes = File(archivePath).readAsBytesSync();
  final digest = sha256.convert(archiveBytes).toString();
  if (expectedSha != null && digest != expectedSha) {
    throw StateError(
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
