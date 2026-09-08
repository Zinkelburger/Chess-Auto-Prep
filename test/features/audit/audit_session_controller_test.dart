/// [AuditSessionController] state machine: launch/finish bookkeeping,
/// pause/resume/cancel, what a cancel and a repertoire switch persist and
/// where, restoring (including the switch-during-load race), and a resume
/// run end to end with every engine source off.
library;

import 'dart:async';
import 'dart:convert';

import 'package:chess_auto_prep/features/audit/controllers/audit_session_controller.dart';
import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/models/audit_result.dart';
import 'package:chess_auto_prep/features/audit/services/audit_config.dart';
import 'package:chess_auto_prep/features/audit/services/audit_persistence.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/hunt_harness.dart';

class _MemoryStorage implements StorageService {
  final Map<String, String> files = {};

  /// A read of one of these paths waits for its completer.
  final Map<String, Completer<void>> gates = {};

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<String?> readFile(String path) async {
    final gate = gates[path];
    if (gate != null) await gate.future;
    return files[path];
  }

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    files[path] = content;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

const _a = '/reps/A/Main.pgn';
const _aJson = '/reps/A/Main_audit.json';
const _b = '/reps/B/Main.pgn';
const _bJson = '/reps/B/Main_audit.json';
const _fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

/// Every source off, so a resume run touches no engine, model or network.
const _quiet = AuditConfig(
  useStockfish: false,
  useMaia: false,
  useLichessDb: false,
  useChessDb: false,
);

AuditFinding _finding(String move) => AuditFinding(
  type: AuditFindingType.missingResponse,
  severity: AuditSeverity.warning,
  movePath: const ['e4'],
  fen: _fen,
  missingMove: move,
);

AuditResult _result(List<AuditFinding> findings, {int nodes = 3}) =>
    AuditResult(
      findings: findings,
      nodesChecked: nodes,
      ourMoveNodesChecked: 1,
      opponentNodesChecked: 1,
      leafNodesChecked: 1,
      elapsed: const Duration(seconds: 1),
    );

/// Let unawaited persistence writes land.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryStorage storage;
  late AuditSessionController controller;
  final jobs = JobManager.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EngineLifecycle.testMode = true;
    storage = _MemoryStorage();
    StorageFactory.instanceForTest = storage;
    controller = AuditSessionController();
  });

  tearDown(() {
    controller.dispose();
    for (final job in jobs.jobs.toList()) {
      jobs.removeJob(job);
    }
    StorageFactory.instanceForTest = null;
    EngineLifecycle.testMode = false;
  });

  AuditSnapshot snapshotAt(String path) => AuditSnapshot.fromJson(
    jsonDecode(storage.files[path]!) as Map<String, dynamic>,
  );

  void startAudit({AuditConfig config = _quiet}) {
    controller.onConfigChanged(config);
    controller.onAuditingChanged(true, jobs, 'A');
  }

  group('launch and finish', () {
    test('starting clears the previous result and opens one job', () {
      controller.onResultChanged(_result([_finding('Nf6')]), null);
      expect(controller.hasResults, isTrue);

      startAudit();

      expect(controller.isAuditing, isTrue);
      expect(controller.result, isNull);
      expect(controller.liveFindings, isEmpty);
      expect(controller.nodesChecked, 0);
      expect(controller.totalNodes, 0);
      final job = controller.currentJob!;
      expect(job.type, JobType.audit);
      expect(job.label, 'A');
      expect(job.status, JobStatus.running);
      expect(job.configSnapshot, _quiet.toMap());

      // A repeated "auditing" signal must not open a second job.
      controller.onAuditingChanged(true, jobs, 'A');
      expect(identical(controller.currentJob, job), isTrue);
      expect(jobs.jobs.length, 1);

      controller.onAuditingChanged(false, jobs, 'A');
      expect(controller.isAuditing, isFalse);
      expect(controller.currentJob, isNull);
      expect(job.status, JobStatus.completed);
    });

    test('live findings and progress feed the job', () {
      startAudit();
      controller.onLiveFinding(_finding('Nf6'));
      controller.onLiveFinding(_finding('d5'));
      controller.onProgress(4, 8);

      expect(controller.liveFindings.map((f) => f.missingMove), ['Nf6', 'd5']);
      expect(controller.activeFindingCount, 2);
      expect(controller.hasResults, isTrue);
      expect(controller.nodesChecked, 4);
      expect(controller.totalNodes, 8);
      final progress = controller.currentJob!.progress;
      expect(progress.fraction, 0.5);
      expect(progress.nodesProcessed, 4);
      expect(progress.totalNodes, 8);
    });

    test('a result replaces live findings and is saved complete', () async {
      startAudit();
      controller.onLiveFinding(_finding('Nf6'));

      controller.onResultReady(_result([_finding('d5')]), _a);
      await settle();

      expect(controller.liveFindings, isEmpty);
      expect(controller.result!.findings.single.missingMove, 'd5');
      final snap = snapshotAt(_aJson);
      expect(snap.isComplete, isTrue);
      expect(snap.result.findings.single.missingMove, 'd5');
      expect(snap.config.useChessDb, isFalse);
    });

    test('a result with no known config is kept but not saved', () async {
      controller.onResultReady(_result([_finding('d5')]), _a);
      await settle();
      expect(controller.result, isNotNull);
      expect(storage.files, isEmpty);
    });

    test('dismissals count against active findings', () {
      final f = _finding('Nf6')..dismissed = true;
      controller.onResultChanged(_result([f, _finding('d5')]), null);
      expect(controller.activeFindingCount, 1);
    });
  });

  group('pause, resume, cancel', () {
    test('pause and resume are no-ops outside a run', () {
      controller.pause();
      expect(controller.isPaused, isFalse);
      controller.resume();
      expect(controller.isPaused, isFalse);
      controller.cancel(_a);
      expect(storage.files, isEmpty);
    });

    test('pause parks the job and resume releases it', () {
      startAudit();
      final job = controller.currentJob!;

      controller.pause();
      expect(controller.isPaused, isTrue);
      expect(job.status, JobStatus.paused);

      controller.pause();
      expect(controller.isPaused, isTrue, reason: 'idempotent');

      controller.resume();
      expect(controller.isPaused, isFalse);
      expect(job.status, JobStatus.running);
    });

    test(
      'cancel saves an interrupted snapshot with the live findings',
      () async {
        startAudit();
        controller.onLiveFinding(_finding('Nf6'));
        controller.onProgress(2, 8);
        final job = controller.currentJob!;

        controller.cancel(_a);
        await settle();

        expect(controller.isAuditing, isFalse);
        expect(controller.isPaused, isFalse);
        expect(controller.currentJob, isNull);
        expect(job.status, JobStatus.cancelled);
        // Live findings stay on screen after a cancel.
        expect(controller.liveFindings.length, 1);

        final snap = snapshotAt(_aJson);
        expect(snap.isComplete, isFalse);
        expect(snap.result.findings.single.missingMove, 'Nf6');
        expect(snap.result.nodesChecked, 2);
        expect(snap.config.useChessDb, isFalse);
      },
    );

    test('cancelling a paused run clears the pause', () {
      startAudit();
      controller.pause();
      controller.cancel(_a);
      expect(controller.isPaused, isFalse);
      expect(controller.isAuditing, isFalse);
    });

    test('progress is not saved when no config was ever given', () async {
      controller.onAuditingChanged(true, jobs, 'A');
      controller.onLiveFinding(_finding('Nf6'));
      controller.cancel(_a);
      await settle();
      expect(storage.files, isEmpty);
    });
  });

  group('repertoire switch', () {
    test('mid-run: progress goes to the old file, state is cleared', () async {
      startAudit();
      controller.onLiveFinding(_finding('Nf6'));
      final job = controller.currentJob!;

      controller.onRepertoireSwitching(_a);
      await settle();

      expect(controller.isAuditing, isFalse);
      expect(controller.currentJob, isNull);
      expect(job.status, JobStatus.cancelled);
      expect(controller.result, isNull);
      expect(controller.liveFindings, isEmpty);
      expect(controller.hasResults, isFalse);
      expect(controller.activeRepertoireId, isNull);

      expect(storage.files.keys, [_aJson]);
      final snap = snapshotAt(_aJson);
      expect(snap.isComplete, isFalse);
      expect(snap.result.findings.single.missingMove, 'Nf6');
    });

    test('idle: nothing is written, state is cleared', () async {
      controller.onResultChanged(_result([_finding('Nf6')]), null);
      controller.onRepertoireSwitching(_a);
      await settle();
      expect(storage.files, isEmpty);
      expect(controller.hasResults, isFalse);
    });

    // BUG: the audit run belongs to the config panel, which hands its
    // result to `onResultReady` with whatever repertoire path the screen
    // has *now*. After a switch mid-run, the old repertoire's partial
    // findings arrive as the new repertoire's complete audit: they replace
    // the state `tryRestore` just loaded for B and are written to B's
    // `_audit.json`. The controller has no way to tell that result from a
    // fresh one, so a fix needs the panel to tag results with the run they
    // came from (or the controller to own the run).
    test(
      'a result from the run cancelled by the switch is not adopted',
      () async {
        startAudit();
        controller.onLiveFinding(_finding('Nf6'));
        controller.onRepertoireSwitching(_a);
        storage.files[_bJson] = jsonEncode(
          AuditSnapshot(
            result: _result([_finding('c5')]),
            config: _quiet,
          ).toJson(),
        );
        await controller.tryRestore(_b);
        expect(controller.result!.findings.single.missingMove, 'c5');

        // ...and then A's cancelled run returns through the panel.
        controller.onResultReady(_result([_finding('Nf6')]), _b);
        await settle();

        expect(controller.result!.findings.single.missingMove, 'c5');
        expect(snapshotAt(_bJson).result.findings.single.missingMove, 'c5');
      },
      skip: 'documents bug: stale result of A overwrites B after a switch',
    );
  });

  group('tryRestore', () {
    test('a complete snapshot becomes the result', () async {
      storage.files[_aJson] = jsonEncode(
        AuditSnapshot(
          result: _result([_finding('Nf6')], nodes: 7),
          config: _quiet.copyWith(mistakeThresholdCp: 77),
        ).toJson(),
      );

      await controller.tryRestore(_a);

      expect(controller.activeRepertoireId, _a);
      expect(controller.result!.findings.single.missingMove, 'Nf6');
      expect(controller.interruptedSnapshot, isNull);
      expect(controller.lastConfig!.mistakeThresholdCp, 77);
      expect(controller.nodesChecked, 7);
      expect(controller.totalNodes, 7);
    });

    test('an interrupted snapshot is offered for resume', () async {
      storage.files[_aJson] = jsonEncode(
        AuditSnapshot(
          result: _result([_finding('Nf6')]),
          config: _quiet,
          checkedFens: {_fen},
          isComplete: false,
        ).toJson(),
      );

      await controller.tryRestore(_a);

      expect(controller.interruptedSnapshot, isNotNull);
      expect(controller.interruptedSnapshot!.checkedFens, {_fen});
      expect(controller.hasResults, isTrue);

      controller.clearInterrupted();
      expect(controller.interruptedSnapshot, isNull);
      expect(controller.result, isNotNull, reason: 'findings stay');

      controller.startFresh();
      expect(controller.result, isNull);
      expect(controller.hasResults, isFalse);
    });

    test('no file clears whatever was showing', () async {
      controller.onResultChanged(_result([_finding('Nf6')]), null);
      await controller.tryRestore(_a);
      expect(controller.result, isNull);
      expect(controller.hasResults, isFalse);
    });

    test('a load that finishes after another switch is discarded', () async {
      storage.files[_aJson] = jsonEncode(
        AuditSnapshot(
          result: _result([_finding('a')]),
          config: _quiet,
        ).toJson(),
      );
      storage.files[_bJson] = jsonEncode(
        AuditSnapshot(
          result: _result([_finding('b')]),
          config: _quiet,
        ).toJson(),
      );
      final gateA = storage.gates[_aJson] = Completer<void>();

      final loadA = controller.tryRestore(_a);
      await controller.tryRestore(_b);
      expect(controller.result!.findings.single.missingMove, 'b');

      gateA.complete();
      await loadA;

      expect(controller.activeRepertoireId, _b);
      expect(
        controller.result!.findings.single.missingMove,
        'b',
        reason: 'A finished loading after the user had moved on to B',
      );
    });
  });

  group('launchResume', () {
    late OpeningTree tree;

    setUpAll(() async {
      tree = await OpeningTreeBuilder.buildTree(
        pgnList: const ['[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 *'],
        username: '',
        userIsWhite: true,
        strictPlayerMatching: false,
        maxDepth: 10,
      );
      await clearEvalCache();
    });

    test('walks the rest of the tree and saves a complete result', () async {
      final prior = _finding('Nf6');
      final snapshot = AuditSnapshot(
        result: _result([prior], nodes: 2),
        config: _quiet.copyWith(mistakeThresholdCp: 55),
        checkedFens: {tree.root.fen, tree.root.children['e4']!.fen},
        isComplete: false,
      );
      final notifications = <bool>[];
      controller.addListener(() => notifications.add(controller.isAuditing));

      final run = controller.launchResume(
        snapshot: snapshot,
        tree: tree,
        isWhiteRepertoire: true,
        jobManager: jobs,
        repertoireLabel: 'A',
        repertoireFilePath: _a,
      );
      expect(controller.isAuditing, isTrue);
      expect(controller.interruptedSnapshot, isNull);
      final job = controller.currentJob!;
      expect(job.label, 'A (resumed)');
      expect(job.status, JobStatus.running);
      await run;

      expect(controller.isAuditing, isFalse);
      expect(controller.currentJob, isNull);
      expect(job.status, JobStatus.completed);
      expect(controller.lastConfig!.mistakeThresholdCp, 55);
      expect(notifications.first, isTrue);
      expect(notifications.last, isFalse);

      final result = controller.result!;
      // root, e4, e5, Nf3, Nc6: skipped nodes still count as walked.
      expect(result.nodesChecked, 5);
      expect(identical(result.findings.single, prior), isTrue);
      expect(controller.liveFindings, isEmpty);
      expect(controller.totalNodes, 5);

      final saved = snapshotAt(_aJson);
      expect(saved.isComplete, isTrue);
      expect(saved.result.findings.single.missingMove, 'Nf6');
      expect(saved.config.mistakeThresholdCp, 55);
    });
  });

  test('clearAll forgets everything including the config', () {
    startAudit();
    controller.onLiveFinding(_finding('Nf6'));
    controller.onAuditingChanged(false, jobs, 'A');
    controller.onResultReady(_result([_finding('d5')]), null);

    controller.clearAll();

    expect(controller.result, isNull);
    expect(controller.liveFindings, isEmpty);
    expect(controller.lastConfig, isNull);
    expect(controller.hasResults, isFalse);
    expect(controller.nodesChecked, 0);
  });
}
