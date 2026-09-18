@Timeout(Duration(seconds: 45))
library;

import 'package:chess_auto_prep/features/studies/models/import_source.dart';
import 'package:chess_auto_prep/widgets/study/import_from_url_dialog.dart';

import 'package:chess_auto_prep/widgets/study/study_import_status_chip.dart';
import 'package:chess_auto_prep/features/documents/widgets/document_save_dialog.dart';
import 'package:chess_auto_prep/features/studies/models/study_document.dart';
import 'package:chess_auto_prep/features/studies/widgets/study_import_close_guard.dart';
import 'package:chess_auto_prep/features/documents/widgets/document_close_scope.dart';
import 'package:chess_auto_prep/features/documents/controllers/document_close_coordinator.dart';
import 'dart:async';
import 'package:chess_auto_prep/app/study_import_jobs.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/widgets/document_save_panel.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_import_controller.dart';
import 'package:chess_auto_prep/features/studies/models/study_import_state.dart';
import 'package:chess_auto_prep/features/studies/repositories/study_import_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations_en.dart';
import 'package:chess_auto_prep/screens/study_screen.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/widgets/app_overflow_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/runtime_settings.dart';
import '../support/scripted_document_store.dart';
import '../support/study_fixture.dart';

const _game = '[Event "Source"]\n\n1. e4 e5 *';

class _Imports implements StudyImportRepository {
  _Imports(this.publication);
  final StudyImportPublication publication;
  Future<StudyImportPublication> Function(String, String)? onPublish;
  @override
  Future<StudyImportPublication> publish(String name, String pgn) async =>
      onPublish == null ? publication : onPublish!(name, pgn);
  @override
  Future<String?> readCachedGame(String id) async => _game;
  @override
  Future<void> cacheGame(String id, String pgn) async {}
  @override
  StudyImportSource openSource() => _Source();
}

class _Source implements StudyImportSource {
  @override
  Future<FetchedStudy> fetchLichess(ImportSource source) async =>
      (pgn: _game, name: 'Downloaded');
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<
    ({
      StudyController study,
      StudyImportController importer,
      AppState app,
      Store store,
      DocumentCloseCoordinator close,
    })
  >
  host(
    WidgetTester tester, {
    bool dark = true,
    double scale = 1,
    bool isolated = false,
  }) async {
    tester.view.physicalSize = isolated
        ? const Size(480, 1000)
        : const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = Store()
      ..current = snapshot(_game, path: '/studies/Source.pgn');
    final study = StudyController(
      library: MemoryStudyLibrary(),
      documents: store,
      decode: (content, name, path) async =>
          StudyDocument.fromPgn(content, name: name, filePath: path),
      autoSaveDelay: const Duration(hours: 1),
    );
    await study.openStudy('/studies/Source.pgn');
    final imports = _Imports(
      StudyImportPublication(
        path: '/studies/Downloaded.pgn',
        content: _game,
        outcome: PgnWriteUncertain(
          error: StateError('ack lost'),
          before: null,
          observed: null,
        ),
      ),
    );
    final importer = StudyImportController(
      documents: store,
      repository: imports,
      jobs: RepertoireStudyImportJobs(
        JobManager.instance,
        AppLocalizationsEn.new,
      ),
    );
    final app = AppState()..setMode(AppMode.study);
    final settings = testRuntimeSettings();
    final close = DocumentCloseCoordinator();
    addTearDown(close.dispose);
    addTearDown(() {
      importer.dispose();
      study.dispose();
      app.dispose();
      settings.dispose();
    });
    await pumpRuntimeWidget(
      tester,
      settings,
      MultiProvider(
        providers: [
          Provider<StudyImportRepository>.value(value: imports),
          ChangeNotifierProvider<StudyController>.value(value: study),
          ChangeNotifierProvider<StudyImportController>.value(value: importer),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: DocumentCloseScope(
            coordinator: close,
            child: StudyImportCloseGuard(
              importer: importer,
              chooseCopyDestination: (_) async => '/chosen.pgn',
              child: isolated
                  ? Scaffold(
                      body: Center(
                        child: Builder(
                          builder: (context) => StudyImportStatusChip(
                            controller: importer,
                            onReview: () => showDocumentSaveDialog(
                              context,
                              title: AppLocalizations.of(
                                context,
                              ).studyImportReview,
                              session: importer.publicationRecovery!,
                              chooseCopyDestination: (_) async => '/copy.pgn',
                            ),
                          ),
                        ),
                      ),
                    )
                  : const StudyScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (
      study: study,
      importer: importer,
      app: app,
      store: store,
      close: close,
    );
  }

  Future<void> importLichess(WidgetTester tester, {bool append = false}) async {
    final menu = tester.widget<AppOverflowMenu>(
      find.byType(AppOverflowMenu).first,
    );
    menu.entries.singleWhere((e) => e.label == 'From URL…').onRun();
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(ImportFromUrlDialog),
            matching: find.byType(TextField),
          )
          .first,
      'https://lichess.org/study/abcdefgh',
    );
    await tester.pumpAndSettle();
    if (append) {
      await tester.tap(
        find.text('Add to the current study instead of creating a new one'),
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Import'));
    if (append) {
      // Chapter parsing runs on a real isolate. Alternate real scheduling with
      // fake-clock pumps so its response can reach the widget callback.
      final study = tester
          .element(find.byType(StudyScreen))
          .read<StudyController>();
      for (var i = 0; i < 100 && !study.dirty; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Lichess uncertain publication retains downloaded bytes and review',
    (tester) async {
      final f = await host(tester);
      await importLichess(tester);
      expect(f.importer.needsPublicationReview, isTrue);
      expect(f.importer.publicationRecovery!.state.content, _game);
      expect(
        f.importer.publicationRecovery!.state.path,
        '/studies/Downloaded.pgn',
      );
      expect(f.study.title.filePath, '/studies/Source.pgn');
      await tester.tap(find.byTooltip('Review downloaded study'));
      await tester.pumpAndSettle();
      expect(find.byType(DocumentSavePanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed Lichess append reports failure and keeps unsaved chapters',
    (tester) async {
      final f = await host(tester);
      f.store.onSave = (_, _) async => PgnWriteFailed(StateError('disk full'));
      await importLichess(tester, append: true);
      expect(f.study.chapterList.chapters, hasLength(2));
      expect(f.study.dirty, isTrue);
      expect(
        find.text(
          'Could not finish the import. Your existing work is preserved.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late publication reports its destination without opening over a newer study',
    (tester) async {
      final f = await host(tester);
      final imports =
          tester.element(find.byType(StudyScreen)).read<StudyImportRepository>()
              as _Imports;
      final pending = Completer<StudyImportPublication>();
      imports.onPublish = (_, _) => pending.future;
      // An indeterminate import indicator intentionally stays active until publication.
      final menu = tester.widget<AppOverflowMenu>(
        find.byType(AppOverflowMenu).first,
      );
      menu.entries.singleWhere((e) => e.label == 'From URL…').onRun();
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(ImportFromUrlDialog),
              matching: find.byType(TextField),
            )
            .first,
        'https://lichess.org/study/abcdefgh',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      f.store.onOpen = (path) async =>
          PgnOpened(snapshot('[Event "Unrelated"]\n\n1. d4 *', path: path));
      final opening = f.study.openStudy('/studies/Unrelated.pgn');
      await tester.pump();
      expect(await opening, isTrue);
      pending.complete(
        StudyImportPublication(
          path: '/studies/Downloaded.pgn',
          content: _game,
          outcome: PgnSaved(
            before: null,
            after: snapshot(_game, path: '/studies/Downloaded.pgn'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(f.study.title.filePath, '/studies/Unrelated.pgn');
      expect(
        find.text('Imported 1 games into “Downloaded” (0 unavailable).'),
        findsOneWidget,
      );
      expect(find.textContaining('Imported “Unrelated”'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final label in ['Train this chapter', 'Browse in PGN viewer']) {
    testWidgets('$label refuses a failed save', (tester) async {
      final f = await host(tester);
      f.store.onSave = (_, _) async => PgnWriteFailed(StateError('disk full'));
      f.study.setComment(TreePath.empty, 'Unsaved important note');
      final menu = tester.widget<AppOverflowMenu>(
        find.byType(AppOverflowMenu).first,
      );
      menu.entries.singleWhere((e) => e.label == label).onRun();
      await tester.pumpAndSettle();
      expect(f.store.saves, hasLength(1));
      expect(f.app.currentMode, AppMode.study);
      expect(f.study.state.dirty, isTrue);
      expect(f.study.doc.toPgn(), contains('Unsaved important note'));
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('$label ignores a save completed after the chapter changed', (
      tester,
    ) async {
      final f = await host(tester);
      f.study.addChapter('Other');
      f.study.selectChapter(0);
      final gate = Completer<PgnWriteResult>();
      f.store.onSave = (_, _) => gate.future;
      final menu = tester.widget<AppOverflowMenu>(
        find.byType(AppOverflowMenu).first,
      );
      menu.entries.singleWhere((e) => e.label == label).onRun();
      await tester.pump();
      f.study.selectChapter(1);
      gate.complete(
        PgnSaved(
          before: f.store.current,
          after: snapshot(
            f.study.doc.toPgn(),
            path: '/studies/Source.pgn',
            revision: '2',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(f.app.currentMode, AppMode.study);
      expect(f.study.chapterIndex, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('native close requires a decision for unresolved import bytes', (
    tester,
  ) async {
    final f = await host(tester);
    final run = f.importer.startCollectionDownload(
      gameIds: ['1'],
      studyName: 'Downloaded',
    );
    await tester.pumpAndSettle();
    await run;
    final closing = f.close.prepareClose();
    await tester.pumpAndSettle();
    expect(find.byType(DocumentSavePanel), findsOneWidget);
    expect(f.importer.publicationRecovery!.state.uncertain, isTrue);
    await tester.tap(find.text('Keep app open'));
    await tester.pumpAndSettle();
    expect((await closing).disposition, DocumentCloseDisposition.cancelled);
    expect(f.importer.needsPublicationReview, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final isolated in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
        'uncertain import exposes destination and copy recovery, dark=$dark isolated=$isolated',
        (tester) async {
          final f = await host(
            tester,
            dark: dark,
            scale: isolated ? 2 : 1.5,
            isolated: isolated,
          );
          final run = f.importer.startCollectionDownload(
            gameIds: ['1'],
            studyName: 'Downloaded',
          );
          await tester.pumpAndSettle();
          expect((await run).failure, StudyImportFailure.uncertainPublication);
          await tester.tap(find.byTooltip('Review downloaded study'));
          await tester.pumpAndSettle();
          expect(find.byType(DocumentSavePanel), findsOneWidget);
          expect(find.text('/studies/Downloaded.pgn'), findsOneWidget);
          final save = tester.widget<FilledButton>(
            find.byKey(const ValueKey('document-save')),
          );
          expect(
            save.onPressed,
            isNull,
            reason: 'uncertain writes cannot be retried blindly',
          );
          expect(
            find.byKey(const ValueKey('document-save-copy')),
            findsOneWidget,
          );
          expect(f.importer.publicationRecovery!.state.content, _game);
          expect(
            f.importer.publicationRecovery!.state.outcome,
            same(f.importer.lastResult!.publication!.outcome),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
