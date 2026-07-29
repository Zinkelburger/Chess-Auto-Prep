/// Background auto-analysis of recent games.
///
/// After the games pane loads its list, every in-window game that has no
/// stored evals yet is analyzed here — sequentially, as a JobManager-visible,
/// cancellable job — and the annotated movetext is patched back into the
/// games-library cache by dedup key. Opening a game afterwards restores the
/// analysis instantly from those comments, and the pane's summary chips fill
/// in as each game finishes ("come home, open the app, the review is already
/// done").
library;

import 'package:flutter/foundation.dart';

import '../../../services/engine/engine_lifecycle.dart';
import '../../../services/game_analysis_controller.dart';
import '../../../services/games_library/games_library_service.dart';
import '../../../services/jobs/repertoire_job.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/recent_game.dart';
import 'game_review_summary.dart';

class GameAutoAnalysisService extends ChangeNotifier with SafeChangeNotifier {
  GameAutoAnalysisService._();
  static final GameAutoAnalysisService instance = GameAutoAnalysisService._();

  /// Cap per run — the first run against a never-analyzed backlog would
  /// otherwise burn engine time for hours. The job label names the cap, so a
  /// truncated run is never mistaken for full coverage; the next refresh
  /// picks up the remainder.
  static const int maxGamesPerRun = 20;

  /// Give up after this many games in a row produce no analysis — that means
  /// the engine itself is unavailable (no binary, no workers), not that one
  /// game was odd.
  static const int _maxConsecutiveFailures = 2;

  /// Registered by the PGN viewer: dedup key of the game it currently shows,
  /// or null. That game is skipped here — the viewer's own auto-analysis
  /// covers it, and two annotators racing on one game would double the work
  /// and fight over the write.
  String? Function()? currentlyOpenGame;

  /// Games already attempted this session (analyzed, failed, or skipped as
  /// open-in-viewer at the time) — never re-attempted until restart.
  final Set<String> _processed = {};

  bool _running = false;
  bool _cancelled = false;
  GameAnalysisController? _active;

  bool get isRunning => _running;

  void cancel() {
    _cancelled = true;
    _active?.cancel();
  }

  /// Analyze the unanalyzed games in [games] (expected newest-first). Safe to
  /// call on every list refresh: no-ops while running, and each game is
  /// attempted at most once per session.
  Future<void> maybeRun(List<RecentGame> games) async {
    if (_running) return;
    final open = currentlyOpenGame?.call();
    final pending = <RecentGame>[
      for (final g in games)
        if (g.meWhite != null &&
            g.summary == null &&
            g.record.dedupKey != open &&
            !_processed.contains(g.record.dedupKey))
          g,
    ];
    if (pending.isEmpty) return;
    final batch = pending.take(maxGamesPerRun).toList();

    _running = true;
    _cancelled = false;
    // Lease the shared engine pool so a mode switch can't dispose the
    // workers mid-run (same rule as the tactics import job).
    EngineLifecycle.instance.retainPool();
    final job = JobManager.instance.createJob(
      type: JobType.gameAnalysis,
      label: pending.length > batch.length
          ? 'Analyze recent games (newest ${batch.length} of ${pending.length})'
          : 'Analyze recent games',
    );
    job.onCancel = cancel;
    job.updateStatus(JobStatus.running);
    notifyListeners();

    var done = 0;
    var consecutiveFailures = 0;
    try {
      for (final game in batch) {
        if (_cancelled) break;
        _processed.add(game.record.dedupKey);
        if (currentlyOpenGame?.call() == game.record.dedupKey) continue;
        job.updateProgress(
          JobProgress(
            fraction: done / batch.length,
            message: '${game.white} vs ${game.black}',
            nodesProcessed: done,
            totalNodes: batch.length,
          ),
        );
        final ok = await _analyzeOne(game);
        done++;
        if (ok) {
          consecutiveFailures = 0;
          notifyListeners(); // the pane repaints this row's summary chip
        } else if (!_cancelled) {
          consecutiveFailures++;
          if (consecutiveFailures >= _maxConsecutiveFailures) {
            job.fail('Engine unavailable — analysis skipped');
            break;
          }
        }
      }
      job.updateProgress(
        JobProgress(
          fraction: 1,
          message: 'Done',
          nodesProcessed: done,
          totalNodes: batch.length,
        ),
      );
    } finally {
      _running = false;
      _active = null;
      EngineLifecycle.instance.releasePool();
      if (job.isActive) {
        job.updateStatus(
          _cancelled ? JobStatus.cancelled : JobStatus.completed,
        );
      }
      notifyListeners();
    }
  }

  Future<bool> _analyzeOne(RecentGame game) async {
    // Headless controller: no listeners, and deliberately never disposed on
    // the success path — dispose() calls cancel(), which stops *all* pool
    // searches and would kill a viewer analysis running concurrently.
    final controller = _active = GameAnalysisController();
    String? annotated;
    try {
      await controller.analyzeGame(
        game.record.pgn,
        onAnnotatedMovetext: (text) => annotated = text,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[GameAutoAnalysis] ${game.record.dedupKey}: $e');
      }
    }
    // analyzeGame only reports the annotated movetext after an uncancelled,
    // complete pass — so a null here means failure (or cancellation).
    final movetext = annotated;
    if (movetext == null || _cancelled) return false;

    final patched = await GamesLibraryService.patchGameMovetext(
      cachePath: game.cachePath,
      dedupKey: game.record.dedupKey,
      updatedMovetext: movetext,
    );
    if (!patched && kDebugMode) {
      debugPrint(
        '[GameAutoAnalysis] could not patch ${game.record.dedupKey} '
        'into ${game.cachePath}',
      );
    }
    final meWhite = game.meWhite;
    if (meWhite != null) {
      game.summary = summaryFromEvals(controller.evals, meWhite: meWhite);
    }
    return true;
  }
}
