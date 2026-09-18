@Timeout(Duration(seconds: 35))
library;

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_import_controller.dart';
import 'package:chess_auto_prep/features/studies/models/study_document.dart';
import 'package:chess_auto_prep/features/studies/repositories/study_import_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/screens/study_screen.dart';
import 'package:chess_auto_prep/widgets/study/study_chapter_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/board_engine_fixture.dart';
import '../support/runtime_settings.dart';
import '../support/scripted_document_store.dart';
import '../support/study_fixture.dart';

class _UnusedImports implements StudyImportRepository, StudyImportJobs {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboard;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    useScriptedBoardEngine();
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<StudyController> host(WidgetTester tester, bool compact) async {
    tester.view.physicalSize = Size(compact ? 900 : 1500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = Store()
      ..current = snapshot('[Event "First"]\n\n1. e4 {First note} *');
    store.onSave = (before, content) async {
      final after = store.current = snapshot(content, path: before.path);
      return PgnSaved(before: before, after: after);
    };
    final study = StudyController(
      library: MemoryStudyLibrary(),
      documents: store,
      decode: (content, name, path) async =>
          StudyDocument.fromPgn(content, name: name, filePath: path),
      autoSaveDelay: const Duration(hours: 1),
    );
    await study.openStudy('/main.pgn');
    study.addChapter('Second');
    study.playSan('d4');
    study.setComment(study.path, 'Second note');
    study.selectChapter(0);
    final imports = _UnusedImports();
    final importer = StudyImportController(
      documents: store,
      repository: imports,
      jobs: imports,
    );
    final settings = testRuntimeSettings();
    final app = AppState()..setMode(AppMode.study);
    addTearDown(() {
      study.dispose();
      importer.dispose();
      settings.dispose();
      app.dispose();
    });
    await pumpRuntimeWidget(
      tester,
      settings,
      MultiProvider(
        providers: [
          ChangeNotifierProvider<StudyController>.value(value: study),
          ChangeNotifierProvider<StudyImportController>.value(value: importer),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const StudyScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return study;
  }

  Future<void> openAction(WidgetTester tester, String action) async {
    await tester.tap(find.byTooltip('Chapter actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  for (final compact in [false, true]) {
    final layout = compact ? 'compact' : 'wide';
    testWidgets('$layout copies the menu chapter after pre-frame reorder', (
      tester,
    ) async {
      final study = await host(tester, compact);
      final expected = study.chapterPgn(0);
      await tester.tap(find.byTooltip('Chapter actions').first);
      await tester.pumpAndSettle();
      study.reorderChapter(0, 1);
      await tester.tap(find.text('Copy chapter PGN'));
      await tester.pumpAndSettle();
      expect(clipboard, expected);
      expect(tester.takeException(), isNull);
      await study.flushSave();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$layout ignores a removed chapter in an open menu', (
      tester,
    ) async {
      final study = await host(tester, compact);
      clipboard = 'unchanged';
      await tester.tap(find.byTooltip('Chapter actions').first);
      await tester.pumpAndSettle();
      study.deleteChapter(0);
      await tester.tap(find.text('Copy chapter PGN'));
      await tester.pumpAndSettle();
      expect(clipboard, 'unchanged');
      expect(study.chapterList.chapters.single.name, 'Second');
      expect(tester.takeException(), isNull);
      await study.flushSave();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$layout clear confirmation follows a reordered chapter', (
      tester,
    ) async {
      final study = await host(tester, compact);
      await openAction(tester, 'Clear comments, glyphs and shapes…');
      study.reorderChapter(0, 1);
      await tester.tap(find.widgetWithText(TextButton, 'Clear'));
      await tester.pumpAndSettle();
      expect(study.chapterPgn(0), contains('Second note'));
      expect(study.chapterPgn(1), isNot(contains('First note')));
      expect(tester.takeException(), isNull);
      await study.flushSave();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$layout delete confirmation cannot mutate a replacement', (
      tester,
    ) async {
      final study = await host(tester, compact);
      await openAction(tester, 'Delete chapter…');
      await study.newStudy('Replacement');
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(study.title.name, 'Replacement');
      expect(study.chapterList.chapters, hasLength(1));
      await tester.tap(find.byTooltip('Chapter actions').first);
      await tester.pumpAndSettle();
      final delete = tester.widget<PopupMenuItem<ChapterAction>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is PopupMenuItem<ChapterAction> &&
              widget.value == ChapterAction.delete,
        ),
      );
      expect(delete.enabled, isFalse);
      expect(tester.takeException(), isNull);
      await study.flushSave();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
