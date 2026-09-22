/// In-app download of the ChessDB full dump.
///
/// The snapshot is ~1.2 TB across a few hundred files, so the transfer is
/// built to be interrupted: every file is fetched with an HTTP range request
/// ([SnapshotFileDownloader]), a partial file resumes from its own length,
/// and finished files are never re-fetched. Stopping and starting again —
/// including across app restarts — carries on where it left off.
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

import '../../features/settings/controllers/eval_database_settings.dart';
import '../../utils/safe_change_notifier.dart';
import '../../utils/time_format.dart';
import '../jobs/repertoire_job.dart';
import 'cdb_snapshot_catalog.dart';
import 'cdbdirect_parse.dart';
import 'eval_database_job.dart';
import 'snapshot_file_downloader.dart';
import 'storage_volumes.dart';
import 'transfer_rate_meter.dart';

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
    required this.settings,
    CdbSnapshotCatalog? catalog,
    this.concurrency = 4,
    Uri Function(String repoPath)? urlBuilder,
  }) : _catalog = catalog ?? CdbSnapshotCatalog() {
    _files = SnapshotFileDownloader(
      http: _http,
      urlFor: urlBuilder ?? chessDbFileUrl,
      openSink: _openSnapshotSink,
      headroomBytes: kCdbDownloadHeadroomBytes,
    );
  }

  final EvalDatabaseSettings settings;

  static const _keyParentDir = 'eval.cdb_download.parent_dir';
  static const _keySnapshotId = 'eval.cdb_download.snapshot_id';

  /// Parallel file transfers. Four saturates a home connection without
  /// turning the disk write pattern into a seek storm.
  final int concurrency;

  final CdbSnapshotCatalog _catalog;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 30);
  late final SnapshotFileDownloader _files;
  final TransferRateMeter _rate = TransferRateMeter();

  CdbDownloadPhase _phase = CdbDownloadPhase.idle;
  CdbSnapshot? _snapshot;
  String? _parentDir;
  String? _error;

  int _bytesDone = 0;
  int _bytesTotal = 0;
  int _filesDone = 0;

  final Set<String> _activeFiles = <String>{};
  List<CdbFileProblem> _problems = const [];

  bool _stopRequested = false;
  Future<void>? _runInFlight;
  Future<void>? _closeFuture;

  Future<T> _operate<T>(Future<T> Function() action, {bool interrupt = false}) {
    if (_closeFuture != null || isDisposed) {
      return Future.error(StateError('Download controller is closed'));
    }
    final previous = _runInFlight;
    if (previous != null && !interrupt) {
      return Future.error(StateError('A download operation is still running'));
    }
    _stopRequested = interrupt;
    final settled = Completer<void>();
    _runInFlight = settled.future;
    notifyListenersOutsideBuild();
    return (() async {
      try {
        await previous;
        if (_closeFuture != null || isDisposed) {
          throw StateError('Download controller is closed');
        }
        _error = null;
        return await action();
      } catch (error) {
        _error = '$error';
        _phase = CdbDownloadPhase.failed;
        rethrow;
      } finally {
        if (identical(_runInFlight, settled.future)) _runInFlight = null;
        settled.complete();
        notifyListeners();
      }
    })();
  }

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
  double get bytesPerSecond => _rate.bytesPerSecond;
  List<CdbFileProblem> get problems => _problems;

  bool get isRunning => _runInFlight != null;

  bool get canResume =>
      _snapshot != null &&
      _parentDir != null &&
      (_phase == CdbDownloadPhase.paused || _phase == CdbDownloadPhase.failed);

  double get fraction =>
      _bytesTotal <= 0 ? 0 : (_bytesDone / _bytesTotal).clamp(0.0, 1.0);

  int get bytesRemaining => (_bytesTotal - _bytesDone).clamp(0, _bytesTotal);

  /// Time left at the current rate, or null before a rate is known.
  Duration? get eta => _rate.eta(bytesRemaining);

  /// Files being transferred right now, for the progress line.
  List<String> get activeFiles => _activeFiles.toList()..sort();

  /// Directory to hand the reader once the download finishes.
  String? get dataDirectory {
    final parent = _parentDir;
    final snap = _snapshot;
    if (parent == null || snap == null) return null;
    return _dataDirectoryOf(parent, snap);
  }

  static String _dataDirectoryOf(String parent, CdbSnapshot snap) =>
      p.join(parent, snap.id, 'data');

  /// The streamed write behind every snapshot file: appended to on resume,
  /// truncated on a fresh start. Reproducible data, so no journal.
  static IOSink _openSnapshotSink(File target, {required bool append}) =>
      target.openWrite(mode: append ? FileMode.append : FileMode.write);

  // ── Setup ────────────────────────────────────────────────────────────────

  /// Re-attach to a download parked by an earlier run of the app.
  ///
  /// Only reads what is on disk — it never starts a transfer, so launching
  /// the app on a metered connection does not silently resume 1.2 TB.
  Future<void> loadSaved() {
    if (isRunning || (_snapshot != null && _phase != CdbDownloadPhase.failed)) {
      return Future.value();
    }
    return _operate(_loadSaved);
  }

  Future<void> _loadSaved() async {
    _snapshot = null;
    _parentDir = null;
    _phase = CdbDownloadPhase.idle;
    final prefs = await SharedPreferences.getInstance();
    final parent = prefs.getString(_keyParentDir);
    final id = prefs.getString(_keySnapshotId);
    if (parent == null || parent.isEmpty || id == null || id.isEmpty) return;
    if (!await Directory(p.join(parent, id)).exists()) return;

    final snap = await _catalog.fetchSnapshot(id);
    if (_stopRequested) return;
    _snapshot = snap;
    _parentDir = parent;
    _bytesTotal = snap.totalBytes;
    await _measureLocal();
    _phase = _phaseForMeasuredBytes();
  }

  /// Prepare a download of [snapshot] into [parentDir] without starting it.
  Future<void> prepare({
    required CdbSnapshot snapshot,
    required String parentDir,
  }) => _operate(() async {
    _snapshot = snapshot;
    _parentDir = parentDir;
    _bytesTotal = snapshot.totalBytes;
    _problems = const [];
    _phase = CdbDownloadPhase.preparing;
    notifyListeners();

    await _measureLocal();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyParentDir, parentDir);
    await prefs.setString(_keySnapshotId, snapshot.id);

    _phase = _phaseForMeasuredBytes();
    notifyListeners();
  });

  CdbDownloadPhase _phaseForMeasuredBytes() => _bytesDone >= _bytesTotal
      ? CdbDownloadPhase.complete
      : CdbDownloadPhase.paused;

  // ── Transfer ─────────────────────────────────────────────────────────────

  /// Start, or carry on from where a previous attempt stopped.
  Future<void> start() {
    if (isRunning) return _runInFlight ?? Future.value();
    return _operate(() async {
      final snap = _snapshot;
      final parent = _parentDir;
      if (snap == null || parent == null) return;

      _phase = CdbDownloadPhase.downloading;
      _job = ensureEvalDatabaseJob(
        _job,
        label: 'ChessDB dump — ${snap.id}',
        onCancel: () => unawaited(pause()),
      );
      _startTicker();
      notifyListeners();

      await _run(snap, parent);
    });
  }

  /// Park the transfer. Everything already fetched stays on disk.
  Future<void> pause() async {
    if (!isRunning) return;
    _stopRequested = true;
    await _runInFlight;
  }

  /// Forget the download without touching the files.
  Future<void> forget() => _operate(_forget, interrupt: true);

  Future<void> _forget() async {
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

  /// Validate and activate an existing dump under the same admission as deletion.
  Future<void> activateDirectory(String path) => _operate(() async {
    final validation = await validateCdbDirectDataDirDetailed(path);
    if (!validation.isValid) throw StateError(validation.message);
    if (_stopRequested || isDisposed) return;
    await settings.configureCdbDirectory(path);
    _phase = _snapshot == null
        ? CdbDownloadPhase.idle
        : _phaseForMeasuredBytes();
  });

  /// Delete every file fetched so far, then forget the download.
  Future<void> deleteFiles() => _operate(() async {
    final parent = _parentDir;
    final snap = _snapshot;
    if (parent != null && snap != null) {
      await settings.clearCdbDirectory(_dataDirectoryOf(parent, snap));
      final dir = Directory(p.join(parent, snap.id));
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    await _forget();
  }, interrupt: true);

  /// Compare local file lengths with the manifest and report the mismatches.
  Future<List<CdbFileProblem>> check() => _operate(() async {
    final snap = _snapshot;
    final parent = _parentDir;
    if (snap == null || parent == null) return const [];

    final previous = _phase;
    _phase = CdbDownloadPhase.checking;
    notifyListeners();

    final found = <CdbFileProblem>[];
    for (final file in snap.files) {
      final length = await _localLength(parent, file) ?? -1;
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
    if (found.isEmpty) {
      _phase = CdbDownloadPhase.complete;
    } else if (previous == CdbDownloadPhase.complete) {
      _phase = CdbDownloadPhase.paused;
    } else {
      _phase = previous;
    }
    notifyListeners();
    return found;
  });

  // ── Internals ────────────────────────────────────────────────────────────

  /// Bytes of [file] on disk, or null when it is absent.
  static Future<int?> _localLength(String parent, CdbSnapshotFile file) async {
    final local = File(p.join(parent, file.path));
    return await local.exists() ? local.length() : null;
  }

  Future<void> _measureLocal() async {
    final snap = _snapshot;
    final parent = _parentDir;
    if (snap == null || parent == null) return;
    var done = 0;
    var complete = 0;
    for (final file in snap.files) {
      final length = await _localLength(parent, file);
      if (length == null) continue;
      // A file longer than the manifest says is corrupt, not ahead: count
      // nothing for it so the transfer redoes it from zero.
      if (length > file.bytes) continue;
      done += length;
      if (length == file.bytes) complete++;
    }
    _bytesDone = done;
    _filesDone = complete;
    _rate.reset(done);
  }

  Future<void> _run(CdbSnapshot snap, String parent) async {
    try {
      await Directory(_dataDirectoryOf(parent, snap)).create(recursive: true);
      await _measureLocal();
      notifyListeners();

      final queue = Queue<CdbSnapshotFile>();
      for (final file in snap.files) {
        if (await _localLength(parent, file) == file.bytes) continue;
        queue.add(file);
      }

      if (_stopRequested) {
        _phase = CdbDownloadPhase.paused;
        return;
      }
      if (queue.isEmpty) {
        await _finish(snap, parent);
        return;
      }

      await _requireRoomFor(queue, p.join(parent, snap.id));

      await Future.wait([
        for (var i = 0; i < concurrency; i++) _worker(queue, parent),
      ]);

      final error = _error;
      if (error != null) {
        _phase = CdbDownloadPhase.failed;
        _job?.fail(error);
      } else if (_stopRequested) {
        _phase = CdbDownloadPhase.paused;
        _job?.updateStatus(JobStatus.paused);
      } else {
        await _finish(snap, parent);
      }
    } catch (e) {
      if (_stopRequested) {
        _phase = CdbDownloadPhase.paused;
      } else {
        _error = '$e';
        _phase = CdbDownloadPhase.failed;
        _job?.fail('$e');
      }
    } finally {
      _stopTicker();
      _activeFiles.clear();
      notifyListeners();
    }
  }

  /// Stop before filling the volume: a disk with no room left takes the rest
  /// of the desktop down with it.
  Future<void> _requireRoomFor(
    Iterable<CdbSnapshotFile> pending,
    String directory,
  ) async {
    final remaining = pending.fold(0, (sum, f) => sum + f.bytes);
    final space = await freeBytesForPath(directory);
    if (space != null && space < remaining + kCdbDownloadHeadroomBytes) {
      throw StateError(
        '${formatBytes(space)} free where ${formatBytes(remaining)} is still '
        'to download. Free up space, or point the download at another drive.',
      );
    }
  }

  Future<void> _finish(CdbSnapshot snap, String parent) async {
    if (_stopRequested || isDisposed) return;
    _phase = CdbDownloadPhase.complete;
    _bytesDone = _bytesTotal;
    _filesDone = snap.files.length;
    _job?.updateProgress(
      JobProgress(fraction: 1, message: 'Downloaded ${snap.id}'),
    );
    _job?.updateStatus(JobStatus.completed);

    final dataDir = _dataDirectoryOf(parent, snap);
    if (_stopRequested || isDisposed) return;
    try {
      await settings.configureCdbDirectory(dataDir);
    } catch (_) {
      // The artifact is complete. Settings retains its failed activation for
      // explicit retry; downloading the same files again cannot repair it.
    }
  }

  Future<void> _worker(Queue<CdbSnapshotFile> queue, String parent) async {
    while (!_stopRequested && _error == null && queue.isNotEmpty) {
      final file = queue.removeFirst();
      _activeFiles.add(file.name);
      notifyListeners();
      try {
        final outcome = await _files.fetch(
          file,
          parent,
          shouldStop: () => _stopRequested,
          onBytes: (delta) => _bytesDone += delta,
        );
        if (outcome == SnapshotFileOutcome.complete) _filesDone++;
      } catch (e) {
        if (!_stopRequested) _error = 'Downloading ${file.name} failed: $e';
      } finally {
        _activeFiles.remove(file.name);
        notifyListeners();
      }
    }
  }

  void _startTicker() {
    _rate.reset(_bytesDone);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _rate.sample(_bytesDone);
      final eta = this.eta;
      _job?.updateProgress(
        JobProgress(
          fraction: fraction,
          message:
              '${formatBytes(_bytesDone)} of ${formatBytes(_bytesTotal)}'
              '${eta == null ? '' : ' — ${formatCoarseDuration(eta)} left'}',
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
    _rate.reset(_bytesDone);
  }

  /// Stop admission and settle successfully after all admitted work drains.
  Future<void> close() {
    if (_closeFuture case final pending?) return pending;
    _stopRequested = true;
    _stopTicker();
    _http.close(force: true);
    _catalog.dispose();
    return _closeFuture = _runInFlight ?? Future.value();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
