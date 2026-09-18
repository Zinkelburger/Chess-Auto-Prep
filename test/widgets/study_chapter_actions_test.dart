@Timeout(Duration(seconds: 35))
library;

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_import_controller.dart';
import 'package:chess_auto_prep/features/studies/models/study_document.dart';
import 'package:chess_auto_prep/features/studies/repositories/study_import_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/screens/study_screen.dart';
import 'package:chess_auto_prep/widgets/study/study_chapter_actions.dart';
import 'package:chess_auto_prep/widgets/study/study_picker_bar.dart';
import 'package:chess_auto_prep/features/documents/widgets/document_save_panel.dart';
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

class _NamedStudyLibrary extends MemoryStudyLibrary {
  @override
  Future<List<RepertoireMetadata>> list() async => [
    RepertoireMetadata(
      filePath: '/main.pgn',
      name: 'main',
      lastModified: DateTime(2026),
    ),
  ];
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

  Future<StudyController> host(
    WidgetTester tester,
    bool compact, {
    double? width,
    bool named = false,
    bool uncertainSave = false,
    double scale = 1,
    bool light = false,
  }) async {
    tester.view.physicalSize = Size(width ?? (compact ? 900 : 1500), 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = Store()
      ..current = snapshot('[Event "First"]\n\n1. e4 {First note} *');
    store.onSave = (before, content) async {
      if (uncertainSave) {
        return PgnWriteUncertain(
          error: StateError('acknowledgement lost'),
          before: before,
          observed: null,
        );
      }
      final after = store.current = snapshot(content, path: before.path);
      return PgnSaved(before: before, after: after);
    };
    final study = StudyController(
      library: named ? _NamedStudyLibrary() : MemoryStudyLibrary(),
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
          theme: light ? AppTheme.light() : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
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

  for (final scale in [1.0, 1.5]) {
    testWidgets('750px Study switch and rename at scale $scale', (
      tester,
    ) async {
      final study = await host(
        tester,
        true,
        width: 750,
        named: true,
        scale: scale,
      );
      expect(study.title.canRename, isTrue);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Switch study'));
      await tester.pumpAndSettle();
      expect(find.text('Switch study'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Rename study').last);
      await tester.pumpAndSettle();
      final editor = find.descendant(
        of: find.byType(StudyPickerBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(editor, 'Renamed study');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(study.title.name, 'Renamed study');
      expect(tester.takeException(), isNull);
      await study.flushSave();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('750px recovery preserves warning and keyboard access', (
    tester,
  ) async {
    final study = await host(tester, true, width: 750, uncertainSave: true);
    final button = find.byKey(const ValueKey('study-save-recovery'));
    expect(tester.widget(button), isA<IconButton>());
    expect(tester.widget<IconButton>(button).tooltip, 'Save and recovery…');
    expect(
      find.descendant(of: button, matching: find.byIcon(Icons.save_outlined)),
      findsOneWidget,
    );
    await study.save();
    await tester.pumpAndSettle();
    expect(study.state.uncertain, isTrue);
    final warning = find.descendant(
      of: button,
      matching: find.byIcon(Icons.warning_amber),
    );
    expect(warning, findsOneWidget);
    Focus.of(tester.element(warning)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(DocumentSavePanel), findsOneWidget);
    expect(study.state.uncertain, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final light in [false, true]) {
    testWidgets(
      'manager search, selection and dismissal at 200% (${light ? 'light' : 'dark'})',
      (tester) async {
        final study = await host(
          tester,
          true,
          width: 750,
          scale: 2,
          light: light,
        );
        study.renameChapter(
          1,
          'Second chapter with a very long descriptive title',
        );
        await openAction(tester, 'Manage & reorder chapters…');
        final dialog = find.byType(Dialog);
        final second = find.descendant(
          of: dialog,
          matching: find.text(
            'Second chapter with a very long descriptive title',
          ),
        );
        await tester.tap(second);
        await tester.pumpAndSettle();
        expect(study.chapterIndex, 1);
        expect(
          tester.widget<Text>(second).style!.color,
          (light ? AppTheme.light() : AppTheme.dark())
              .colorScheme
              .onPrimaryContainer,
        );
        expect(dialog, findsOneWidget);
        final search = find.descendant(
          of: dialog,
          matching: find.byType(TextField),
        );
        await tester.enterText(search, ' first ');
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: dialog,
            matching: find.byType(ReorderableListView),
          ),
          findsNothing,
        );
        expect(
          find.descendant(of: dialog, matching: find.text('First')),
          findsOneWidget,
        );
        expect(second, findsNothing);
        await tester.enterText(search, 'no match');
        await tester.pumpAndSettle();
        expect(find.text('No matching chapters'), findsOneWidget);
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: dialog,
            matching: find.byType(ReorderableListView),
          ),
          findsOneWidget,
        );
        expect(second, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        await openAction(tester, 'Manage & reorder chapters…');
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: dialog, matching: find.byType(TextField)),
              )
              .controller!
              .text,
          isEmpty,
        );
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(tester.takeException(), isNull);
        await study.flushSave();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('manager edit button retains chapter through pre-frame reorder', (
    tester,
  ) async {
    final study = await host(tester, true);
    await openAction(tester, 'Manage & reorder chapters…');
    final edit = tester.widget<IconButton>(
      find
          .byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == 'Edit chapter',
          )
          .first,
    );
    study.reorderChapter(0, 1);
    edit.onPressed!();
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'First');
    await tester.enterText(field, 'Edited original');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(study.chapterList.chapters.map((c) => c.name), [
      'Second',
      'Edited original',
    ]);
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await study.flushSave();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final replace in [false, true]) {
    testWidgets(
      'manager delete confirmation ${replace ? 'rejects replacement' : 'follows reorder'}',
      (tester) async {
        final study = await host(tester, true);
        await openAction(tester, 'Manage & reorder chapters…');
        await tester.tap(find.byTooltip('Delete chapter').first);
        await tester.pumpAndSettle();
        if (replace) {
          await study.newStudy('Replacement');
        } else {
          study.reorderChapter(0, 1);
        }
        await tester.tap(find.widgetWithText(TextButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(study.chapterList.chapters, hasLength(1));
        expect(
          study.chapterList.chapters.single.name,
          replace ? 'Chapter 1' : 'Second',
        );
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) =>
                      w is IconButton &&
                      w.tooltip == 'A study needs at least one chapter',
                ),
              )
              .onPressed,
          isNull,
        );
        expect(find.byType(Dialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await study.flushSave();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
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
