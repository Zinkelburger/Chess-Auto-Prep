/// CoverageController.runAsJob: the job lifecycle a coverage run drives in
/// the Jobs pane — created running, fed progress, completed with a summary,
/// or failed with the error. The analysis itself is scripted out.
library;

import 'package:chess_auto_prep/features/coverage/controllers/coverage_controller.dart';
import 'package:chess_auto_prep/features/coverage/models/coverage_config.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _OnProgress = void Function(String message, double? progress);

/// Replaces the real analysis with a script so tests control what the run
/// reports and how it ends.
class _ScriptedCoverageController extends CoverageController {
  _ScriptedCoverageController(this._script);

  final Future<CoverageResult?> Function(_OnProgress? onProgress) _script;

  @override
  Future<CoverageResult?> calculate({
    required CoverageConfig config,
    required OpeningTree tree,
    required bool isWhiteRepertoire,
    _OnProgress? onProgress,
  }) => _script(onProgress);
}

const _config = CoverageConfig(
  targetPercent: 80,
  useMaia: false,
  maiaElo: 1900,
);

CoverageResult _result() {
  return CoverageResult(
    rootFen: 'startpos',
    rootMoves: const ['e4'],
    rootGameCount: 1000,
    targetPercent: 80,
    targetGameCount: 800,
    coveredLeaves: const [],
    tooShallowLeaves: [
      LeafNode(
        fen: 'f1',
        moves: const ['e4', 'e5'],
        gameCount: 12,
        category: LeafCategory.tooShallow,
        reason: 'popular continuation not covered',
      ),
    ],
    tooDeepLeaves: const [],
    unaccountedMoves: const [],
    totalCoveredGames: 0,
    totalShallowGames: 12,
    totalDeepGames: 0,
    totalUnaccountedGames: 0,
  );
}

void main() {
  final jobManager = JobManager.instance;

  tearDown(() {
    for (final job in List.of(jobManager.jobs)) {
      jobManager.removeJob(job);
    }
  });

  Future<CoverageResult?> run(_ScriptedCoverageController controller) =>
      controller.runAsJob(
        config: _config,
        tree: OpeningTree(),
        isWhiteRepertoire: true,
        jobManager: jobManager,
        label: 'MyRep coverage',
      );

  test('a successful run completes the job with the summary message', () async {
    final controller = _ScriptedCoverageController((onProgress) async {
      onProgress?.call('Analyzing e4…', 0.5);
      return _result();
    });

    final result = await run(controller);

    expect(result, isNotNull);
    final job = jobManager.jobs.single;
    expect(job.type, JobType.coverage);
    expect(job.label, 'MyRep coverage');
    expect(job.status, JobStatus.completed);
    expect(job.progress.fraction, 1);
    expect(
      job.progress.message,
      '0.0% covered, 1 shallow, 0 deep, 0 unaccounted',
    );
    controller.dispose();
  });

  test('progress callbacks land on the job card as they arrive', () async {
    late RepertoireJob job;
    final controller = _ScriptedCoverageController((onProgress) async {
      job = jobManager.jobs.single;
      expect(job.status, JobStatus.running);
      onProgress?.call('Fetching root…', null);
      expect(job.progress.message, 'Fetching root…');
      expect(job.progress.fraction, 0); // null progress reads as 0
      onProgress?.call('Analyzing e4…', 0.5);
      expect(job.progress.fraction, 0.5);
      return null;
    });

    final result = await run(controller);

    // A null result still ends the job; there is just no summary to show.
    expect(result, isNull);
    expect(job.status, JobStatus.completed);
    controller.dispose();
  });

  test('a failed run fails the job and rethrows for the caller', () async {
    final controller = _ScriptedCoverageController(
      (_) async => throw StateError('explorer down'),
    );

    await expectLater(run(controller), throwsStateError);
    final job = jobManager.jobs.single;
    expect(job.status, JobStatus.failed);
    expect(job.error, contains('explorer down'));
    controller.dispose();
  });
}
