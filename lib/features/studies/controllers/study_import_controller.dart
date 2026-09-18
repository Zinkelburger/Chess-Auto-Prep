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
/// Completed Lichess downloads and generated PGN use [publishStudy], sharing
/// publication recovery and app-close ownership without a download job.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../utils/safe_change_notifier.dart';
import '../../../chess_core/pgn/pgn_text.dart'
    show extractHeaders, countPgnGames;
import '../../documents/models/pgn_document.dart';
import '../models/chapter_naming.dart';
import '../models/study_import_state.dart';
import '../../documents/controllers/document_save_session.dart';
import '../../documents/repositories/pgn_document_store.dart';
import '../repositories/study_import_repository.dart';

/// How a finished (or abandoned) collection download turned out.
class StudyImportResult {
  const StudyImportResult({
    required this.studyName,
    required this.studyPath,
    required this.chapters,
    required this.failed,
    required this.cancelled,
    this.failure,
    this.publication,
  });

  final String studyName;

  /// Acknowledged destination; null for empty or unsuccessful publication.
  final String? studyPath;

  final int chapters;

  /// Games that could not be fetched and were skipped.
  final int failed;

  final bool cancelled;

  /// Set when the run stopped early; the partial study is still written.
  final StudyImportFailure? failure;

  /// Native outcome retained for failed/uncertain publications.
  final StudyImportPublication? publication;

  bool get wroteAnything => studyPath != null && chapters > 0;
}

class StudyImportController extends ChangeNotifier with SafeChangeNotifier {
  StudyImportController({
    required this._repository,
    required this.jobs,
    required this._documents,
  });

  final PgnDocumentStore _documents;

  DocumentSaveSession? _publicationRecovery;
  StreamSubscription<Object?>? _recoveryChanges;
  DocumentSaveSession? get publicationRecovery => _publicationRecovery;
  bool get needsPublicationReview =>
      _publicationRecovery != null &&
      (_publicationRecovery!.state.dirty ||
          _publicationRecovery!.state.uncertain);

  final StudyImportRepository _repository;
  final StudyImportJobs jobs;
  StudyImportSource? _source;
  Future<StudyImportResult>? _pending;
  bool _closing = false;

  Object get closeRevision =>
      (_running, _resultGeneration, _pending, _publicationRecovery?.state);

  /// Settle acknowledged cache and publication work before native app close.
  /// A cancelled close may start another run; permanent disposal is separate.
  Future<void> stop() async {
    cancel();
    await _pending;
  }

  Future<void> shutdown() async {
    _closing = true;
    await stop();
    await _recoveryChanges?.cancel();
    await _publicationRecovery?.dispose();
  }

  @override
  void dispose() {
    unawaited(shutdown().catchError((Object _) {}));
    super.dispose();
  }

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
  StudyImportProgress _progress = const StudyImportProgress(
    StudyImportStage.idle,
  );
  int _done = 0;
  int _total = 0;
  StudyImportJob? _job;

  StudyImportResult? _lastResult;
  int _resultGeneration = 0;

  bool get isRunning => _running;

  /// What is being downloaded, e.g. `Fischer's 60 Memorable Games`.
  String get label => _label;

  /// One-line status: `Downloading 14/60 · next in 18s`.
  StudyImportProgress get progress => _progress;

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
  /// comes back on [StudyImportResult.failure] and is recorded on the job.
  /// Rejects with [StudyImportRejected] if a run is already going.
  Future<StudyImportResult> startCollectionDownload({
    required List<String> gameIds,
    required String studyName,
    Duration delay = defaultDelay,
  }) {
    final rejection = admissionFailure;
    if (rejection != null) return Future.error(rejection);
    if (gameIds.isEmpty) {
      return Future.error(
        const StudyImportRejected(StudyImportFailure.emptyCollection),
      );
    }
    if (gameIds.any((id) => !RegExp(r'^\d+$').hasMatch(id))) {
      return Future.error(
        const StudyImportRejected(StudyImportFailure.invalidGameIds),
      );
    }
    final captured = List<String>.unmodifiable(gameIds);
    return _pending = _start(
      gameIds: captured,
      studyName: studyName,
      delay: delay,
    );
  }

  /// Synchronous admission policy, also used by dialogs before handing off work.
  StudyImportRejected? get admissionFailure {
    if (_closing || isDisposed) {
      return const StudyImportRejected(StudyImportFailure.closed);
    }
    if (needsPublicationReview) {
      return const StudyImportRejected(
        StudyImportFailure.unresolvedPublication,
      );
    }
    if (_running) {
      return const StudyImportRejected(StudyImportFailure.alreadyRunning);
    }
    return null;
  }

  /// Publish completed downloaded PGN through the same retained receipt and
  /// close ownership as a collection. No document is opened as a side effect.
  Future<StudyImportResult> publishStudy({
    required String name,
    required String pgn,
  }) {
    final rejection = admissionFailure;
    if (rejection != null) return Future.error(rejection);
    _running = true;
    _cancelRequested = false;
    _label = name;
    _done = _total = countPgnGames(pgn);
    _progress = const StudyImportProgress(StudyImportStage.starting);
    final pending = _pending =
        _finish(
          studyName: name,
          content: pgn,
          chapters: _total,
          failed: 0,
        ).whenComplete(() {
          _running = false;
          notifyListeners();
        });
    notifyListeners();
    return pending;
  }

  Future<StudyImportResult> _start({
    required List<String> gameIds,
    required String studyName,
    required Duration delay,
  }) async {
    _running = true;
    _cancelRequested = false;
    _label = studyName;
    _done = 0;
    _total = gameIds.length;
    _progress = const StudyImportProgress(StudyImportStage.starting);
    StudyImportSource? client;
    try {
      _reportJob(() => _job = jobs.start(studyName));
      client = _source = _repository.openSource();
      notifyListeners();
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
    } catch (_) {
      final result = await _finish(
        studyName: studyName,
        content: '',
        chapters: 0,
        failed: 0,
        failure: StudyImportFailure.startup,
      );
      return result;
    } finally {
      client?.close();
      _source = null;
      _running = false;
      _job = null;
      notifyListeners();
    }
  }

  /// Ask the running download to stop. Games already fetched are still written.
  void cancel() {
    if (!_running) return;
    _cancelRequested = true;
    _source?.close();
    _setProgress(const StudyImportProgress(StudyImportStage.cancelling));
  }

  Future<StudyImportResult> _run({
    required StudyImportSource client,
    required List<String> gameIds,
    required String studyName,
    required Duration delay,
  }) async {
    final chapters = <String>[];
    var failed = 0;
    var throttledInARow = 0;
    var pace = delay;
    var hasRequested = false;
    StudyImportFailure? failure;

    try {
      for (var i = 0; i < gameIds.length; i++) {
        if (_cancelRequested) break;
        final gid = gameIds[i];

        var pgn = await _repository.readCachedGame(gid);
        if (_cancelRequested) break;
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
              failure = StudyImportFailure.throttled;
              break;
            }
          } else {
            throttledInARow = 0;
          }

          pgn = fetched.pgn;
          if (pgn != null) {
            await _repository.cacheGame(gid, pgn);
          } else {
            failed++;
            _publishProgress(
              i + 1,
              gameIds.length,
              StudyImportProgress(StudyImportStage.skipped, gameId: gid),
            );
            continue;
          }
        }

        chapters.add(_asChapter(pgn, index: chapters.length));
        _done = chapters.length + failed;
        _publishProgress(
          _done,
          gameIds.length,
          StudyImportProgress(
            StudyImportStage.downloaded,
            downloaded: chapters.length,
          ),
        );
      }
    } catch (_) {
      if (!_cancelRequested) {
        failure = StudyImportFailure.download;
      }
    }

    return _finish(
      studyName: studyName,
      content: chapters.isEmpty ? '' : '${chapters.join('\n\n')}\n',
      chapters: chapters.length,
      failed: failed,
      failure: failure,
    );
  }

  /// Fetch one game, retrying through the backoff ladder while it is throttled.
  Future<({String? pgn, bool throttled})> _fetchWithBackoff({
    required StudyImportSource client,
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

      if (!await _sleep(wait, game: index + 1, retrying: attempt > 0)) {
        return (pgn: null, throttled: sawThrottle);
      }
      _publishProgress(
        _done,
        total,
        StudyImportProgress(StudyImportStage.fetching, game: index + 1),
      );
      final result = await client.fetchGame(gid);

      switch (result.status) {
        case StudyGameFetchStatus.ok:
          return (pgn: result.pgn, throttled: sawThrottle);
        case StudyGameFetchStatus.failed:
          return (pgn: null, throttled: sawThrottle);
        case StudyGameFetchStatus.throttled:
          sawThrottle = true;
      }
    }
    return (pgn: null, throttled: true);
  }

  /// Write the collected games out as a study file.
  Future<StudyImportResult> _finish({
    required String studyName,
    required String content,
    required int chapters,
    required int failed,
    StudyImportFailure? failure,
  }) async {
    String? path;
    StudyImportPublication? publication;
    if (chapters > 0) {
      try {
        publication = await _repository.publish(studyName, content);
        final outcome = publication.outcome;
        if (outcome is PgnSaved) {
          path = outcome.after.path;
        } else {
          failure =
              publication.failure ??
              (outcome is PgnWriteUncertain
                  ? StudyImportFailure.uncertainPublication
                  : StudyImportFailure.publication);
        }
      } catch (error) {
        publication = StudyImportPublication(
          path: '',
          content: content,
          outcome: PgnWriteUncertain(
            error: error,
            before: null,
            observed: null,
          ),
        );
        failure = StudyImportFailure.uncertainPublication;
      }
    }

    await _recoveryChanges?.cancel();
    await _publicationRecovery?.dispose();
    _publicationRecovery = path == null && publication != null
        ? DocumentSaveSession.failedCreate(
            _documents,
            path: publication.path,
            content: publication.content,
            outcome: publication.outcome,
          )
        : null;
    _recoveryChanges = _publicationRecovery?.changes.listen(
      (_) => notifyListeners(),
    );
    final result = StudyImportResult(
      studyName: studyName,
      studyPath: path,
      chapters: path == null ? 0 : chapters,
      failed: failed,
      cancelled: _cancelRequested,
      failure: failure,
      publication: publication,
    );

    _reportJob(
      () => _job?.finish(
        chapters: result.chapters,
        total: _total,
        cancelled: _cancelRequested,
        failure: failure,
      ),
    );

    _lastResult = result;
    _resultGeneration++;
    _progress = const StudyImportProgress(StudyImportStage.idle);
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
  Future<bool> _sleep(
    Duration total, {
    required int game,
    required bool retrying,
  }) async {
    if (_cancelRequested) return false;
    if (total <= Duration.zero) return true;

    final end = DateTime.now().add(total);
    while (true) {
      if (_cancelRequested) return false;
      final remaining = end.difference(DateTime.now());
      if (remaining <= Duration.zero) return true;
      _setProgress(
        StudyImportProgress(
          retrying ? StudyImportStage.retrying : StudyImportStage.waiting,
          game: game,
          remainingSeconds: (remaining.inMilliseconds / 1000).ceil(),
        ),
      );
      await Future.delayed(
        remaining < const Duration(seconds: 1)
            ? remaining
            : const Duration(seconds: 1),
      );
    }
  }

  // ── Progress plumbing ──────────────────────────────────────────────────

  // Job history is a presentation projection. Its failure must never replay
  // publication or replace the acknowledged document receipt.
  void _reportJob(void Function() report) {
    try {
      report();
    } catch (error, stack) {
      debugPrint('Study import job reporting failed: $error\n$stack');
    }
  }

  void _publishProgress(int done, int total, StudyImportProgress progress) {
    _done = done;
    _setProgress(progress);
  }

  void _setProgress(StudyImportProgress progress) {
    _progress = progress;
    _reportJob(() => _job?.progress(_done, _total, progress));
    notifyListeners();
  }
}
