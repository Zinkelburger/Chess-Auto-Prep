/// On-disk store for the Lichess cloud evaluations.
///
/// 394 million positions is too many for the `chessdb_evals` SQLite table the
/// ChessDB dump uses.  The keys are 64-bit hashes, so they arrive in random
/// order, and every insert into a primary-key B-tree that size lands on a
/// different page — the master-games importer already pays that cost for a
/// table two orders of magnitude smaller.  Since the data is immutable once
/// downloaded and only ever looked up by exact key, a sorted flat file is both
/// smaller and faster than a database here:
///
/// ```
///   evals.bin   32-byte header, then fixed 15-byte records sorted by key
///   evals.idx   every 1024th key, so a lookup is one disk read
///   evals.json  manifest: record count, source stamp, build state
/// ```
///
/// A record is 15 bytes (`pos`, `cp`, `mate`, `depth`, packed move), so the
/// whole database is about 5.9 GB rather than the ~10 GB the equivalent
/// SQLite table would take, and a lookup is a binary search in a 3 MB
/// in-memory key array followed by a single 15 KB read.
///
/// Scores are stored exactly as Lichess publishes them: **White-relative**
/// (see `lichess_eval_line.dart`).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../utils/atomic_file.dart';
import 'lichess_eval_line.dart';

/// Bytes per record in `evals.bin`.
const int kRecordBytes = 15;

/// Bytes of header before the first record.
const int kHeaderBytes = 32;

/// One key is remembered per this many records.
const int kIndexStride = 1024;

/// Bumped when the record layout changes; a store with another value is
/// rebuilt rather than misread.
const int kStoreFormatVersion = 1;

/// `CAPLEV01` — the file's magic, checked on open.
const List<int> kStoreMagic = [0x43, 0x41, 0x50, 0x4c, 0x45, 0x56, 0x30, 0x31];

/// Centipawn scores are clamped to this, which keeps the field 16-bit.
const int kMaxStoredCp = 32000;

/// Depths above this are stored as this; the field is one byte.
const int kMaxStoredDepth = 255;

/// Unsigned comparison of two 64-bit keys.
///
/// The keys are FNV hashes, so half of them are negative as signed integers.
/// Ordering them unsigned keeps the bucket a key falls into ([bucketOf]) and
/// its position in the file consistent.
int compareKeys(int a, int b) {
  if (a == b) return 0;
  final flippedA = a ^ _signBit;
  final flippedB = b ^ _signBit;
  return flippedA < flippedB ? -1 : 1;
}

const int _signBit = -9223372036854775808; // 0x8000000000000000

/// Top byte of [key], 0-255 — the bucket it sorts into.
int bucketOf(int key) => (key >> 56) & 0xff;

/// How many buckets [LichessEvalWriter] spreads records over.
const int kBucketCount = 256;

/// What a lookup found.
class StoredEval {
  const StoredEval({
    required this.cp,
    required this.mate,
    required this.depth,
    required this.move,
  });

  /// White-relative centipawns; meaningless when [mate] is set.
  final int cp;

  /// White-relative mate distance, or null.
  final int? mate;

  final int depth;

  /// Best move in UCI, or null when the published PV carried none.
  final String? move;
}

/// Where a built store lives.  [directory] holds the three files.
class LichessEvalStorePaths {
  const LichessEvalStorePaths(this.directory);

  final String directory;

  String get dataFile => '$directory${Platform.pathSeparator}evals.bin';
  String get indexFile => '$directory${Platform.pathSeparator}evals.idx';
  String get manifestFile => '$directory${Platform.pathSeparator}evals.json';

  /// Scratch directory for the bucket files a build writes before sorting.
  String get bucketDirectory =>
      '$directory${Platform.pathSeparator}build-buckets';
}

/// What a finished (or half-finished) store says about itself.
class LichessEvalManifest {
  const LichessEvalManifest({
    required this.records,
    required this.complete,
    this.sourceLastModified,
    this.sourceBytes,
    this.builtAt,
    this.linesRead = 0,
    this.stride = kIndexStride,
  });

  /// Positions in the finished store.
  final int records;

  /// False while a build is still bucketing or merging.
  final bool complete;

  /// `Last-Modified` of the download this was built from — the snapshot id.
  final String? sourceLastModified;

  final int? sourceBytes;
  final DateTime? builtAt;

  /// Lines of the JSONL consumed so far, so an interrupted scan resumes.
  final int linesRead;

  final int stride;

  Map<String, dynamic> toJson() => {
    'records': records,
    'complete': complete,
    if (sourceLastModified != null) 'source_last_modified': sourceLastModified,
    if (sourceBytes != null) 'source_bytes': sourceBytes,
    if (builtAt != null) 'built_at': builtAt!.toIso8601String(),
    'lines_read': linesRead,
    'stride': stride,
  };

  static LichessEvalManifest? fromJson(Map<String, dynamic> json) {
    final records = json['records'];
    if (records is! int) return null;
    final builtAt = json['built_at'];
    return LichessEvalManifest(
      records: records,
      complete: json['complete'] as bool? ?? false,
      sourceLastModified: json['source_last_modified'] as String?,
      sourceBytes: json['source_bytes'] as int?,
      builtAt: builtAt is String ? DateTime.tryParse(builtAt) : null,
      linesRead: json['lines_read'] as int? ?? 0,
      stride: json['stride'] as int? ?? kIndexStride,
    );
  }
}

/// Read and write the manifest beside the data files.
Future<LichessEvalManifest?> readManifest(LichessEvalStorePaths paths) async {
  final file = File(paths.manifestFile);
  if (!await file.exists()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) return null;
    return LichessEvalManifest.fromJson(decoded);
  } catch (_) {
    return null;
  }
}

Future<void> writeManifest(
  LichessEvalStorePaths paths,
  LichessEvalManifest manifest,
) async {
  await Directory(paths.directory).create(recursive: true);
  await writeTextFileAtomically(
    File(paths.manifestFile),
    const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
  );
}

// ── Reading ──────────────────────────────────────────────────────────────

/// Read-only handle on a finished store.
///
/// Holds the sparse key array in memory (3 MB for the full database) and
/// keeps one file handle open; [lookup] costs a binary search in RAM plus a
/// single read of [kIndexStride] records.
class LichessEvalStore {
  LichessEvalStore._(this._file, this._sparseKeys, this.records, this._stride);

  final RandomAccessFile _file;
  final Int64List _sparseKeys;
  final int _stride;

  /// Positions in the store.
  final int records;

  /// Opens the store in [directory], or null when it is absent or unfinished.
  static Future<LichessEvalStore?> open(String directory) async {
    if (directory.trim().isEmpty) return null;
    final paths = LichessEvalStorePaths(directory);
    final manifest = await readManifest(paths);
    if (manifest == null || !manifest.complete || manifest.records <= 0) {
      return null;
    }
    final data = File(paths.dataFile);
    final index = File(paths.indexFile);
    if (!await data.exists() || !await index.exists()) return null;

    final expected = kHeaderBytes + manifest.records * kRecordBytes;
    if (await data.length() < expected) return null;

    final handle = await data.open();
    try {
      final header = await handle.read(kHeaderBytes);
      final version = ByteData.sublistView(header).getInt32(8, Endian.little);
      for (var i = 0; i < kStoreMagic.length; i++) {
        if (header[i] != kStoreMagic[i]) {
          await handle.close();
          return null;
        }
      }
      if (version != kStoreFormatVersion) {
        await handle.close();
        return null;
      }
      // `sublistView` takes byte offsets into the source, and the view must
      // cover a whole number of 8-byte keys.
      final rawIndex = await index.readAsBytes();
      final usable = rawIndex.length - rawIndex.length % 8;
      final keys = Int64List.sublistView(rawIndex, 0, usable);
      return LichessEvalStore._(
        handle,
        keys,
        manifest.records,
        manifest.stride,
      );
    } catch (_) {
      await handle.close();
      return null;
    }
  }

  /// The eval stored for [key], or null.
  Future<StoredEval?> lookup(int key) async {
    if (records == 0 || _sparseKeys.isEmpty) return null;

    // Which sparse block could hold the key: the last one whose first key is
    // not greater than it.
    var lo = 0;
    var hi = _sparseKeys.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (compareKeys(_sparseKeys[mid], key) <= 0) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    if (compareKeys(_sparseKeys[lo], key) > 0) return null;

    final first = lo * _stride;
    final count = (first + _stride <= records) ? _stride : records - first;
    if (count <= 0) return null;

    await _file.setPosition(kHeaderBytes + first * kRecordBytes);
    final block = await _file.read(count * kRecordBytes);
    if (block.length < count * kRecordBytes) return null;
    final view = ByteData.sublistView(block);

    var blockLo = 0;
    var blockHi = count - 1;
    while (blockLo <= blockHi) {
      final mid = (blockLo + blockHi) >> 1;
      final midKey = view.getInt64(mid * kRecordBytes, Endian.little);
      final cmp = compareKeys(midKey, key);
      if (cmp == 0) return _decode(view, mid * kRecordBytes);
      if (cmp < 0) {
        blockLo = mid + 1;
      } else {
        blockHi = mid - 1;
      }
    }
    return null;
  }

  static StoredEval _decode(ByteData view, int at) {
    final mate = view.getInt16(at + 10, Endian.little);
    return StoredEval(
      cp: view.getInt16(at + 8, Endian.little),
      mate: mate == 0 ? null : mate,
      depth: view.getUint8(at + 12),
      move: unpackUci(view.getUint16(at + 13, Endian.little)),
    );
  }

  Future<void> close() => _file.close();
}

// ── Writing ──────────────────────────────────────────────────────────────

/// Encode one record into [target] at [at].
void encodeRecord(ByteData target, int at, LichessEvalRow row) {
  final mate = row.mate ?? 0;
  var cp = row.cp ?? 0;
  if (cp > kMaxStoredCp) cp = kMaxStoredCp;
  if (cp < -kMaxStoredCp) cp = -kMaxStoredCp;
  var mateOut = mate;
  if (mateOut > 32767) mateOut = 32767;
  if (mateOut < -32767) mateOut = -32767;
  target
    ..setInt64(at, row.pos, Endian.little)
    ..setInt16(at + 8, cp, Endian.little)
    ..setInt16(at + 10, mateOut, Endian.little)
    ..setUint8(
      at + 12,
      row.depth > kMaxStoredDepth ? kMaxStoredDepth : row.depth,
    )
    ..setUint16(at + 13, row.move, Endian.little);
}

/// Reads back a record — the inverse of [encodeRecord], for tests and for the
/// merge step, which sorts raw bytes.
({int pos, int cp, int mate, int depth, int move}) decodeRecord(
  ByteData view,
  int at,
) => (
  pos: view.getInt64(at, Endian.little),
  cp: view.getInt16(at + 8, Endian.little),
  mate: view.getInt16(at + 10, Endian.little),
  depth: view.getUint8(at + 12),
  move: view.getUint16(at + 13, Endian.little),
);

/// Header of `evals.bin`: the magic and a format version, nothing more.
///
/// The record count deliberately lives in the manifest rather than here.
/// Patching a count back into byte 8 after the records are written would mean
/// a positioned write into a file opened for appending, whose behaviour
/// differs between platforms; the manifest is written last anyway, and
/// [LichessEvalStore.open] already checks the count it claims against the
/// actual file length.
Uint8List buildHeader() {
  final header = Uint8List(kHeaderBytes);
  header.setRange(0, kStoreMagic.length, kStoreMagic);
  ByteData.sublistView(header).setInt32(8, kStoreFormatVersion, Endian.little);
  return header;
}
