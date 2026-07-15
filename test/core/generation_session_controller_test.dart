// GenerationSessionController drives engines and isolates for real runs, so
// these tests cover only what is unit-testable without an engine: initial
// state, the generated-tree bundle lifecycle, resume-refusal plumbing in
// startBuild, progress updates with notify throttling, the idle guards on
// the control surface, and dispose safety.

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/jobs/generation_phase.dart';
import 'package:flutter_test/flutter_test.dart';

const _fenAfterE4 =
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

BuildTree _smallTree({
  String rootFen = kStandardStartFen,
  Map<String, dynamic> configSnapshot = const {},
}) {
  final root = BuildTreeNode(
    fen: rootFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: 0,
  )..engineEvalCp = 20;

  final e4 = BuildTreeNode(
    fen: _fenAfterE4,
    moveSan: 'e4',
    moveUci: 'e2e4',
    ply: 1,
    isWhiteToMove: false,
    nodeId: 1,
    parent: root,
  )..engineEvalCp = 25;
  root.children.add(e4);

  return BuildTree(root: root, configSnapshot: configSnapshot)
    ..computeMetadata();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initial state is idle with no tree and clean progress', () {
    final controller = GenerationSessionController();

    expect(controller.isGenerating, isFalse);
    expect(controller.isPaused, isFalse);
    expect(controller.isCancelling, isFalse);
    expect(controller.canPause, isFalse);
    expect(controller.isSnapshotExporting, isFalse);
    expect(controller.snapshotStatus, isNull);
    expect(controller.current, isNull);
    expect(controller.generatedTree, isNull);
    expect(controller.generatedTreeConfig, isNull);
    expect(controller.generatedTreeFenMap, isNull);
    expect(controller.currentJob, isNull);
    expect(controller.lastConfig, isNull);
    expect(controller.lastError, isNull);
    expect(controller.lastRunSummary, isEmpty);
    expect(controller.progressPhase, GenerationPhase.idle);
    expect(controller.progressStatus, isEmpty);
    expect(controller.progressNodes, 0);
    expect(controller.progressLines, 0);

    controller.dispose();
  });

  group('generated tree lifecycle', () {
    test('onTreeBuilt publishes the bundle and notifies', () {
      final controller = GenerationSessionController();
      var notified = 0;
      controller.addListener(() => notified++);

      final tree = _smallTree();
      controller.onTreeBuilt(tree);

      expect(controller.current, isNotNull);
      expect(controller.generatedTree, same(tree));
      expect(controller.generatedTreeFenMap, isNotNull);
      expect(controller.current!.snapshot.root.fen, kStandardStartFen);
      expect(notified, 1);

      controller.dispose();
    });

    test('onTreeBuilt reads play_as_white from the config snapshot', () {
      final controller = GenerationSessionController();

      controller.onTreeBuilt(
        _smallTree(configSnapshot: {'play_as_white': false}),
      );

      expect(controller.current!.snapshot.playAsWhite, isFalse);
      controller.dispose();
    });

    test('clearTree drops the bundle and notifies', () {
      final controller = GenerationSessionController();
      controller.onTreeBuilt(_smallTree());
      var notified = 0;
      controller.addListener(() => notified++);

      controller.clearTree();

      expect(controller.current, isNull);
      expect(controller.generatedTree, isNull);
      expect(notified, 1);
      controller.dispose();
    });
  });

  group('startBuild resume refusal', () {
    test(
      'a legacy partial tree from another position refuses cleanly',
      () async {
        final controller = GenerationSessionController();
        var notified = 0;
        controller.addListener(() => notified++);

        // The paused tree was built from the e4 position (with no recorded
        // move prefix), but the caller is resuming from the standard start.
        final request = GenerationRequest(
          config: const TreeBuildConfig(
            startFen: kStandardStartFen,
            playAsWhite: true,
          ),
          repertoireFilePath: '/nonexistent/rep.pgn',
          buildRootFen: kStandardStartFen,
          lineMovePrefix: const [],
          repertoireStartFen: kStandardStartFen,
          onLinesSaved: (_) {},
          existingTree: _smallTree(rootFen: _fenAfterE4),
        );

        await controller.startBuild(request);

        expect(controller.lastError, contains('Cannot resume'));
        expect(controller.lastRunSummary, contains('Cannot resume'));
        expect(controller.isGenerating, isFalse, reason: 'run never started');
        expect(controller.progressPhase, GenerationPhase.idle);
        expect(notified, 1);
        controller.dispose();
      },
    );
  });

  group('progress plumbing', () {
    test('updateProgress stores every field it is given', () {
      final controller = GenerationSessionController();

      controller.updateProgress(
        nodes: 42,
        depth: 5,
        maxPlyConfig: 18,
        unexploredAtDepth: 7,
        totalAtDepth: 12,
        lines: 3,
        nodesPerMinute: 60.5,
        elapsedMs: 1234,
      );

      expect(controller.progressNodes, 42);
      expect(controller.progressDepth, 5);
      expect(controller.progressMaxPlyConfig, 18);
      expect(controller.progressUnexploredAtDepth, 7);
      expect(controller.progressTotalAtDepth, 12);
      expect(controller.progressLines, 3);
      expect(controller.progressNodesPerMinute, 60.5);
      expect(controller.progressElapsedMs, 1234);
      controller.dispose();
    });

    test('rapid updates coalesce into a throttled trailing notify', () async {
      final controller = GenerationSessionController();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.updateProgress(nodes: 1);
      expect(notified, 1, reason: 'first update notifies immediately');

      controller.updateProgress(nodes: 2);
      expect(controller.progressNodes, 2, reason: 'state updates instantly');
      expect(notified, 1, reason: 'second notify is deferred');

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(notified, 2, reason: 'trailing timer flushed the notify');
      controller.dispose();
    });
  });

  group('idle guards', () {
    test('pause/resume/cancel/finishNow are no-ops when idle', () {
      final controller = GenerationSessionController();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.pauseBuild();
      controller.resumeBuild();
      controller.cancelBuild();

      expect(controller.isPaused, isFalse);
      expect(controller.isCancelling, isFalse);
      expect(controller.isGenerating, isFalse);
      expect(notified, 0, reason: 'guarded methods return before notifying');

      controller.finishNow();
      expect(controller.isGenerating, isFalse);
      controller.dispose();
    });

    test('exportSnapshot refuses without an active build', () async {
      final controller = GenerationSessionController();

      final (ok, message) = await controller.exportSnapshot(
        repertoireName: 'Snap',
        verify: false,
      );

      expect(ok, isFalse);
      expect(message, 'No active build to export from.');
      controller.dispose();
    });

    test('snapshotNameSuggestion falls back when no run is active', () {
      final controller = GenerationSessionController();
      expect(controller.snapshotNameSuggestion(), 'Generated d0 snapshot');
      controller.dispose();
    });
  });

  group('dispose safety', () {
    test('dispose cancels the pending throttle timer', () async {
      final controller = GenerationSessionController();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.updateProgress(nodes: 1); // immediate notify
      controller.updateProgress(nodes: 2); // schedules the trailing timer
      expect(notified, 1);

      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(notified, 1, reason: 'no notify after dispose');
    });

    test('late progress updates after dispose are swallowed', () async {
      final controller = GenerationSessionController();
      controller.dispose();

      // A straggling build callback landing after teardown must not throw:
      // SafeChangeNotifier drops the notification.
      controller.updateProgress(nodes: 99);
      expect(controller.progressNodes, 99);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
  });
}
