import 'dart:async';
import 'dart:convert';

import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/audit/controllers/audit_session_controller.dart';
import 'package:chess_auto_prep/features/audit/services/audit_config.dart';
import 'package:chess_auto_prep/features/audit/services/repertoire_audit_service.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/jobs/generation_phase.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/widgets/layout/jobs_panel.dart';
import 'package:chess_auto_prep/widgets/generation/snapshot_export_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/fake_storage.dart';
import '../support/generation_artifacts_fixture.dart';
import '../support/generation_publication_fixture.dart';
import '../support/runtime_settings.dart';

class _Storage extends MemoryStorage {
  @override
  Future<String> repertoireFilePath(String name) async => '/reps/$name.pgn';
}

/// UI dispatch fixture; pipeline/receipt behavior stays covered by the actual
/// GenerationSessionController and SnapshotExporter suites.
class _Generation extends GenerationSessionController {
  _Generation(JobManager jobs, RuntimeSettings settings)
    : super(
        databases: settings.databases,
        jobs: jobs,
        publication: generationPublicationFixture(),
        artifacts: generationArtifactsFixture(),
        enginePool: testEngines(settings).pool,
        engineLifecycle: testEngines(settings).lifecycle,
      );

  RepertoireJob? job;
  bool paused = false;
  bool cancelling = false;
  bool exporting = false;
  final calls = <String>[];
  Completer<(bool, String)>? exportCompletion;
  ({String name, bool verify})? exportChoice;
  @override
  bool get isGenerating => job != null;
  @override
  RepertoireJob? get currentJob => job;
  @override
  bool get isPaused => paused;
  @override
  bool get isCancelling => cancelling;
  @override
  bool get isSnapshotExporting => exporting;
  @override
  String? get snapshotStatus => exporting ? 'Writing snapshot' : null;
  @override
  String snapshotNameSuggestion() => 'Suggested copy';
  @override
  void pauseBuild() {
    calls.add('pause');
    paused = true;
    notifyListeners();
  }

  @override
  void resumeBuild() {
    calls.add('resume');
    paused = false;
    notifyListeners();
  }

  @override
  void cancelBuild() {
    calls.add('cancel');
    cancelling = true;
    notifyListeners();
  }

  @override
  void finishNow() => calls.add('finish');
  @override
  Future<(bool, String)> exportSnapshot({
    required String repertoireName,
    required bool verify,
  }) async {
    exportChoice = (name: repertoireName, verify: verify);
    exporting = true;
    notifyListeners();
    final result = await exportCompletion!.future;
    exporting = false;
    notifyListeners();
    return result;
  }
}

void main() {
  late RuntimeSettings settings;
  late JobManager jobs;
  late _Generation generation;
  late AuditSessionController audit;
  late _Storage storage;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    settings = testRuntimeSettings();
    jobs = JobManager();
    generation = _Generation(jobs, settings);
    audit = AuditSessionController(
      service: RepertoireAuditService(pool: testEngines(settings).pool),
      prepareEngine: () async {},
      releaseEngine: () async {},
    );
    storage = _Storage();
    StorageFactory.instanceForTest = storage;
  });
  tearDown(() {
    generation.dispose();
    audit.dispose();
    jobs.dispose();
    settings.dispose();
    StorageFactory.instanceForTest = null;
  });

  Future<void> pump(WidgetTester tester, {List<String>? navigation}) async {
    tester.view.physicalSize = const Size(1400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      Provider<StockfishPool>.value(
        value: testEngines(settings).pool,
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: JobsPanel(
              jobManager: jobs,
              generationController: generation,
              auditController: audit,
              onOpenGenerationDialog: () => navigation?.add('generation'),
              onOpenAuditDialog: () => navigation?.add('audit'),
              onOpenCoverageDialog: () => navigation?.add('coverage'),
            ),
          ),
        ),
      ),
    );
  }

  void startGeneration() {
    generation.job = jobs.createJob(type: JobType.generation, label: 'Build A')
      ..updateStatus(JobStatus.running);
    generation.activeConfig = const TreeBuildConfig(
      startFen: kStandardStartFen,
      playAsWhite: true,
    );
    generation.progress.setStatus('Building', GenerationPhase.buildingTree);
  }

  testWidgets(
    'empty navigation and live completed jobs update without a parent rebuild',
    (tester) async {
      final navigation = <String>[];
      await pump(tester, navigation: navigation);
      for (final label in ['Generate', 'Audit', 'Coverage']) {
        await tester.tap(find.text(label));
      }
      expect(navigation, ['generation', 'audit', 'coverage']);
      final job = jobs.createJob(
        type: JobType.studyImport,
        label: 'Imported study',
      );
      job.updateStatus(JobStatus.completed);
      await tester.pump();
      expect(find.text('Imported study'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(find.text('No active jobs'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      jobs.createJob(type: JobType.studyImport, label: 'After unmount');
      audit.onProgress(1, 2);
      generation.progress.update(nodes: 42);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('audit controls update and cancel the owned restored source', (
    tester,
  ) async {
    await audit.tryRestore('/reps/A.pgn');
    audit.onConfigChanged(const AuditConfig(useStockfish: false));
    audit.onAuditingChanged(true, jobs, 'Audit A');
    await pump(tester);
    audit.onProgress(2, 8);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2 / 8 positions checked'), findsOneWidget);
    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(audit.isPaused, isTrue);
    await tester.tap(find.text('Resume'));
    await tester.pump();
    expect(audit.isPaused, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(audit.isAuditing, isFalse);
    expect(jobs.jobs.single.status, JobStatus.cancelled);
    final saved = jsonDecode(storage.files['/reps/A_audit.json']!) as Map;
    expect(saved['isComplete'], isFalse);
    expect(saved['result']['nodesChecked'], 2);
    expect(storage.files.keys, ['/reps/A_audit.json']);
  });

  testWidgets('generation controls retain phase and cancellation gating', (
    tester,
  ) async {
    startGeneration();
    await pump(tester);
    await tester.tap(find.text('Pause'));
    await tester.pump();
    await tester.tap(find.text('Resume'));
    await tester.pump();
    await tester.tap(find.text('Finish Now'));
    expect(generation.calls, ['pause', 'resume', 'finish']);
    generation.progress.setStatus('Exporting', GenerationPhase.extractingLines);
    await tester.pump(const Duration(seconds: 1));
    for (final label in ['Pause', 'Finish Now', 'Export Lines']) {
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed,
        isNull,
      );
    }
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(generation.calls.last, 'cancel');
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancelling…'))
          .onPressed,
      isNull,
    );
  });

  for (final duplicateSubmit in [false, true]) {
    testWidgets(
      duplicateSubmit
          ? 'snapshot keyboard submit does not start a second pending lookup'
          : 'canceled snapshot lookup cannot pop the underlying route',
      (tester) async {
        await pump(tester);
        final navigator = Navigator.of(tester.element(find.byType(JobsPanel)));
        unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('Keep this page')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final pending = Completer<void>();
        var checks = 0;
        storage.beforeExists = (_) async {
          checks++;
          await pending.future;
        };
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        final result = showSnapshotExportDialog(
          tester.element(find.text('Keep this page')),
          suggestedName: 'Pending copy',
          canVerify: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Export'));
        await tester.pump();
        expect(checks, 1);
        if (duplicateSubmit) {
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pump();
          expect(
            checks,
            1,
            reason:
                'A second keyboard submit must not overlap the first lookup.',
          );
        }
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        // The dialog's State remains mounted during its reverse animation.
        await tester.pump();
        pending.complete();
        await tester.pumpAndSettle();
        expect(await result, isNull);
        expect(find.text('Keep this page'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('snapshot input remains alive through the closing animation', (
    tester,
  ) async {
    await pump(tester);
    final result = showSnapshotExportDialog(
      tester.element(find.byType(JobsPanel)),
      suggestedName: 'Retained input',
      canVerify: true,
      verifyDepth: 18,
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Edited input');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'snapshot dialog cancel and failure preserve name, verify and busy state',
    (tester) async {
      startGeneration();
      await pump(tester);
      await tester.tap(find.text('Export Lines'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Suggested copy'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(generation.exportChoice, isNull);
      generation.exportCompletion = Completer<(bool, String)>();
      await tester.tap(find.text('Export Lines'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(find.byType(TextField), 'My copy');
      await tester.tap(find.text('Verify with engine before export'));
      await tester.tap(find.widgetWithText(FilledButton, 'Export'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(generation.exportChoice, (name: 'My copy', verify: false));
      expect(find.text('Writing snapshot'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Export Lines'))
            .onPressed,
        isNull,
      );
      generation.exportCompletion!.complete((false, 'Snapshot write failed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Snapshot write failed'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Export Lines'))
            .onPressed,
        isNotNull,
      );
      expect(generation.isGenerating, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
