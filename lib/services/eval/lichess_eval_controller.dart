/// Getting the Lichess cloud evaluations onto the machine and into the store.
///
/// Two stages behind one progress bar, because the user asked for one thing:
///
///   1. **Download** `lichess_db_eval.jsonl.zst` — 21.7 GB, resumed with a
///      range request so a stopped transfer costs nothing.
///   2. **Import** it into the sorted store (`lichess_eval_import.dart`) in a
///      background isolate, which is where the 283 GB of expanded JSON is
///      read and thrown away.
///
/// Only the second stage leaves anything behind: about 5.9 GB of `evals.bin`.
/// The archive is deletable afterwards and the panel offers that, because
/// keeping it is only worth it to someone who expects to rebuild.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/eval_database_settings.dart';
import '../../utils/safe_change_notifier.dart';
import '../../utils/time_format.dart';
import '../jobs/repertoire_job.dart';
import 'eval_database_job.dart';
import 'lichess_eval_import.dart';
import 'lichess_eval_source.dart';
import 'lichess_eval_store.dart';
import 'storage_volumes.dart';
import 'transfer_rate_meter.dart';
import 'zstd_stream.dart';

enum LichessEvalPhase {
  idle,
  probing,
  downloading,
  paused,
  importing,
  complete,
  failed,
}

/// Free space kept in hand rather than filling the disk to the last byte.
const int kLichessHeadroomBytes = 2 * 1000 * 1000 * 1000;

/// Share of the progress bar the download takes; the import is the rest.
/// Guessing is better than a bar that jumps back to zero.
const double _downloadShare = 0.6;

/// Share of the progress bar the import's scan takes; the merge is the rest.
const double _scanShare = 0.3;

/// The import is given up as stalled after this long without finishing.
const Duration _importTimeout = Duration(days: 2);

class LichessEvalController extends ChangeNotifier with SafeChangeNotifier {
  LichessEvalController({
    LichessEvalSource? source,
    Uri Function()? urlBuilder,
    this._spawnIsolate = true,
  }) : _source = source ?? LichessEvalSource(),
       _urlBuilder = urlBuilder ?? (() => Uri.parse(kLichessEvalUrl));

  static final LichessEvalController instance = LichessEvalController();

  static const _keyDirectory = 'eval.lichess.download_dir';

  /// Folder name created inside the directory the user picks.
  static const String folderName = 'lichess-evals';

  static const String _archiveName = 'lichess_db_eval.jsonl.zst';

  final LichessEvalSource _source;
  final Uri Function() _urlBuilder;
  final bool _spawnIsolate;
  final HttpClient _http = HttpClient()..idleTimeout = const Duration(hours: 1);
  final TransferRateMeter _rate = TransferRateMeter();

  LichessEvalPhase _phase = LichessEvalPhase.idle;
  LichessEvalSourceInfo? _info;
  String? _parentDir;
  String? _error;

  int _archiveDone = 0;
  int _archiveTotal = 0;
  Timer? _ticker;

  int _linesRead = 0;
  int _rowsWritten = 0;
  int _bucketsMerged = 0;

  LichessEvalManifest? _manifest;
  bool _stopRequested = false;
  Isolate? _isolate;
  SendPort? _isolateControl;
  RepertoireJob? _job;

  LichessEvalPhase get phase => _phase;
  LichessEvalSourceInfo? get info => _info;
  String? get parentDirectory => _parentDir;
  String? get error => _error;

  /// The built store's own account of itself, when there is one.
  LichessEvalManifest? get manifest => _manifest;

  int get archiveBytesDone => _archiveDone;
  int get archiveBytesTotal => _archiveTotal;
  double get bytesPerSecond => _rate.bytesPerSecond;
  int get linesRead => _linesRead;
  int get rowsWritten => _rowsWritten;
  int get bucketsMerged => _bucketsMerged;

  bool get isBusy =>
      _phase == LichessEvalPhase.downloading ||
      _phase == LichessEvalPhase.importing ||
      _phase == LichessEvalPhase.probing;

  /// True once a finished store is on disk.
  bool get isReady => _manifest?.complete == true;

  /// Positions in the built store.
  int get storedPositions => _manifest?.records ?? 0;

  /// Where everything lives, once a directory is chosen.
  String? get storeDirectory {
    final parent = _parentDir;
    return parent == null ? null : p.join(parent, folderName);
  }

  String? get archivePath {
    final directory = storeDirectory;
    return directory == null ? null : p.join(directory, _archiveName);
  }

  LichessEvalStorePaths? get storePaths {
    final directory = storeDirectory;
    return directory == null ? null : LichessEvalStorePaths(directory);
  }

  /// Peak disk the whole operation needs: the archive plus the store, which
  /// coexist while the buckets are merged.
  int peakBytesFor(LichessEvalSourceInfo info) =>
      info.bytes + info.storeBytes + kLichessHeadroomBytes;

  /// What stays behind once the archive is deleted.
  int restingBytesFor(LichessEvalSourceInfo info) => info.storeBytes;

  double get fraction {
    switch (_phase) {
      case LichessEvalPhase.downloading:
      case LichessEvalPhase.paused:
        if (_archiveTotal <= 0) return 0;
        return (_archiveDone / _archiveTotal) * _downloadShare;
      case LichessEvalPhase.importing:
        final total = _info?.positions ?? 0;
        final scanned = total == 0 ? 0.0 : (_linesRead / total).clamp(0.0, 1.0);
        final merged = _bucketsMerged / kBucketCount;
        return _downloadShare +
            scanned * _scanShare +
            merged * (1 - _downloadShare - _scanShare);
      case LichessEvalPhase.complete:
        return 1;
      case LichessEvalPhase.idle:
      case LichessEvalPhase.probing:
      case LichessEvalPhase.failed:
        return 0;
    }
  }

  Duration? get eta => _phase == LichessEvalPhase.downloading
      ? _rate.eta(_archiveTotal - _archiveDone)
      : null;

  /// Re-attach to whatever is already on disk.  Never starts a transfer.
  Future<void> loadSaved() async {
    // A second panel mounting mid-transfer must not re-read the half-built
    // manifest off disk: refreshStoreState would report an incomplete store
    // as `paused` while the import is still running.
    if (isBusy) return;
    final prefs = await SharedPreferences.getInstance();
    _parentDir = prefs.getString(_keyDirectory);
    if (_parentDir == null) {
      final saved = EvalDatabaseSettings.instance.lichessEvalsPath;
      if (saved.isNotEmpty) _parentDir = p.dirname(saved);
    }
    await refreshStoreState();
  }

  /// Re-read the manifest and the partially downloaded archive.
  Future<void> refreshStoreState() async {
    final paths = storePaths;
    final archive = archivePath;
    if (paths == null || archive == null) {
      _manifest = null;
      notifyListeners();
      return;
    }
    final manifest = _manifest = await readManifest(paths);
    _archiveDone = await _lengthOf(File(archive));
    if (manifest != null && manifest.complete) {
      _phase = LichessEvalPhase.complete;
      _rowsWritten = manifest.records;
    } else if (_archiveDone > 0 || (manifest?.linesRead ?? 0) > 0) {
      _phase = LichessEvalPhase.paused;
      _linesRead = manifest?.linesRead ?? 0;
    }
    notifyListeners();
  }

  /// Ask Lichess how big the file is today.
  Future<LichessEvalSourceInfo> refreshSource() async {
    _phase = LichessEvalPhase.probing;
    // The download dialog starts this from its `initState`, so everything up
    // to the first await runs inside the build phase. See
    // [SafeChangeNotifier.notifyListenersOutsideBuild].
    notifyListenersOutsideBuild();
    final info = _info = await _source.probe();
    _archiveTotal = info.bytes;
    _phase = isReady
        ? LichessEvalPhase.complete
        : (_archiveDone > 0 ? LichessEvalPhase.paused : LichessEvalPhase.idle);
    notifyListeners();
    return info;
  }

  /// Point the controller at [parentDir] and remember it.
  Future<void> prepare({
    required LichessEvalSourceInfo info,
    required String parentDir,
  }) async {
    _info = info;
    _parentDir = parentDir;
    _archiveTotal = info.bytes;
    _error = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDirectory, parentDir);
    await Directory(p.join(parentDir, folderName)).create(recursive: true);
    await refreshStoreState();
  }

  /// Download what is missing, then import.  Safe to call again after a pause.
  Future<void> start() async {
    if (isBusy) return;
    final info = _info;
    final directory = storeDirectory;
    final archive = archivePath;
    if (info == null || directory == null || archive == null) {
      _fail('Choose where the database should live first.');
      return;
    }

    final backend = await probeZstdBackend();
    if (backend == ZstdBackend.none) {
      _fail(zstdMissingMessage);
      return;
    }

    _stopRequested = false;
    _error = null;
    _job = ensureEvalDatabaseJob(
      _job,
      label: 'Lichess evaluations',
      onCancel: () => unawaited(pause()),
    );

    try {
      if (!isReady) {
        await _download(info, File(archive));
        if (_stopRequested) {
          _setPaused();
          return;
        }
        await _runImport(
          archivePath: archive,
          storeDirectory: directory,
          info: info,
          backend: backend,
        );
        if (_stopRequested) {
          _setPaused();
          return;
        }
      }
      await refreshStoreState();
      if (isReady) await _completeJob(directory);
    } catch (e) {
      _fail('$e');
    } finally {
      _stopTicker();
      notifyListeners();
    }
  }

  Future<void> _completeJob(String directory) async {
    await EvalDatabaseSettings.instance.setLichessEvalsPath(directory);
    await EvalDatabaseSettings.instance.setEnableLichessEvals(true);
    _phase = LichessEvalPhase.complete;
    _job?.updateProgress(
      JobProgress(
        fraction: 1,
        message: '${_formatCount(storedPositions)} positions ready',
      ),
    );
    _job?.updateStatus(JobStatus.completed);
    _job = null;
  }

  /// Stop after the current chunk or checkpoint; everything already written
  /// stays, so [start] resumes from there.
  Future<void> pause() async {
    if (!isBusy) return;
    _stopRequested = true;
    _isolateControl?.send(kLichessImportCancelMessage);
    notifyListeners();
  }

  /// Remove the 21.7 GB download, keeping the built store.
  Future<void> deleteArchive() async {
    final path = archivePath;
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
    _archiveDone = 0;
    notifyListeners();
  }

  /// Remove everything: archive, buckets and store.
  Future<void> deleteEverything() async {
    if (isBusy) await pause();
    final directory = storeDirectory;
    if (directory != null) {
      final dir = Directory(directory);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    _manifest = null;
    _archiveDone = 0;
    _linesRead = 0;
    _rowsWritten = 0;
    _bucketsMerged = 0;
    _phase = LichessEvalPhase.idle;
    if (EvalDatabaseSettings.instance.lichessEvalsPath == directory) {
      await EvalDatabaseSettings.instance.setEnableLichessEvals(false);
      await EvalDatabaseSettings.instance.setLichessEvalsPath('');
    }
    notifyListeners();
  }

  // ── Download ───────────────────────────────────────────────────────────

  static Future<int> _lengthOf(File file) async =>
      await file.exists() ? file.length() : 0;

  Future<void> _download(LichessEvalSourceInfo info, File target) async {
    await target.parent.create(recursive: true);
    var existing = await _lengthOf(target);
    if (existing > info.bytes) {
      // A stale, longer file cannot be a prefix of this one.
      await target.delete();
      existing = 0;
    }
    if (existing == info.bytes) {
      _archiveDone = existing;
      return;
    }

    final free = await freeBytesForPath(target.parent.path);
    if (free != null &&
        free < (info.bytes - existing) + kLichessHeadroomBytes) {
      throw StateError(
        'Not enough room on that drive: ${formatBytes(free)} free, '
        '${formatBytes(info.bytes - existing)} still to download.',
      );
    }

    _phase = LichessEvalPhase.downloading;
    _archiveDone = existing;
    _archiveTotal = info.bytes;
    _startTicker();
    notifyListeners();

    final request = await _http.getUrl(_urlBuilder());
    if (existing > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
    }
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw StateError('Lichess answered ${response.statusCode}');
    }
    // A server that ignores the range restarts the file; anything else would
    // splice the beginning of the download onto the middle of the old one.
    final resumed = response.statusCode == HttpStatus.partialContent;
    final sink = target.openWrite(
      mode: resumed ? FileMode.append : FileMode.write,
    );
    if (!resumed) _archiveDone = 0;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        _archiveDone += chunk.length;
        if (_stopRequested) break;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (_stopRequested) return;

    final written = await target.length();
    if (written != info.bytes) {
      throw StateError(
        'Short download: ${formatBytes(written)} of ${formatBytes(info.bytes)}',
      );
    }
  }

  // ── Import ─────────────────────────────────────────────────────────────

  Future<void> _runImport({
    required String archivePath,
    required String storeDirectory,
    required LichessEvalSourceInfo info,
    required ZstdBackend backend,
  }) async {
    _phase = LichessEvalPhase.importing;
    _bucketsMerged = 0;
    notifyListeners();

    final receive = ReceivePort();
    final finished = Completer<void>();
    // The completer is also completed from `onExit`/`onError` below, which can
    // land before the `await` further down attaches. A second, swallowing
    // listener keeps that from surfacing as an unhandled async error; the real
    // await still receives it.
    unawaited(finished.future.catchError((_) {}));
    receive.listen((message) => _onImportMessage(message, finished));

    final request = LichessImportRequest(
      archivePath: archivePath,
      storeDirectory: storeDirectory,
      sendPort: receive.sendPort,
      sourceLastModified: info.lastModified,
      sourceBytes: info.bytes,
      backend: backend,
    );

    try {
      if (_spawnIsolate) {
        _isolate = await Isolate.spawn(
          runLichessImportIsolate,
          request,
          onExit: receive.sendPort,
          onError: receive.sendPort,
        );
        await finished.future.timeout(
          _importTimeout,
          onTimeout: () => throw StateError('the import stalled'),
        );
      } else {
        // Tests drive the import in-process so they can watch it finish.
        await runLichessImportIsolate(request);
      }
    } finally {
      receive.close();
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _isolateControl = null;
    }
  }

  /// One message on the import port.
  ///
  /// The port is also the isolate's `onExit` and `onError` port, so besides
  /// [LichessImportProgress] reports it carries the isolate's control port,
  /// a `null` on exit and an `[error, stackTrace]` pair on an uncaught error.
  /// Dropping the last two would leave an isolate that died without a report
  /// showing "importing" until [_importTimeout].
  void _onImportMessage(Object? message, Completer<void> finished) {
    switch (message) {
      case SendPort():
        _isolateControl = message;
        if (_stopRequested) message.send(kLichessImportCancelMessage);
      case null:
        // onExit. Harmless after a `done`/`failed` report; the only signal
        // there is when the isolate died without sending one.  A cancelled
        // import also exits without one, on purpose — that is a pause.
        if (finished.isCompleted) return;
        if (_stopRequested) {
          finished.complete();
        } else {
          finished.completeError(
            StateError('the import isolate stopped before it finished'),
          );
        }
      case List():
        // onError sends [error, stackTrace], both already stringified.
        if (finished.isCompleted) return;
        final error = message.isNotEmpty ? message.first : 'unknown error';
        finished.completeError(StateError('import failed: $error'));
      case LichessImportProgress():
        _applyImportProgress(message, finished);
      default:
        break;
    }
  }

  void _applyImportProgress(
    LichessImportProgress progress,
    Completer<void> finished,
  ) {
    _linesRead = progress.linesRead;
    _rowsWritten = progress.rowsWritten;
    _bucketsMerged = progress.bucketsMerged;
    switch (progress.phase) {
      case LichessImportPhase.failed:
        if (!finished.isCompleted) {
          finished.completeError(StateError(progress.error ?? 'import failed'));
        }
      case LichessImportPhase.done:
        if (!finished.isCompleted) finished.complete();
      case LichessImportPhase.scanning:
      case LichessImportPhase.merging:
        break;
    }
    _job?.updateProgress(
      JobProgress(fraction: fraction, message: _importMessage(progress)),
    );
    notifyListeners();
  }

  String _importMessage(LichessImportProgress progress) =>
      switch (progress.phase) {
        LichessImportPhase.scanning =>
          'Reading evaluations — ${_formatCount(progress.linesRead)} positions',
        LichessImportPhase.merging =>
          'Sorting — ${progress.bucketsMerged} of $kBucketCount blocks',
        LichessImportPhase.done =>
          '${_formatCount(progress.rowsWritten)} positions ready',
        LichessImportPhase.failed => progress.error ?? 'failed',
      };

  static String _formatCount(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).round()}k';
    return '$value';
  }

  // ── Bookkeeping ────────────────────────────────────────────────────────

  void _setPaused() {
    _phase = LichessEvalPhase.paused;
    _job?.updateStatus(JobStatus.cancelled);
    _job = null;
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _phase = LichessEvalPhase.failed;
    _job?.fail(message);
    _job = null;
    notifyListeners();
  }

  void _startTicker() {
    _rate.reset(_archiveDone);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _rate.sample(_archiveDone);
      final eta = this.eta;
      _job?.updateProgress(
        JobProgress(
          fraction: fraction,
          message:
              '${formatBytes(_archiveDone)} of ${formatBytes(_archiveTotal)}'
              '${eta == null ? '' : ' — ${formatCoarseDuration(eta)} left'}',
        ),
      );
      notifyListeners();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    _rate.reset(_archiveDone);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _http.close(force: true);
    _source.dispose();
    super.dispose();
  }
}
