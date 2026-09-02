/// Catalogue of ChessDB full-dump snapshots.
///
/// chessdb.cn publishes periodic snapshots of its cloud evaluation database
/// (`chess-YYYYMMDD`) on its own FTP server; the same snapshots are mirrored
/// on Hugging Face, which is what the in-app download uses — plain HTTPS with
/// byte-range resume, per-file sizes and SHA-256 digests, no extra tooling.
///
/// The FTP/rsync commands stay in the UI for anyone who would rather run the
/// transfer themselves.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Hugging Face dataset that mirrors the chessdb.cn snapshots.
const String kChessDbHfRepo = 'robertnurnberg/chessdbcn';

const String kChessDbHfDatasetUrl =
    'https://huggingface.co/datasets/$kChessDbHfRepo';

const String _kHfTreeApi =
    'https://huggingface.co/api/datasets/$kChessDbHfRepo/tree/main';

const String _kHfResolveBase =
    'https://huggingface.co/datasets/$kChessDbHfRepo/resolve/main';

/// Snapshot used when the catalogue cannot be reached (offline setup guide).
const String kChessDbFallbackSnapshotId = 'chess-20260702';

/// Download URL for a file inside the mirrored dataset.
Uri chessDbFileUrl(String repoPath) =>
    Uri.parse('$_kHfResolveBase/${Uri.encodeFull(repoPath)}');

/// One file of a snapshot, as the mirror describes it.
class CdbSnapshotFile {
  const CdbSnapshotFile({required this.path, required this.bytes, this.sha256});

  /// Path within the dataset, e.g. `chess-20260702/data/152796.sst`.
  final String path;
  final int bytes;

  /// Git-LFS object id, which is the file's SHA-256. Absent for the handful
  /// of small files (`CURRENT`, `MANIFEST-*`) stored outside LFS.
  final String? sha256;

  String get name => path.split('/').last;
}

/// A published snapshot: every file, and what it costs on disk.
class CdbSnapshot {
  const CdbSnapshot({required this.id, required this.files});

  /// Directory name, e.g. `chess-20260702`.
  final String id;
  final List<CdbSnapshotFile> files;

  int get totalBytes {
    var sum = 0;
    for (final f in files) {
      sum += f.bytes;
    }
    return sum;
  }

  /// Publication date parsed out of the id, or null if it does not fit.
  DateTime? get date => parseSnapshotDate(id);
}

/// `chess-20260702` → 2 July 2026.
DateTime? parseSnapshotDate(String id) {
  final m = RegExp(r'^chess-(\d{4})(\d{2})(\d{2})$').firstMatch(id);
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime(year, month, day);
}

/// Snapshot directory names from a Hugging Face tree listing, newest first.
///
/// Only `chess-*` entries are kept: the same dataset also carries the
/// xiangqi dump, which this app has no reader for.
List<String> parseHfSnapshotIds(String body) {
  final ids = <String>[];
  for (final entry in _decodeEntries(body)) {
    if (entry['type'] != 'directory') continue;
    final path = entry['path'];
    if (path is! String) continue;
    if (parseSnapshotDate(path) == null) continue;
    ids.add(path);
  }
  ids.sort((a, b) => b.compareTo(a));
  return ids;
}

/// Files from a Hugging Face tree listing (directories skipped).
List<CdbSnapshotFile> parseHfTreeFiles(String body) {
  final files = <CdbSnapshotFile>[];
  for (final entry in _decodeEntries(body)) {
    if (entry['type'] != 'file') continue;
    final path = entry['path'];
    if (path is! String) continue;
    final size = entry['size'];
    if (size is! int) continue;
    String? digest;
    final lfs = entry['lfs'];
    if (lfs is Map && lfs['oid'] is String) {
      digest = lfs['oid'] as String;
    }
    files.add(CdbSnapshotFile(path: path, bytes: size, sha256: digest));
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// `<https://…>; rel="next"` → the next page URL, or null at the end.
Uri? parseHfNextLink(String? linkHeader) {
  if (linkHeader == null || linkHeader.isEmpty) return null;
  for (final part in linkHeader.split(',')) {
    if (!part.contains('rel="next"')) continue;
    final start = part.indexOf('<');
    final end = part.indexOf('>', start + 1);
    if (start < 0 || end < 0) continue;
    return Uri.tryParse(part.substring(start + 1, end));
  }
  return null;
}

List<Map<String, dynamic>> _decodeEntries(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) return const [];
  return decoded.whereType<Map<String, dynamic>>().toList();
}

/// Reads the published snapshot list and per-file manifests.
class CdbSnapshotCatalog {
  CdbSnapshotCatalog({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Snapshot ids, newest first.
  Future<List<String>> listSnapshotIds() async {
    final body = await _get(Uri.parse('$_kHfTreeApi?limit=100'));
    return parseHfSnapshotIds(body.body);
  }

  /// Every file of [id], following the listing's pagination.
  Future<CdbSnapshot> fetchSnapshot(String id) async {
    final files = <CdbSnapshotFile>[];
    Uri? next = Uri.parse('$_kHfTreeApi/$id/data?limit=1000');
    var pages = 0;
    while (next != null && pages < 50) {
      final resp = await _get(next);
      files.addAll(parseHfTreeFiles(resp.body));
      next = parseHfNextLink(resp.headers['link']);
      pages++;
    }
    if (files.isEmpty) {
      throw CdbCatalogException('Snapshot $id lists no files.');
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return CdbSnapshot(id: id, files: files);
  }

  /// The newest published snapshot, with its manifest.
  Future<CdbSnapshot> fetchLatest() async {
    final ids = await listSnapshotIds();
    if (ids.isEmpty) {
      throw const CdbCatalogException('No snapshots are published right now.');
    }
    return fetchSnapshot(ids.first);
  }

  Future<http.Response> _get(Uri url) async {
    final http.Response resp;
    try {
      resp = await _client.get(url).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw CdbCatalogException('Could not reach the snapshot mirror: $e');
    }
    if (resp.statusCode != 200) {
      throw CdbCatalogException(
        'Snapshot mirror answered ${resp.statusCode} for $url',
      );
    }
    return resp;
  }

  void dispose() => _client.close();
}

class CdbCatalogException implements Exception {
  const CdbCatalogException(this.message);
  final String message;

  @override
  String toString() => message;
}
