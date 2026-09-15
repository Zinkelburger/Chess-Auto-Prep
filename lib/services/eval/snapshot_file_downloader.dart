/// Resumable transfer of one snapshot file.
///
/// Every file is fetched with an HTTP range request: a partial file resumes
/// from its own length, a file the manifest says is complete is left alone,
/// and a file longer than the manifest is fetched again from zero. Transient
/// failures are retried with a growing pause; a stop request between or
/// during attempts ends the transfer with whatever is on disk.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../storage/file_mutation_service.dart';
import 'cdb_snapshot_catalog.dart';
import 'storage_volumes.dart';

/// How much downloaded data may sit in the sink's buffer before the read loop
/// waits for the disk to catch up.
///
/// [IOSink.add] neither blocks nor reports a full buffer, so a loop that only
/// calls `add` never applies backpressure: on a network faster than the disk
/// the whole transfer accumulates in memory.  A multi-GB dump fetched by
/// several workers at once is how that becomes an OOM rather than a slow
/// download.  Awaiting a flush suspends the enclosing `await for`, which
/// pauses the HTTP subscription — so this constant is the real cap on how
/// much of the file is resident, per worker.
const int _sinkBufferBytes = 8 * 1024 * 1024;

/// Whether the transfer ended because the file is complete or because the
/// caller asked it to stop.
enum SnapshotFileOutcome { complete, stopped }

/// Opens the sink a file's bytes stream into, appending when [append].
///
/// Supplied by the owner of the download rather than opened here: the
/// streamed write of a resumable snapshot file is the one durable write in
/// the transfer, and the file-mutation policy keeps it in the reviewed
/// controller.
typedef SnapshotSinkOpener =
    IOSink Function(File target, {required bool append});

class SnapshotFileDownloader {
  SnapshotFileDownloader({
    required this._http,
    required this._urlFor,
    required this._openSink,
    this.maxAttempts = 5,
    this.headroomBytes = 0,
  });

  final HttpClient _http;

  /// Where a manifest path is fetched from. Injectable so the resume logic
  /// can be exercised against a local server.
  final Uri Function(String repoPath) _urlFor;

  final SnapshotSinkOpener _openSink;

  /// Attempts before a failing file is given up on.
  final int maxAttempts;

  /// Free space that must remain on the volume after the file is fetched.
  final int headroomBytes;

  /// Fetch [file] into `<parentDir>/<file.path>`, resuming a partial copy.
  ///
  /// [onBytes] reports every change to the bytes on disk, including the
  /// negative correction when a partial file has to be discarded. [shouldStop]
  /// is polled between chunks and attempts. Throws after [maxAttempts]
  /// failures, with the partial file kept for the next run.
  Future<SnapshotFileOutcome> fetch(
    CdbSnapshotFile file,
    String parentDir, {
    required bool Function() shouldStop,
    required void Function(int delta) onBytes,
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (shouldStop()) return SnapshotFileOutcome.stopped;
      try {
        return await _fetchOnce(
          file,
          parentDir,
          shouldStop: shouldStop,
          onBytes: onBytes,
        );
      } catch (e) {
        if (attempt == maxAttempts) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
    // Unreachable: the loop returns or rethrows on its last attempt.
    return SnapshotFileOutcome.stopped;
  }

  Future<SnapshotFileOutcome> _fetchOnce(
    CdbSnapshotFile file,
    String parentDir, {
    required bool Function() shouldStop,
    required void Function(int delta) onBytes,
  }) async {
    final target = File(p.join(parentDir, file.path));
    await target.parent.create(recursive: true);

    var offset = await target.exists() ? await target.length() : 0;
    if (offset > file.bytes) {
      await _discard(target, parentDir);
      offset = 0;
    }
    if (offset == file.bytes) return SnapshotFileOutcome.complete;

    await _requireFreeSpace(target.parent.path, file, file.bytes - offset);

    final response = await _open(file, offset);
    if (offset > 0 && response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      if (response.statusCode == HttpStatus.ok ||
          response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        // The mirror ignored the range, or says our offset is past the end:
        // start the file over rather than appending a second copy of its
        // head.
        await _discard(target, parentDir);
        onBytes(-offset);
        throw StateError('Range request refused (${response.statusCode})');
      }
      // Anything else (a 5xx, a 429) says nothing about the range; retry it
      // with the partial file intact rather than throwing gigabytes away.
      throw HttpException('HTTP ${response.statusCode} for ${file.name}');
    }
    if (offset == 0 && response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode} for ${file.name}');
    }

    final stopped = await _writeBody(
      response,
      target,
      append: offset > 0,
      shouldStop: shouldStop,
      onBytes: onBytes,
    );
    if (stopped) return SnapshotFileOutcome.stopped;

    final written = await target.length();
    if (written != file.bytes) {
      throw StateError(
        'Short read: got ${formatBytes(written)} of ${formatBytes(file.bytes)}',
      );
    }
    return SnapshotFileOutcome.complete;
  }

  /// Removes a partial copy that cannot be resumed. Snapshot files are
  /// re-downloadable, so this is a disposable delete scoped to the download
  /// folder.
  Future<void> _discard(File target, String parentDir) => FileMutationService
      .instance
      .deleteDisposableFile(target, allowedRoot: Directory(parentDir));

  Future<void> _requireFreeSpace(
    String directory,
    CdbSnapshotFile file,
    int needed,
  ) async {
    final free = await freeBytesForPath(directory);
    if (free != null && free < needed + headroomBytes) {
      throw StateError(
        'Only ${formatBytes(free)} free — not enough for ${file.name} '
        '(${formatBytes(needed)} left to fetch).',
      );
    }
  }

  Future<HttpClientResponse> _open(CdbSnapshotFile file, int offset) async {
    final request = await _http.getUrl(_urlFor(file.path));
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    return request.close();
  }

  /// Streams [response] into [target]; true when [shouldStop] cut it short.
  Future<bool> _writeBody(
    HttpClientResponse response,
    File target, {
    required bool append,
    required bool Function() shouldStop,
    required void Function(int delta) onBytes,
  }) async {
    final sink = _openSink(target, append: append);
    var stopped = false;
    try {
      var buffered = 0;
      await for (final chunk in response) {
        if (shouldStop()) {
          stopped = true;
          break;
        }
        sink.add(chunk);
        onBytes(chunk.length);
        buffered += chunk.length;
        if (buffered >= _sinkBufferBytes) {
          // Suspends this loop, which pauses the response subscription until
          // the bytes are on disk.  Without it the sink queues without bound.
          await sink.flush();
          buffered = 0;
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return stopped;
  }
}
