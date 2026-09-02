/// In-app download of the ChessDB full dump.
///
/// The snapshot is ~1.2 TB across a few hundred files, so the transfer is
/// built to be interrupted: every file is fetched with an HTTP range request,
/// a partial file resumes from its own length, and finished files are never
/// re-fetched. Stopping and starting again — including across app restarts —
/// carries on where it left off.
///
/// The controller owns no UI. It publishes progress, registers a resumable
/// [RepertoireJob] so the transfer shows up in the Jobs pane like any other
/// long task, and points [EvalDatabaseSettings] at the data directory once the
/// download completes.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/eval_database_settings.dart';
import '../../utils/safe_change_notifier.dart';
import '../jobs/repertoire_job.dart';
import 'cdb_snapshot_catalog.dart';
import 'storage_volumes.dart';

enum CdbDownloadPhase {
  /// Nothing started, or the last attempt was cleared.
  idle,

  /// Reading the manifest and measuring what is already on disk.
  preparing,
  downloading,
  paused,

  /// Re-checking file lengths against the manifest.
  checking,
  complete,
  failed,
}

/// A file the local copy disagrees with the manifest about.
class CdbFileProblem {
  const CdbFileProblem({
    required this.name,
    required this.expectedBytes,
    required this.actualBytes,
  });

  final String name;
  final int expectedBytes;

  /// -1 when the file is missing entirely.
  final int actualBytes;

  bool get isMissing => actualBytes < 0;
}

/// Headroom left free on the target volume; below this the download parks
/// itself rather than filling the disk to the last byte.
const int kCdbDownloadHeadroomBytes = 2 * 1000 * 1000 * 1000;

/// Extra space the setup dialog asks for on top of the snapshot, so a full
/// download does not leave the volume with nothing to work in.
const int kCdbRecommendedHeadroomBytes = 20 * 1000 * 1000 * 1000;

class CdbSnapshotDownloadController extends ChangeNotifier
    with SafeChangeNotifier {
  CdbSnapshotDownloadController({
    CdbSnapshotCatalog? catalog,
    this.concurrency = 4,
    Uri Function(String repoPath)? urlBuilder,
  }) : _catalog = catalog ?? CdbSnapshotCatalog(),
       _urlFor = urlBuilder ?? chessDbFileUrl;

  static final CdbSnapshotDownloadController instance =
      CdbSnapshotDownloadController();

  static const _keyParentDir = 'eval.cdb_download.parent_dir';
  static const _keySnapshotId = 'eval.cdb_download.snapshot_id';

  /// Parallel file transfers. Four saturates a home connection without
  /// turning the disk write pattern into a seek storm.
  final int concurrency;

  final CdbSnapshotCatalog _catalog;

  /// Where a manifest path is fetched from. Injectable so the resume logic
  /// can be exercised against a local server.
  final Uri Function(String repoPath) _urlFor;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 30);

  CdbDownloadPhase _phase = CdbDownloadPhase.idle;
  CdbSnapshot? _snapshot;
  String? _parentDir;
  String? _error;

  int _bytesDone = 0;
  int _bytesTotal = 0;
  int _filesDone = 0;
  double _bytesPerSecond = 0;
  int _lastSampleBytes = 0;

  final Set<String> _activeFiles = <String>{};
  List<CdbFileProblem> _problems = const [];

  bool _stopRequested = false;
  Future<void>? _runInFlight;
  Timer? _ticker;
  RepertoireJob? _job;

  // ── State ────────────────────────────────────────────────────────────────

  CdbDownloadPhase get phase => _phase;
  CdbSnapshot? get snapshot => _snapshot;

  /// Folder the user picked; the snapshot lives in `<parentDir>/<id>/`.
  String? get parentDir => _parentDir;
  String? get error => _error;

  int get bytesDone => _bytesDone;
  int get bytesTotal => _bytesTotal;
  int get filesDone => _filesDone;
  int get filesTotal => _snapshot?.files.length ?? 0;
  double get bytesPerSecond => _bytesPerSecond;
  List<CdbFileProblem> get problems => _problems;

  bool get isRunning =>
      _phase == CdbDownloadPhase.downloading ||
      _phase == CdbDownloadPhase.preparing ||
      _phase == CdbDownloadPhase.checking;

  bool get canResume =>
      _snapshot != null &&
      _parentDir != null &&
      (_phase == CdbDownloadPhase.paused || _phase == CdbDownloadPhase.failed);

  double get fraction =>
      _bytesTotal <= 0 ? 0 : (_bytesDone / _bytesTotal).clamp(0.0, 1.0);

  int get bytesRemaining => (_bytesTotal - _bytesDone).clamp(0, _bytesTotal);

  /// Time left at the current rate, or null before a rate is known.
  Duration? get eta {
    if (_bytesPerSecond <= 0 || bytesRemaining <= 0) return null;
    final seconds = bytesRemaining / _bytesPerSecond;
    if (seconds.isInfinite || seconds.isNaN || seconds > 60 * 60 * 24 * 90) {
      return null;
    }
    return Duration(seconds: seconds.round());
  }

  /// Files being transferred right now, for the progress line.
  List<String> get activeFiles => _activeFiles.toList()..sort();

  /// Directory to hand the reader once the download finishes.
  String? get dataDirectory {
    final parent = _parentDir;
    final snap = _snapshot;
    if (parent == null || snap == null) return null;
    return p.join(parent, snap.id, 'data');
  }

  // ── Setup ────────────────────────────────────────────────────────────────

  /// Re-attach to a download parked by an earlier run of the app.
  ///
  /// Only reads what is on disk — it never starts a transfer, so launching
  /// the app on a metered connection does not silently resume 1.2 TB.
  Future<void> loadSaved() async {
    if (_snapshot != null || isRunning) return;
    final prefs = await SharedPreferences.getInstance();
    final parent = prefs.getString(_keyParentDir);
    final id = prefs.getString(_keySnapshotId);
    if (parent == null || parent.isEmpty || id == null || id.isEmpty) return;
    if (!await Directory(p.join(parent, id)).exists()) return;

    try {
      final snap = await _catalog.fetchSnapshot(id);
      _snapshot = snap;
      _parentDir = parent;
      _bytesTotal = snap.totalBytes;
      await _measureLocal();
      _phase = _bytesDone >= _bytesTotal
          ? CdbDownloadPhase.complete
          : CdbDownloadPhase.paused;
      notifyListeners();
    } on CdbCatalogException {
      // Offline at launch: leave the panel showing the plain settings.
    }
  }

  /// Prepare a download of [snapshot] into [parentDir] without starting it.
  Future<void> prepare({
    required CdbSnapshot snapshot,
    required String parentDir,
  }) async {
    if (isRunning) return;
    _snapshot = snapshot;
    _parentDir = parentDir;
    _bytesTotal = snapshot.totalBytes;
    _error = null;
    _problems = const [];
    _phase = CdbDownloadPhase.preparing;
    notifyListeners();

    await _measureLocal();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyParentDir, parentDir);
    await prefs.setString(_keySnapshotId, snapshot.id);

    _phase = _bytesDone >= _bytesTotal
        ? CdbDownloadPhase.complete
        : CdbDownloadPhase.paused;
    notifyListeners();
  }

  // ── Transfer ─────────────────────────────────────────────────────────────

  /// Start, or carry on from where a previous attempt stopped.
  Future<void> start() async {
    if (isRunning) return _runInFlight;
    final snap = _snapshot;
    final parent = _parentDir;
    if (snap == null || parent == null) return;

    _stopRequested = false;
    _error = null;
    _phase = CdbDownloadPhase.downloading;
    _ensureJob();
    _startTicker();
    notifyListeners();

    _runInFlight = _run(snap, parent);
    return _runInFlight;
  }

  /// Park the transfer. Everything already fetched stays on disk.
  Future<void> pause() async {
    if (!isRunning) return;
    _stopRequested = true;
    await _runInFlight;
  }

  /// Forget the download without touching the files.
  Future<void> forget() async {
    await pause();
    _snapshot = null;
    _parentDir = null;
    _bytesDone = 0;
    _bytesTotal = 0;
    _filesDone = 0;
    _problems = const [];
    _phase = CdbDownloadPhase.idle;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyParentDir);
    await prefs.remove(_keySnapshotId);
    notifyListeners();
  }

  /// Delete every file fetched so far, then forget the download.
  Future<void> deleteFiles() async {
    await pause();
    final parent = _parentDir;
    final snap = _snapshot;
    if (parent != null && snap != null) {
      final dir = Directory(p.join(parent, snap.id));
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    await forget();
  }

  /// Compare local file lengths with the manifest and report the mismatches.
  Future<List<CdbFileProblem>> check() async {
    final snap = _snapshot;
    final parent = _parentDir;
    if (snap == null || parent == null) return const [];
    if (isRunning) return _problems;

    final previous = _phase;
    _phase = CdbDownloadPhase.checking;
    notifyListeners();

    final found = <CdbFileProblem>[];
    for (final file in snap.files) {
      final local = File(p.join(parent, file.path));
      final length = await local.exists() ? await local.length() : -1;
      if (length != file.bytes) {
        found.add(
          CdbFileProblem(
            name: file.name,
            expectedBytes: file.bytes,
            actualBytes: length,
          ),
        );
      }
    }

    _problems = found;
    await _measureLocal();
    _phase = found.isEmpty
        ? CdbDownloadPhase.complete
        : (previous == CdbDownloadPhase.complete
              ? CdbDownloadPhase.paused
              : previous);
    notifyListeners();
    return found;
  }

  // ── Internals ────────────────────────────────────────────────────────────

  Future<void> _measureLocal() async {
    final snap = _snapshot;
    final parent = _parentDir;
    if (snap == null || parent == null) return;
    var done = 0;
    var complete = 0;
    for (final file in snap.files) {
      final local = File(p.join(parent, file.path));
      if (!await local.exists()) continue;
      final length = await local.length();
      // A file longer than the manifest says is corrupt, not ahead: count
      // nothing for it so the transfer redoes it from zero.
      if (length > file.bytes) continue;
      done += length;
      if (length == file.bytes) complete++;
    }
    _bytesDone = done;
    _filesDone = complete;
    _lastSampleBytes = done;
  }

  Future<void> _run(CdbSnapshot snap, String parent) async {
    try {
      await Directory(p.join(parent, snap.id, 'data')).create(recursive: true);
      await _measureLocal();
      notifyListeners();

      final queue = Queue<CdbSnapshotFile>();
      for (final file in snap.files) {
        final local = File(p.join(parent, file.path));
        final length = await local.exists() ? await local.length() : 0;
        if (length == file.bytes) continue;
        queue.add(file);
      }

      if (queue.isEmpty) {
        await _finish(snap, parent);
        return;
      }

      final remaining = _pendingBytes(queue);
      final space = await freeBytesForPath(p.join(parent, snap.id));
      if (space != null && space < remaining + kCdbDownloadHeadroomBytes) {
        // Stop before filling the volume: a disk with no room left takes the
        // rest of the desktop down with it.
        throw StateError(
          '${formatBytes(space)} free where ${formatBytes(remaining)} is still '
          'to download. Free up space, or point the download at another drive.',
        );
      }

      await Future.wait([
        for (var i = 0; i < concurrency; i++) _worker(queue, parent),
      ]);

      if (_error != null) {
        _phase = CdbDownloadPhase.failed;
        _job?.fail(_error!);
      } else if (_stopRequested) {
        _phase = CdbDownloadPhase.paused;
        _job?.updateStatus(JobStatus.paused);
      } else {
        await _finish(snap, parent);
      }
    } catch (e) {
      _error = '$e';
      _phase = CdbDownloadPhase.failed;
      _job?.fail('$e');
    } finally {
      _stopTicker();
      _activeFiles.clear();
      _runInFlight = null;
      notifyListeners();
    }
  }

  int _pendingBytes(Queue<CdbSnapshotFile> queue) {
    var sum = 0;
    for (final f in queue) {
      sum += f.bytes;
    }
    return sum;
  }

  Future<void> _finish(CdbSnapshot snap, String parent) async {
    _phase = CdbDownloadPhase.complete;
    _bytesDone = _bytesTotal;
    _filesDone = snap.files.length;
    _job?.updateProgress(
      JobProgress(fraction: 1, message: 'Downloaded ${snap.id}'),
    );
    _job?.updateStatus(JobStatus.completed);

    final dataDir = p.join(parent, snap.id, 'data');
    await EvalDatabaseSettings.instance.setCdbDirectPath(dataDir);
    await EvalDatabaseSettings.instance.setEnableCdbDirect(true);
  }

  Future<void> _worker(Queue<CdbSnapshotFile> queue, String parent) async {
    while (!_stopRequested && _error == null && queue.isNotEmpty) {
      final file = queue.removeFirst();
      _activeFiles.add(file.name);
      notifyListeners();
      try {
        await _downloadWithRetries(file, parent);
        if (!_stopRequested) _filesDone++;
      } catch (e) {
        _error = 'Downloading ${file.name} failed: $e';
      } finally {
        _activeFiles.remove(file.name);
        notifyListeners();
      }
    }
  }

  Future<void> _downloadWithRetries(CdbSnapshotFile file, String parent) async {
    const maxAttempts = 5;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_stopRequested) return;
      try {
        await _downloadFile(file, parent);
        return;
      } on _DownloadStopped {
        return;
      } catch (e) {
        if (attempt == maxAttempts) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }

  Future<void> _downloadFile(CdbSnapshotFile file, String parent) async {
    final target = File(p.join(parent, file.path));
    await target.parent.create(recursive: true);

    var offset = await target.exists() ? await target.length() : 0;
    if (offset > file.bytes) {
      await target.delete();
      offset = 0;
    }
    if (offset == file.bytes) return;

    final free = await freeBytesForPath(target.parent.path);
    if (free != null &&
        free < (file.bytes - offset) + kCdbDownloadHeadroomBytes) {
      throw StateError(
        'Only ${formatBytes(free)} free — not enough for ${file.name} '
        '(${formatBytes(file.bytes - offset)} left to fetch).',
      );
    }

    final request = await _http.getUrl(_urlFor(file.path));
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    final response = await request.close();

    if (offset > 0 && response.statusCode != HttpStatus.partialContent) {
      // The mirror ignored the range: start the file over rather than
      // appending a second copy of its head.
      await response.drain<void>();
      await target.delete();
      _bytesDone -= offset;
      throw StateError('Range request refused (${response.statusCode})');
    }
    if (offset == 0 && response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode} for ${file.name}');
    }

    final sink = target.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    var stopped = false;
    try {
      await for (final chunk in response) {
        if (_stopRequested) {
          stopped = true;
          break;
        }
        sink.add(chunk);
        _bytesDone += chunk.length;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (stopped) throw const _DownloadStopped();

    final written = await target.length();
    if (written != file.bytes) {
      throw StateError(
        'Short read: got ${formatBytes(written)} of ${formatBytes(file.bytes)}',
      );
    }
  }

  void _ensureJob() {
    final snap = _snapshot;
    if (snap == null) return;
    final existing = _job;
    if (existing != null && existing.isActive) {
      existing.updateStatus(JobStatus.running);
      return;
    }
    final job = JobManager.instance.createJob(
      type: JobType.evalDatabase,
      label: 'ChessDB dump — ${snap.id}',
    );
    job.resumable = true;
    job.onCancel = () => unawaited(pause());
    job.updateStatus(JobStatus.running);
    _job = job;
  }

  void _startTicker() {
    _lastSampleBytes = _bytesDone;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final delta = _bytesDone - _lastSampleBytes;
      _lastSampleBytes = _bytesDone;
      // Exponential moving average: a per-second sample of a multi-hour
      // transfer is far too jumpy to show as-is.
      _bytesPerSecond = _bytesPerSecond == 0
          ? delta.toDouble()
          : _bytesPerSecond * 0.7 + delta * 0.3;
      _job?.updateProgress(
        JobProgress(
          fraction: fraction,
          message:
              '${formatBytes(_bytesDone)} of ${formatBytes(_bytesTotal)}'
              '${eta == null ? '' : ' — ${formatDuration(eta!)} left'}',
          nodesProcessed: _filesDone,
          totalNodes: filesTotal,
        ),
      );
      notifyListeners();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    _bytesPerSecond = 0;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _http.close(force: true);
    super.dispose();
  }
}

class _DownloadStopped implements Exception {
  const _DownloadStopped();
}
