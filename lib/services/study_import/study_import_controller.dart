/// Downloads a chessgames.com collection into a new study, in the background.
///
/// The collection endpoint bans fast callers, so a 60-game collection is a
/// ~22-minute job, not a dialog you can hold open. This owns that run:
///
///   * one request at a time, [_defaultDelay] apart plus jitter — never
///     parallel;
///   * every fetched game is cached to disk before the next request, so a
///     cancel, a crash, or a ban part-way through resumes instead of
///     restarting;
///   * a throttle (429/403, or a soft-ban HTML body) backs off 60 s, 120 s …
///     up to 10 minutes and permanently slows the pace for the rest of the
///     run;
///   * three games throttled in a row is a real ban — the run stops and keeps
///     the cache, so restarting it later picks up where it left off.
///
/// Progress is mirrored into a [RepertoireJob] so the run shows up in the jobs
/// panel alongside generation and audit, and survives leaving Study mode.
///
/// The Lichess path is a single request and does not come through here — see
/// `lichess_study_client.dart`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../utils/log.dart';
import '../../utils/safe_change_notifier.dart';
import '../jobs/repertoire_job.dart';
import '../pgn_parsing_service.dart' show extractHeaders;
import '../storage/app_paths.dart';
import '../storage/storage_factory.dart';
import '../storage/study_naming.dart';
import 'chapter_naming.dart';
import 'chessgames_collection_client.dart';
import 'study_import_exception.dart';

/// How a finished (or abandoned) collection download turned out.
class StudyImportResult {
  const StudyImportResult({
    required this.studyName,
    required this.studyPath,
    required this.chapters,
    required this.failed,
    required this.cancelled,
    this.error,
  });

  final String studyName;

  /// Where the study was written — `null` when nothing was downloaded.
  final String? studyPath;

  final int chapters;

  /// Games that could not be fetched and were skipped.
  final int failed;

  final bool cancelled;

  /// Set when the run stopped early; the partial study is still written.
  final String? error;

  bool get wroteAnything => studyPath != null && chapters > 0;
}

class StudyImportController extends ChangeNotifier with SafeChangeNotifier {
  StudyImportController._();

  /// Application-wide instance — the run must outlive the Study screen.
  static final StudyImportController instance = StudyImportController._();

  /// Create an independent instance (unit tests only).
  @visibleForTesting
  StudyImportController.fresh() : this._();

  // ── Pacing ─────────────────────────────────────────────────────────────

  /// Measured safe pace: ~2–3 s apart earns a 429 inside 20 games, ~22 s apart
  /// sustains 60.
  static const Duration defaultDelay = Duration(seconds: 22);

  static const Duration _minDelay = Duration(seconds: 5);
  static const Duration _maxDelay = Duration(seconds: 60);
  static const Duration _maxBackoff = Duration(minutes: 10);
  static const int _maxAttemptsPerGame = 5;
  static const int _throttledGamesBeforeGivingUp = 3;

  // ── State ──────────────────────────────────────────────────────────────

  final Random _jitter = Random();

  bool _running = false;
  bool _cancelRequested = false;
  String _label = '';
  String _message = '';
  int _done = 0;
  int _total = 0;
  RepertoireJob? _job;

  StudyImportResult? _lastResult;
  int _resultGeneration = 0;

  bool get isRunning => _running;

  /// What is being downloaded, e.g. `Fischer's 60 Memorable Games`.
  String get label => _label;

  /// One-line status: `Downloading 14/60 · next in 18s`.
  String get message => _message;

  int get gamesDone => _done;
  int get gamesTotal => _total;

  double get fraction => _total == 0 ? 0 : _done / _total;

  /// The most recent finished run, for a one-shot "done" notification.
  StudyImportResult? get lastResult => _lastResult;

  /// Bumped once per finished run, so a screen can tell a new result from a
  /// rebuild and show its SnackBar exactly once.
  int get resultGeneration => _resultGeneration;

  // ── Run ────────────────────────────────────────────────────────────────

  /// Download [gameIds] (in order) into a new study named [studyName].
  ///
  /// Returns when the run finishes; never throws once started — a failure
  /// comes back on [StudyImportResult.error] and is recorded on the job.
  /// Throws [StudyImportException] synchronously if a run is already going.
  Future<StudyImportResult> startCollectionDownload({
    required List<String> gameIds,
    required String studyName,
    Duration delay = defaultDelay,
  }) async {
    if (_running) {
      throw const StudyImportException(
        'A collection download is already running.',
      );
    }
    if (gameIds.isEmpty) {
      throw const StudyImportException('No games found in that collection.');
    }

    _running = true;
    _cancelRequested = false;
    _label = studyName;
    _done = 0;
    _total = gameIds.length;
    _message = 'Starting…';
    _job = JobManager.instance.createJob(
      type: JobType.studyImport,
      label: 'Import: $studyName',
    )..updateStatus(JobStatus.running);
    notifyListeners();

    final client = http.Client();
    try {
      return await _run(
        client: client,
        gameIds: gameIds,
        studyName: studyName,
        delay: Duration(
          milliseconds: delay.inMilliseconds.clamp(
            _minDelay.inMilliseconds,
            _maxDelay.inMilliseconds,
          ),
        ),
      );
    } finally {
      client.close();
      _running = false;
      _job = null;
      notifyListeners();
    }
  }

  /// Ask the running download to stop. Games already fetched are still written.
  void cancel() {
    if (!_running) return;
    _cancelRequested = true;
    _setMessage('Cancelling…');
  }

  Future<StudyImportResult> _run({
    required http.Client client,
    required List<String> gameIds,
    required String studyName,
    required Duration delay,
  }) async {
    final chapters = <String>[];
    var failed = 0;
    var throttledInARow = 0;
    var pace = delay;
    var hasRequested = false;
    String? error;

    for (var i = 0; i < gameIds.length; i++) {
      if (_cancelRequested) break;
      final gid = gameIds[i];

      var pgn = await _readCache(gid);
      if (pgn == null) {
        final fetched = await _fetchWithBackoff(
          client: client,
          gid: gid,
          index: i,
          total: gameIds.length,
          pace: pace,
          // Only requests need spacing: the *first* one goes out immediately,
          // so resuming a run whose first 30 games are cached costs nothing.
          waitFirst: hasRequested,
        );
        hasRequested = true;
        if (_cancelRequested) break;

        // Any throttle means the pace was too fast for right now, even if the
        // retry eventually landed.
        if (fetched.throttled) pace = _slowerThan(pace);

        // Only a game we *gave up on* counts toward "we are banned" — games
        // that came through after a backoff mean the pacing is working.
        if (fetched.throttled && fetched.pgn == null) {
          throttledInARow++;
          if (throttledInARow >= _throttledGamesBeforeGivingUp) {
            error =
                'chessgames.com is refusing requests. Downloaded games are '
                'cached — start the same collection again later to resume.';
            break;
          }
        } else {
          throttledInARow = 0;
        }

        pgn = fetched.pgn;
        if (pgn != null) {
          await _writeCache(gid, pgn);
        } else {
          failed++;
          _publishProgress(i + 1, gameIds.length, 'Skipped game $gid');
          continue;
        }
      }

      chapters.add(_asChapter(pgn, index: chapters.length));
      _done = chapters.length + failed;
      _publishProgress(_done, gameIds.length, 'Downloaded ${chapters.length}');
    }

    return _finish(
      studyName: studyName,
      chapters: chapters,
      failed: failed,
      error: error,
    );
  }

  /// Fetch one game, retrying through the backoff ladder while it is throttled.
  Future<({String? pgn, bool throttled})> _fetchWithBackoff({
    required http.Client client,
    required String gid,
    required int index,
    required int total,
    required Duration pace,
    required bool waitFirst,
  }) async {
    var sawThrottle = false;

    for (var attempt = 0; attempt < _maxAttemptsPerGame; attempt++) {
      final wait = attempt == 0
          ? (waitFirst ? _paced(pace) : Duration.zero)
          : _backoff(attempt);

      final label = attempt == 0
          ? 'Game ${index + 1}/$total'
          : 'Rate-limited — retrying game ${index + 1}/$total';
      if (!await _sleep(wait, label)) {
        return (pgn: null, throttled: sawThrottle);
      }

      _publishProgress(_done, total, 'Fetching game ${index + 1}/$total');
      final result = await fetchGamePgn(gid, client: client);

      switch (result.status) {
        case ChessgamesFetchStatus.ok:
          return (pgn: result.pgn, throttled: sawThrottle);
        case ChessgamesFetchStatus.failed:
          log.w('[StudyImport] gid $gid unavailable — skipping');
          return (pgn: null, throttled: sawThrottle);
        case ChessgamesFetchStatus.throttled:
          sawThrottle = true;
          log.w('[StudyImport] throttled on gid $gid (attempt ${attempt + 1})');
      }
    }
    return (pgn: null, throttled: true);
  }

  /// Write the collected games out as a study file.
  Future<StudyImportResult> _finish({
    required String studyName,
    required List<String> chapters,
    required int failed,
    String? error,
  }) async {
    String? path;
    if (chapters.isNotEmpty) {
      try {
        path = await _writeStudy(studyName, chapters);
      } catch (e) {
        log.e('[StudyImport] could not write study "$studyName": $e');
        error ??=
            'Downloaded ${chapters.length} games but could not save the '
            'study file.';
      }
    }

    final result = StudyImportResult(
      studyName: studyName,
      studyPath: path,
      chapters: path == null ? 0 : chapters.length,
      failed: failed,
      cancelled: _cancelRequested,
      error: error,
    );

    final job = _job;
    if (job != null) {
      if (error != null) {
        job.fail(error);
      } else {
        job.updateProgress(
          JobProgress(
            fraction: 1,
            message: '${result.chapters} chapters',
            nodesProcessed: result.chapters,
            totalNodes: _total,
          ),
        );
        job.updateStatus(
          _cancelRequested ? JobStatus.cancelled : JobStatus.completed,
        );
      }
    }

    _lastResult = result;
    _resultGeneration++;
    _message = '';
    notifyListeners();
    return result;
  }

  /// Rename a downloaded game into a usable chapter title and hand back its
  /// PGN. Collections repeat the tournament in every `[Event]`, which would
  /// give a study whose chapters are 60 copies of one name.
  String _asChapter(String pgn, {required int index}) {
    final headers = extractHeaders(pgn);
    return withEventHeader(
      pgn.trim(),
      gameChapterName(headers, fallback: 'Game ${index + 1}'),
    );
  }

  Future<String> _writeStudy(String studyName, List<String> chapters) async {
    // Never overwrite an existing study — a re-run of the same collection
    // lands beside the old one.
    final reserved = await reserveStudyPath(studyName);
    await StorageFactory.instance.writeFile(
      reserved.path,
      '${chapters.join('\n\n')}\n',
    );
    return reserved.path;
  }

  // ── Pacing helpers ─────────────────────────────────────────────────────

  /// [pace] plus 0–3 s of jitter, so repeated runs don't hit a fixed rhythm.
  Duration _paced(Duration pace) =>
      pace + Duration(milliseconds: _jitter.nextInt(3000));

  Duration _backoff(int attempt) {
    final seconds = 60 * (1 << (attempt - 1));
    return seconds >= _maxBackoff.inSeconds
        ? _maxBackoff
        : Duration(seconds: seconds);
  }

  Duration _slowerThan(Duration pace) {
    final next = pace * 1.5;
    return next > _maxDelay ? _maxDelay : next;
  }

  /// Sleep [total], ticking once a second so the countdown is live and a
  /// cancel lands promptly. Returns `false` if cancelled mid-wait.
  Future<bool> _sleep(Duration total, String what) async {
    if (_cancelRequested) return false;
    if (total <= Duration.zero) return true;

    final end = DateTime.now().add(total);
    while (true) {
      if (_cancelRequested) return false;
      final remaining = end.difference(DateTime.now());
      if (remaining <= Duration.zero) return true;
      _setMessage('$what · next in ${_humanize(remaining)}');
      await Future.delayed(
        remaining < const Duration(seconds: 1)
            ? remaining
            : const Duration(seconds: 1),
      );
    }
  }

  static String _humanize(Duration d) {
    if (d.inMinutes >= 1) {
      final seconds = d.inSeconds % 60;
      return seconds == 0 ? '${d.inMinutes}m' : '${d.inMinutes}m ${seconds}s';
    }
    return '${d.inSeconds + 1}s';
  }

  // ── Progress plumbing ──────────────────────────────────────────────────

  void _publishProgress(int done, int total, String what) {
    _done = done;
    _setMessage(total == 0 ? what : '$what · $done/$total');
  }

  void _setMessage(String message) {
    _message = message;
    _job?.updateProgress(
      JobProgress(
        fraction: fraction,
        message: message,
        nodesProcessed: _done,
        totalNodes: _total,
      ),
    );
    notifyListeners();
  }

  // ── Per-game cache ─────────────────────────────────────────────────────

  Future<File> _cacheFile(String gid) async {
    final dir = await AppPaths.chessgamesCacheDirectory(create: true);
    return File(p.join(dir.path, '$gid.pgn'));
  }

  Future<String?> _readCache(String gid) async {
    try {
      final file = await _cacheFile(gid);
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return content.trim().isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String gid, String pgn) async {
    try {
      await (await _cacheFile(gid)).writeAsString(pgn);
    } catch (e) {
      // A cache miss next time is the only cost.
      log.w('[StudyImport] could not cache gid $gid: $e');
    }
  }
}
