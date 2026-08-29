/// Session controller for repertoire coverage analysis.
///
/// Owns the observable coverage state: result, progress, and running flag.
/// The screen initiates analysis via [calculate] and listens for updates.
library;

import 'package:flutter/foundation.dart';

import '../../../models/opening_tree.dart';
import '../../../services/jobs/notify_throttle.dart';
import '../../../services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/features/coverage/models/coverage_config.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../../../utils/safe_change_notifier.dart';

class CoverageController extends ChangeNotifier with SafeChangeNotifier {
  /// Progress arrives per tree node; the screen hears about it a few times
  /// a second.  Terminal states flush so a finished run lands at once.
  late final NotifyThrottle _progressNotify = NotifyThrottle(notifyListeners);

  @override
  void dispose() {
    _progressNotify.dispose();
    super.dispose();
  }

  CoverageResult? _result;
  bool _isRunning = false;
  double? _progress;
  String? _progressMessage;

  CoverageResult? get result => _result;
  bool get isRunning => _isRunning;
  double? get progress => _progress;
  String? get progressMessage => _progressMessage;

  void clear() {
    _result = null;
    notifyListeners();
  }

  /// One-line outcome shared by the jobs card and the completion snackbar.
  static String summarize(CoverageResult result) =>
      '${result.coveragePercent.toStringAsFixed(1)}% covered, '
      '${result.tooShallowLeaves.length} shallow, '
      '${result.tooDeepLeaves.length} deep, '
      '${result.unaccountedMoves.length} unaccounted';

  /// Run coverage as a first-class job in [jobManager], so the run is visible
  /// in the Jobs pane alongside generation and audit. Progress and the final
  /// summary land on the job card; a failure fails the job and rethrows so
  /// the caller can surface it.
  Future<CoverageResult?> runAsJob({
    required CoverageConfig config,
    required OpeningTree tree,
    required bool isWhiteRepertoire,
    required JobManager jobManager,
    required String label,
  }) async {
    final job = jobManager.createJob(type: JobType.coverage, label: label);
    job.updateStatus(JobStatus.running);
    try {
      final result = await calculate(
        config: config,
        tree: tree,
        isWhiteRepertoire: isWhiteRepertoire,
        onProgress: (message, progress) {
          job.updateProgress(
            JobProgress(fraction: progress ?? 0, message: message),
          );
        },
      );
      if (result != null) {
        job.updateProgress(
          JobProgress(fraction: 1, message: summarize(result)),
        );
      }
      job.updateStatus(JobStatus.completed);
      return result;
    } catch (e) {
      job.fail('$e');
      rethrow;
    }
  }

  /// Run coverage analysis. Returns the result, or null if the tree is null
  /// or an error occurs. Progress is reported via [notifyListeners] and,
  /// when provided, [onProgress] (used to drive the jobs-pane card).
  Future<CoverageResult?> calculate({
    required CoverageConfig config,
    required OpeningTree tree,
    required bool isWhiteRepertoire,
    void Function(String message, double? progress)? onProgress,
  }) async {
    _isRunning = true;
    _result = null;
    _progress = 0.0;
    _progressMessage = 'Starting analysis...';
    notifyListeners();

    final service = CoverageService(
      database: config.database,
      ratings: config.ratingsString,
      speeds: config.speedsString,
      useMaia: config.useMaia,
      maiaElo: config.maiaElo,
    );

    try {
      final coverageResult = await service.analyzeOpeningTree(
        tree,
        targetPercent: config.targetPercent,
        isWhiteRepertoire: isWhiteRepertoire,
        onProgress: (message, prog) {
          _progressMessage = message;
          _progress = prog;
          _progressNotify();
          onProgress?.call(message, prog);
        },
      );

      _result = coverageResult;
      _isRunning = false;
      _progress = null;
      _progressMessage = null;
      _progressNotify.flush();
      return coverageResult;
    } catch (e) {
      _isRunning = false;
      _progress = null;
      _progressMessage = null;
      _progressNotify.flush();
      rethrow;
    }
  }
}
