/// Turning `lichess_db_eval.jsonl.zst` into the sorted store.
///
/// Runs in its own isolate; the controller drives it and shows progress.  Two
/// phases, because the records arrive keyed by a hash and the store must end
/// up sorted:
///
///   1. **Scan.**  Decompress, split lines, keep the deepest eval of each,
///      and append the 15-byte record to one of 256 bucket files chosen by
///      the top byte of the key.  Sequential appends only.
///   2. **Merge.**  Sort each bucket in memory (a bucket is ~23 MB for the
///      full file) and append it to `evals.bin` in bucket order, recording
///      every 1024th key into `evals.idx`.  Buckets are visited in ascending
///      order and the key's top byte *is* the bucket number, so the result is
///      globally sorted.
///
/// The scan is resumable: the manifest records how many lines were consumed
/// and how long each bucket file was at the last checkpoint, so a restart
/// truncates the buckets back to that point and skips forward in the stream.
/// Re-reading the compressed prefix costs minutes; re-parsing it would cost
/// hours, so nothing before the checkpoint is parsed again.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'lichess_eval_line.dart';
import 'lichess_eval_store.dart';
import 'zstd_stream.dart';

/// What the isolate is doing.
enum LichessImportPhase { scanning, merging, done, failed }

/// A progress tick sent back to the controller.
class LichessImportProgress {
  const LichessImportProgress({
    required this.phase,
    this.linesRead = 0,
    this.rowsWritten = 0,
    this.compressedBytesRead = 0,
    this.bucketsMerged = 0,
    this.error,
  });

  final LichessImportPhase phase;
  final int linesRead;
  final int rowsWritten;

  /// Position in the `.zst`, for a progress fraction against its size.
  final int compressedBytesRead;

  final int bucketsMerged;
  final String? error;
}

/// Everything the isolate needs; must be sendable.
class LichessImportRequest {
  const LichessImportRequest({
    required this.archivePath,
    required this.storeDirectory,
    required this.sendPort,
    this.sourceLastModified,
    this.sourceBytes,
    this.backend,
    this.checkpointEvery = 2000000,
  });

  final String archivePath;
  final String storeDirectory;
  final SendPort sendPort;
  final String? sourceLastModified;
  final int? sourceBytes;

  /// Forces a decompressor; null probes.
  final ZstdBackend? backend;

  /// Lines between manifest checkpoints.
  final int checkpointEvery;
}

/// Cooperative cancellation: the controller sends `true` on this port.
class LichessImportControl {
  LichessImportControl();
  bool cancelled = false;
}

/// Entry point for `Isolate.spawn`.
Future<void> runLichessImportIsolate(LichessImportRequest request) async {
  final control = LichessImportControl();
  final receive = ReceivePort();
  request.sendPort.send(receive.sendPort);
  receive.listen((message) {
    if (message == 'cancel') control.cancelled = true;
  });
  try {
    await importLichessEvals(request, control);
  } catch (e) {
    request.sendPort.send(
      LichessImportProgress(phase: LichessImportPhase.failed, error: '$e'),
    );
  } finally {
    receive.close();
  }
}

/// Scan then merge.  Sends [LichessImportProgress] to `request.sendPort`.
///
/// [openStream] is the seam the tests use to feed plain bytes instead of a
/// compressed file; production leaves it null and the archive is decompressed.
Future<void> importLichessEvals(
  LichessImportRequest request,
  LichessImportControl control, {
  Stream<List<int>> Function(String path)? openStream,
}) async {
  final paths = LichessEvalStorePaths(request.storeDirectory);
  final resumed = await readManifest(paths);
  final stale =
      resumed != null &&
      request.sourceLastModified != null &&
      resumed.sourceLastModified != null &&
      resumed.sourceLastModified != request.sourceLastModified;

  var linesToSkip = 0;
  List<int> bucketLengths = List<int>.filled(kBucketCount, 0);
  var rowsWritten = 0;
  if (resumed != null && !resumed.complete && !stale) {
    linesToSkip = resumed.linesRead;
    final saved = await _readBucketLengths(paths);
    if (saved != null) {
      bucketLengths = saved;
      rowsWritten = saved.fold(0, (a, b) => a + b) ~/ kRecordBytes;
    } else {
      linesToSkip = 0;
    }
  }
  if (stale) {
    // A newer publication invalidates every bucket written from the old one.
    await _clearBuckets(paths);
  }

  // After the staleness check, so a discarded build's directory is recreated
  // rather than reopened out from under the writer.
  await Directory(paths.bucketDirectory).create(recursive: true);
  final writer = _BucketWriter(paths.bucketDirectory);
  await writer.open(bucketLengths);

  var linesRead = 0;
  var lastCheckpoint = 0;
  var compressedRead = 0;

  void report(LichessImportPhase phase, {int bucketsMerged = 0}) {
    request.sendPort.send(
      LichessImportProgress(
        phase: phase,
        linesRead: linesRead,
        rowsWritten: rowsWritten,
        compressedBytesRead: compressedRead,
        bucketsMerged: bucketsMerged,
      ),
    );
  }

  Future<void> checkpoint() async {
    await writer.flush();
    await _writeBucketLengths(paths, writer.lengths);
    await writeManifest(
      paths,
      LichessEvalManifest(
        records: rowsWritten,
        complete: false,
        sourceLastModified: request.sourceLastModified,
        sourceBytes: request.sourceBytes,
        linesRead: linesRead,
      ),
    );
  }

  try {
    final splitter = _LineSplitter();
    final stream = openStream != null
        ? openStream(request.archivePath)
        : openZstdStream(request.archivePath, prefer: request.backend);
    outer:
    await for (final chunk in stream) {
      compressedRead += chunk.length;
      for (final line in splitter.add(chunk)) {
        linesRead++;
        if (linesRead <= linesToSkip) continue;
        final row = parseLichessEvalLine(line);
        if (row != null) {
          writer.add(row);
          rowsWritten++;
        }
        if (linesRead - lastCheckpoint >= request.checkpointEvery) {
          lastCheckpoint = linesRead;
          await checkpoint();
          report(LichessImportPhase.scanning);
          if (control.cancelled) break outer;
        }
      }
      if (control.cancelled) break;
    }
    if (!control.cancelled) {
      for (final line in splitter.finish()) {
        linesRead++;
        if (linesRead <= linesToSkip) continue;
        final row = parseLichessEvalLine(line);
        if (row != null) {
          writer.add(row);
          rowsWritten++;
        }
      }
    }
    await checkpoint();
    if (control.cancelled) {
      report(LichessImportPhase.scanning);
      return;
    }
  } finally {
    await writer.close();
  }

  report(LichessImportPhase.merging);
  final records = await mergeBuckets(
    paths,
    onBucket: (index) {
      report(LichessImportPhase.merging, bucketsMerged: index + 1);
      return control.cancelled;
    },
  );
  if (control.cancelled) {
    report(LichessImportPhase.merging);
    return;
  }

  await writeManifest(
    paths,
    LichessEvalManifest(
      records: records,
      complete: true,
      sourceLastModified: request.sourceLastModified,
      sourceBytes: request.sourceBytes,
      builtAt: DateTime.now(),
      linesRead: linesRead,
    ),
  );
  await _clearBuckets(paths);
  request.sendPort.send(
    LichessImportProgress(
      phase: LichessImportPhase.done,
      linesRead: linesRead,
      rowsWritten: records,
      compressedBytesRead: compressedRead,
      bucketsMerged: kBucketCount,
    ),
  );
}

/// Sort every bucket and write `evals.bin` + `evals.idx`.  Returns the record
/// count actually written (duplicates collapse to their deepest eval).
///
/// [onBucket] is called after each bucket; returning true cancels.
Future<int> mergeBuckets(
  LichessEvalStorePaths paths, {
  bool Function(int index)? onBucket,
}) async {
  final data = File(paths.dataFile).openWrite();
  final index = File(paths.indexFile).openWrite();
  var written = 0;
  try {
    data.add(buildHeader());
    final sparse = BytesBuilder(copy: false);
    for (var bucket = 0; bucket < kBucketCount; bucket++) {
      final file = File(_bucketPath(paths.bucketDirectory, bucket));
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final sorted = sortBucket(bytes);
        for (var i = 0; i < sorted.lengthInBytes; i += kRecordBytes) {
          if ((written + i ~/ kRecordBytes) % kIndexStride == 0) {
            final key = ByteData.sublistView(
              sorted,
              i,
              i + 8,
            ).getInt64(0, Endian.little);
            final entry = ByteData(8)..setInt64(0, key, Endian.little);
            sparse.add(entry.buffer.asUint8List());
          }
        }
        data.add(sorted);
        written += sorted.lengthInBytes ~/ kRecordBytes;
      }
      if (onBucket != null && onBucket(bucket)) return written;
    }
    index.add(sparse.takeBytes());
  } finally {
    await data.flush();
    await data.close();
    await index.flush();
    await index.close();
  }

  return written;
}

/// Sort one bucket's raw records ascending by key, keeping the deepest eval
/// when a key appears more than once.
///
/// A comparison sort rather than a radix pass: a full bucket holds about 1.5
/// million records, so this is roughly 30 million comparisons per bucket and
/// a few minutes over all 256 — immaterial next to the hours the scan spends
/// decompressing and parsing 283 GB of JSON.
Uint8List sortBucket(Uint8List bytes) {
  final count = bytes.lengthInBytes ~/ kRecordBytes;
  if (count == 0) return Uint8List(0);
  final view = ByteData.sublistView(bytes);
  final keys = Int64List(count);
  final depths = Uint8List(count);
  for (var i = 0; i < count; i++) {
    keys[i] = view.getInt64(i * kRecordBytes, Endian.little);
    depths[i] = view.getUint8(i * kRecordBytes + 12);
  }
  final order = List<int>.generate(count, (i) => i, growable: false);
  order.sort((a, b) {
    final cmp = compareKeys(keys[a], keys[b]);
    if (cmp != 0) return cmp;
    return depths[b].compareTo(depths[a]);
  });

  final out = Uint8List(count * kRecordBytes);
  var written = 0;
  var previous = 0;
  var havePrevious = false;
  for (final i in order) {
    if (havePrevious && keys[i] == previous) continue; // shallower duplicate
    out.setRange(
      written * kRecordBytes,
      (written + 1) * kRecordBytes,
      bytes,
      i * kRecordBytes,
    );
    previous = keys[i];
    havePrevious = true;
    written++;
  }
  return Uint8List.sublistView(out, 0, written * kRecordBytes);
}

String _bucketPath(String directory, int bucket) =>
    '$directory${Platform.pathSeparator}'
    'b${bucket.toString().padLeft(3, '0')}.bin';

String _bucketLengthsPath(LichessEvalStorePaths paths) =>
    '${paths.bucketDirectory}${Platform.pathSeparator}lengths.bin';

Future<List<int>?> _readBucketLengths(LichessEvalStorePaths paths) async {
  final file = File(_bucketLengthsPath(paths));
  if (!await file.exists()) return null;
  final bytes = await file.readAsBytes();
  if (bytes.length != kBucketCount * 8) return null;
  final view = ByteData.sublistView(bytes);
  return [
    for (var i = 0; i < kBucketCount; i++) view.getInt64(i * 8, Endian.little),
  ];
}

Future<void> _writeBucketLengths(
  LichessEvalStorePaths paths,
  List<int> lengths,
) async {
  final buffer = ByteData(kBucketCount * 8);
  for (var i = 0; i < kBucketCount; i++) {
    buffer.setInt64(i * 8, lengths[i], Endian.little);
  }
  await File(
    _bucketLengthsPath(paths),
  ).writeAsBytes(buffer.buffer.asUint8List(), flush: true);
}

Future<void> _clearBuckets(LichessEvalStorePaths paths) async {
  final directory = Directory(paths.bucketDirectory);
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
}

/// Buffered append to the 256 bucket files.
///
/// One open handle and a 256 KB buffer each — 64 MB of buffering in exchange
/// for turning 394 million scattered writes into large sequential ones.
class _BucketWriter {
  _BucketWriter(this.directory);

  static const int _bufferBytes = 1 << 18;

  final String directory;
  final List<RandomAccessFile> _files = [];
  final List<Uint8List> _buffers = [];
  final List<int> _used = List<int>.filled(kBucketCount, 0);
  final List<int> lengths = List<int>.filled(kBucketCount, 0);

  Future<void> open(List<int> resumeLengths) async {
    for (var i = 0; i < kBucketCount; i++) {
      final file = File(_bucketPath(directory, i));
      final handle = await file.open(mode: FileMode.writeOnlyAppend);
      // Drop anything written after the last checkpoint: those records are
      // about to be produced again by the replayed lines.
      await handle.truncate(resumeLengths[i]);
      await handle.setPosition(resumeLengths[i]);
      lengths[i] = resumeLengths[i];
      _files.add(handle);
      _buffers.add(Uint8List(_bufferBytes));
    }
  }

  void add(LichessEvalRow row) {
    final bucket = bucketOf(row.pos);
    final buffer = _buffers[bucket];
    if (_used[bucket] + kRecordBytes > buffer.lengthInBytes) {
      _spill(bucket);
    }
    encodeRecord(
      ByteData.sublistView(buffer, _used[bucket], _used[bucket] + kRecordBytes),
      0,
      row,
    );
    _used[bucket] += kRecordBytes;
    lengths[bucket] += kRecordBytes;
  }

  void _spill(int bucket) {
    final used = _used[bucket];
    if (used == 0) return;
    _files[bucket].writeFromSync(_buffers[bucket], 0, used);
    _used[bucket] = 0;
  }

  Future<void> flush() async {
    for (var i = 0; i < kBucketCount; i++) {
      _spill(i);
      await _files[i].flush();
    }
  }

  Future<void> close() async {
    for (var i = 0; i < _files.length; i++) {
      _spill(i);
      await _files[i].close();
    }
    _files.clear();
    _buffers.clear();
  }
}

/// Splits a byte stream into lines without decoding the whole thing first.
///
/// The file is ASCII — FENs, UCI moves and numbers — so [String.fromCharCodes]
/// is both correct and cheaper than a UTF-8 decode.
class _LineSplitter {
  final BytesBuilder _pending = BytesBuilder(copy: true);

  Iterable<String> add(List<int> chunk) sync* {
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 0x0a) continue;
      if (_pending.isEmpty) {
        yield String.fromCharCodes(chunk, start, i);
      } else {
        _pending.add(chunk.sublist(start, i));
        yield String.fromCharCodes(_pending.takeBytes());
      }
      start = i + 1;
    }
    if (start < chunk.length) _pending.add(chunk.sublist(start));
  }

  Iterable<String> finish() sync* {
    if (_pending.isNotEmpty) yield String.fromCharCodes(_pending.takeBytes());
  }
}
