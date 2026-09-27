import 'package:provider/provider.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/repertoire/services/chapter_splitter.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'dart:io';
import 'dart:async';

import 'package:chess_auto_prep/features/repertoire/controllers/repertoire_outline_controller.dart';
import 'package:chess_auto_prep/features/repertoire/models/repertoire_outline.dart';
import 'package:chess_auto_prep/features/repertoire/services/repertoire_outline_service.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_outline_panel.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The outline panel against a real temp repertoire: what it lists, what a
/// tap reports, and that the context menu's rename actually renames the file.
String _game(String event, String moves) =>
    '[Event "$event"]\n[Result "*"]\n\n$moves *\n';

class _FailingDestinations extends NativePgnDocumentStore {
  Completer<PgnQuarantineResult>? deletion;
  final deletionEntered = Completer<void>();
  @override
  Future<PgnQuarantineResult> quarantine(
    PgnSnapshot before, {
    String? allowedRoot,
  }) {
    if (!deletionEntered.isCompleted) deletionEntered.complete();
    return deletion?.future ??
        super.quarantine(before, allowedRoot: allowedRoot);
  }

  bool fail = false;
  int creates = 0;
  @override
  Future<PgnWriteResult> create(String path, String content) async {
    if (fail && ++creates == 2) return PgnWriteFailed(StateError('disk full'));
    return super.create(path, content);
  }
}

void main() {
  late Directory tmp;
  late String root;
  late RepertoireOutlineController controller;
  late _FailingDestinations documents;
  late LegacyRepertoireCatalogRepository catalog;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('outline_panel_test');
    root = p.join(tmp.path, 'French');
    Directory(root).createSync();
    File(p.join(root, 'Advance.pgn')).writeAsStringSync(
      '// Color: Black\n\n'
      '${_game('Main line', '1. e4 e6 2. d4 d5 3. e5 c5')}\n'
      '${_game('Nh6 idea', '1. e4 e6 2. d4 d5 3. e5 c5 4. c3 Nc6 5. Nf3 Nh6')}\n',
    );
    Directory(p.join(root, 'Sidelines')).createSync();
    File(p.join(root, 'Sidelines', 'Exchange.pgn')).writeAsStringSync(
      '// Color: Black\n\n${_game('Exchange', '1. e4 e6 2. d4 d5 3. exd5')}\n',
    );
    final storage = IOStorageService(
      documentsRoot: tmp,
      supportRoot: tmp,
      repertoiresRoot: Directory(root),
    );
    documents = _FailingDestinations();
    catalog = LegacyRepertoireCatalogRepository(storage, documents: documents);
    controller = RepertoireOutlineController(
      catalog: catalog,
      service: RepertoireOutlineService(
        catalog: catalog,
        storage: storage,
        splitter: ChapterSplitter(documents: documents, storage: storage),
      ),
    );
    await controller.open(
      rootPath: root,
      activeChapterPath: p.join(root, 'Advance.pgn'),
      isWhite: false,
    );
  });

  tearDown(() {
    controller.dispose();
    tmp.deleteSync(recursive: true);
  });

  /// Edits are disk IO and the rebuild parses chapters in an isolate,
  /// neither of which progresses under the test's fake clock — so these
  /// run inside `runAsync` and wait for the outline to show the result.
  Future<void> untilOutline(
    WidgetTester tester,
    bool Function(OutlineFolder outline) ok,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      final outline = controller.outline;
      if (!controller.isLoading && outline != null && ok(outline)) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('the outline never showed the expected state');
  }

  List<String> namesIn(String chapterPath) => controller.outline!
      .findChapter(chapterPath)!
      .lines!
      .map((l) => l.name)
      .toList();

  /// A mouse drag from the centre of [from] to [to] (a finder, or a point),
  /// released there. Desktop drags start on the first movement.
  Future<void> mouseDrag(WidgetTester tester, Finder from, Offset to) async {
    final gesture = await tester.startGesture(
      tester.getCenter(from),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.moveTo(to + const Offset(1, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  Future<void> rightClick(WidgetTester tester, Finder target) async {
    final gesture = await tester.startGesture(
      tester.getCenter(target),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> pump(
    WidgetTester tester, {
    ValueChanged<String>? onOpenChapter,
    void Function(String, OutlineLine)? onOpenLine,
    ValueChanged<String>? onGenerateInto,
    List<String> currentMoves = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            Provider<RepertoireCatalogRepository>.value(
              value: catalog,
              child: child!,
            ),
        // The panel is desktop-first: with a mouse, a drag starts on the
        // first movement. Widget tests default to Android, where a press
        // is needed first.
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: RepertoireOutlinePanel(
              controller: controller,
              onOpenChapter: onOpenChapter ?? (_) {},
              onOpenLine: onOpenLine ?? (_, _) {},
              onGenerateInto: onGenerateInto,
              currentMoves: currentMoves,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'partial split refreshes saved chapters and shows inspectable paths without Retry',
    (tester) async {
      await tester.runAsync(() async {
        final course = p.join(root, 'Course.pgn');
        final content = [
          for (final title in ['One', 'Two'])
            for (final moves in ['1. e4 e5', '1. d4 d5'])
              '[Event "Course"]\n[White "$title"]\n[Black "Line"]\n[Result "*"]\n\n$moves *\n',
        ].join('\n');
        await File(course).writeAsString(content);
        documents.fail = true;
        await controller.refresh();
        await pump(tester);
        await rightClick(tester, find.text('Course'));
        await tester.tap(find.text('Split into chapters…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Split'));
        await untilOutline(
          tester,
          (outline) => outline.findChapter(p.join(root, 'One.pgn')) != null,
        );
        expect(find.text('Review chapter split'), findsOneWidget);
        final details = tester
            .widget<SelectableText>(find.byType(SelectableText))
            .data!;
        expect(
          details,
          contains('Saved chapters:\n${p.join(root, 'One.pgn')}'),
        );
        expect(details, contains('Paths to inspect'));
        expect(details, contains(p.join(root, 'Two.pgn')));
        expect(find.text('Retry'), findsNothing);
        expect(await File(course).readAsString(), content);
        expect(documents.creates, 2);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.text('One'), findsOneWidget);
        expect(find.text('Course'), findsOneWidget);
      });
    },
  );

  testWidgets('lists folders, chapters and the active chapter\'s lines', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Chapters'), findsOneWidget);
    expect(find.text('French'), findsNothing);
    expect(find.text('Sidelines'), findsOneWidget);
    expect(find.text('Advance'), findsOneWidget);
    // Active chapter is unfolded; a collapsed folder's chapter is not shown.
    expect(find.text('Main line'), findsOneWidget);
    expect(find.text('Nh6 idea'), findsOneWidget);
    expect(find.text('Exchange'), findsNothing);
    expect(find.textContaining('2 chapters · 3 lines'), findsNothing);
    await tester.tap(find.byTooltip('Chapter options'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 chapters · 3 lines'), findsOneWidget);
  });

  testWidgets('clearing filters is not undone by a pending debounce', (
    tester,
  ) async {
    await pump(tester);

    // Filter down to nothing so the "Clear filters" action is on screen.
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Nothing matches'), findsOneWidget);

    // A fresh keystroke arms a 200ms debounce...
    await tester.enterText(find.byType(TextField), 'qqq');
    await tester.pump(const Duration(milliseconds: 50));

    // ...and the user clears the filters before it can fire.
    await tester.tap(find.text('Clear filters'));
    await tester.pump(const Duration(milliseconds: 400));

    // The in-flight timer must not resurrect the search just cleared.
    expect(find.text('Nothing matches'), findsNothing);
    expect(find.text('Main line'), findsOneWidget);
  });

  testWidgets('expanding a folder reveals its chapters', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Sidelines'));
    await tester.pumpAndSettle();
    expect(find.text('Exchange'), findsOneWidget);
  });

  testWidgets('tapping a line reports it with its chapter', (tester) async {
    String? chapter;
    OutlineLine? line;
    await pump(
      tester,
      onOpenLine: (c, l) {
        chapter = c;
        line = l;
      },
    );
    await tester.tap(find.text('Nh6 idea'));
    expect(chapter, p.join(root, 'Advance.pgn'));
    expect(line!.gameIndex, 1);
  });

  testWidgets('"at this position" hides lines that do not reach it', (
    tester,
  ) async {
    await pump(
      tester,
      currentMoves: ['e4', 'e6', 'd4', 'd5', 'e5', 'c5', 'c3'],
    );
    await tester.tap(find.byTooltip('Chapter filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckedPopupMenuItem<bool>));
    await tester.pumpAndSettle();
    expect(find.text('Nh6 idea'), findsOneWidget);
    expect(find.text('Main line'), findsNothing);
  });

  for (final returnToA in [false, true]) {
    testWidgets(
      'Outline admitted failure identifies old chapter after root ${returnToA ? "A B A" : "A B"}',
      (tester) async {
        await tester.runAsync(() async {
          documents.deletion = Completer<PgnQuarantineResult>();
          await pump(tester);
          await rightClick(tester, find.text('Advance'));
          await tester.tap(find.text('Delete chapter…'));
          for (
            var i = 0;
            i < 200 && find.byType(AlertDialog).evaluate().isEmpty;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          await tester.tap(find.text('Delete'));
          await documents.deletionEntered.future;
          final other = Directory(p.join(tmp.path, 'Other'))..createSync();
          await controller.open(
            rootPath: other.path,
            activeChapterPath: null,
            isWhite: true,
          );
          if (returnToA) {
            await controller.open(
              rootPath: root,
              activeChapterPath: p.join(root, 'Advance.pgn'),
              isWhite: false,
            );
          }
          documents.deletion!.complete(
            PgnQuarantineFailed(StateError('refused')),
          );
          for (
            var i = 0;
            i < 200 && find.byType(SnackBar).evaluate().isEmpty;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          final message = find.textContaining(
            'The chapter could not be moved to recovery.',
          );
          expect(message, findsOneWidget);
          expect(
            tester.widget<Text>(message).data,
            contains(p.join(root, 'Advance.pgn')),
          );
          expect(
            tester.widget<Text>(message).data,
            isNot(contains(other.path)),
          );
          expect(File(p.join(root, 'Advance.pgn')).existsSync(), isTrue);
          expect(controller.rootPath, returnToA ? root : other.path);
        });
      },
    );
  }

  for (final sameText in [false, true]) {
    testWidgets(
      'Outline confirmation preserves ${sameText ? "equal-text" : "changed"} replacement',
      (tester) async {
        await tester.runAsync(() async {
          await pump(tester);
          await rightClick(tester, find.text('Advance'));
          await tester.tap(find.text('Delete chapter…'));
          for (
            var i = 0;
            i < 200 && find.byType(AlertDialog).evaluate().isEmpty;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          expect(find.text('Delete chapter "Advance"?'), findsOneWidget);
          final file = File(p.join(root, 'Advance.pgn'));
          final original = file.readAsStringSync();
          file.renameSync(p.join(tmp.path, 'retained.pgn'));
          final replacement = sameText
              ? original
              : _game('New writer', '1. d4 d5');
          file.writeAsStringSync(replacement);
          await tester.tap(find.text('Delete'));
          await untilOutline(tester, (o) => o.findChapter(file.path) != null);
          for (
            var i = 0;
            i < 200 && find.byType(SnackBar).evaluate().isEmpty;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          expect(find.textContaining('Nothing was removed'), findsOneWidget);
          expect(file.readAsStringSync(), replacement);
          expect(controller.activeChapterPath, file.path);
          expect(controller.isChapterOpen(file.path), isTrue);
        });
      },
    );
  }

  testWidgets(
    'Outline confirmation cannot authorize after active selection A B A',
    (tester) async {
      await tester.runAsync(() async {
        await pump(tester);
        await rightClick(tester, find.text('Advance'));
        await tester.tap(find.text('Delete chapter…'));
        for (
          var i = 0;
          i < 200 && find.byType(AlertDialog).evaluate().isEmpty;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
        final active = p.join(root, 'Advance.pgn');
        controller.setActiveChapter(p.join(root, 'Sidelines', 'Exchange.pgn'));
        controller.setActiveChapter(active);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(File(active).existsSync(), isTrue);
        expect(controller.activeChapterPath, active);
        expect(find.byType(SnackBar), findsNothing);
      });
    },
  );

  testWidgets('right-click → Rename renames the chapter file', (tester) async {
    // Everything after the first frame runs in real async: the rename is
    // disk IO and the rebuild parses the chapter in an isolate, neither of
    // which progresses under the test's fake clock.
    await tester.runAsync(() async {
      await pump(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Advance')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Rename…'), findsOneWidget);
      expect(find.text('Generate lines into this chapter…'), findsNothing);

      await tester.tap(find.text('Rename…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Advance Variation');
      await tester.tap(find.text('Rename'));
      await untilOutline(
        tester,
        (o) => o.findChapter(p.join(root, 'Advance Variation.pgn')) != null,
      );

      expect(File(p.join(root, 'Advance Variation.pgn')).existsSync(), isTrue);
      expect(File(p.join(root, 'Advance.pgn')).existsSync(), isFalse);
      expect(find.text('Advance Variation'), findsOneWidget);
    });
  });

  testWidgets('chapter menu offers generation when the host supports it', (
    tester,
  ) async {
    String? target;
    await pump(tester, onGenerateInto: (path) => target = path);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Advance')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate lines into this chapter…'));
    await tester.pumpAndSettle();
    expect(target, p.join(root, 'Advance.pgn'));
  });

  testWidgets('a chapter rename with a slash is refused in the dialog', (
    tester,
  ) async {
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Advance')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'a/b');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Names cannot contain'), findsOneWidget);
  });

  testWidgets(
    'a line dragged onto another chapter updates both files quietly',
    (tester) async {
      await tester.runAsync(() async {
        await pump(tester);
        await tester.tap(find.text('Sidelines'));
        await tester.pumpAndSettle();
        final advance = p.join(root, 'Advance.pgn');
        final exchange = p.join(root, 'Sidelines', 'Exchange.pgn');

        await mouseDrag(
          tester,
          find.text('Nh6 idea'),
          tester.getCenter(find.text('Exchange')),
        );
        await untilOutline(
          tester,
          (o) => o.findChapter(exchange)!.lineCount == 2,
        );
        expect(namesIn(advance), ['Main line']);
        expect(namesIn(exchange), ['Exchange', 'Nh6 idea']);
        expect(find.byType(SnackBar), findsNothing);
      });
    },
  );

  testWidgets('a line dropped on the top half of another goes before it', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await pump(tester);
      final advance = p.join(root, 'Advance.pgn');
      final target = tester.getTopLeft(find.text('Main line'));
      await mouseDrag(
        tester,
        find.text('Nh6 idea'),
        target + const Offset(4, 2),
      );
      await untilOutline(
        tester,
        (o) => o.findChapter(advance)!.lines!.first.name == 'Nh6 idea',
      );
      expect(namesIn(advance), ['Nh6 idea', 'Main line']);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  testWidgets('Ctrl-click picks several lines and a drag moves them all', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await pump(tester);
      await tester.tap(find.text('Sidelines'));
      await tester.pumpAndSettle();
      final advance = p.join(root, 'Advance.pgn');
      final exchange = p.join(root, 'Sidelines', 'Exchange.pgn');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('Main line'));
      await tester.tap(find.text('Nh6 idea'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      await mouseDrag(
        tester,
        find.text('Main line'),
        tester.getCenter(find.text('Exchange')),
      );
      await untilOutline(
        tester,
        (o) => o.findChapter(exchange)!.lineCount == 3,
      );
      expect(namesIn(advance), isEmpty);
      expect(namesIn(exchange), ['Exchange', 'Main line', 'Nh6 idea']);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  testWidgets('a line dropped on a folder starts a chapter there', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final opened = <String>[];
      await pump(tester, onOpenChapter: opened.add);
      final made = p.join(root, 'Sidelines', 'Nh6 idea.pgn');

      await mouseDrag(
        tester,
        find.text('Nh6 idea'),
        tester.getCenter(find.text('Sidelines')),
      );
      await tester.pumpAndSettle();
      expect(find.text('New chapter for this line'), findsOneWidget);
      // The line's own name is the suggestion; keeping it is an answer.
      await tester.tap(find.text('Create'));
      await untilOutline(tester, (o) => o.findChapter(made) != null);

      expect(namesIn(made), ['Nh6 idea']);
      expect(namesIn(p.join(root, 'Advance.pgn')), ['Main line']);
      expect(opened, [made]);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  testWidgets('dragging a nested chapter offers the top level', (tester) async {
    await tester.runAsync(() async {
      await pump(tester);
      await tester.tap(find.text('Sidelines'));
      await tester.pumpAndSettle();
      final moved = p.join(root, 'Exchange.pgn');

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Exchange')),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 25));
      await tester.pump();
      expect(find.text('Move to the top level'), findsOneWidget);
      await gesture.moveTo(
        tester.getCenter(find.text('Move to the top level')),
      );
      await tester.pump();
      await gesture.up();
      await untilOutline(tester, (o) => o.findChapter(moved) != null);
      expect(find.text('Move to the top level'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  testWidgets('the + button makes a chapter and opens it', (tester) async {
    await tester.runAsync(() async {
      final opened = <String>[];
      await pump(tester, onOpenChapter: opened.add);
      await tester.tap(find.byTooltip('New chapter'));
      await tester.pumpAndSettle();
      expect(find.text('New chapter'), findsOneWidget);

      // A name already in this folder is refused in the field.
      await tester.enterText(find.byType(TextField).last, 'advance');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.textContaining('already exists'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'Tarrasch');
      await tester.tap(find.text('Create'));
      final made = p.join(root, 'Tarrasch.pgn');
      await untilOutline(tester, (o) => o.findChapter(made) != null);
      expect(File(made).existsSync(), isTrue);
      expect(opened, [made]);
    });
  });

  testWidgets(
    'deleting a line updates the chapter without a completion toast',
    (tester) async {
      await tester.runAsync(() async {
        await pump(tester);
        final advance = p.join(root, 'Advance.pgn');
        await rightClick(tester, find.text('Main line'));
        await tester.tap(find.text('Delete line'));
        await untilOutline(
          tester,
          (o) => o.findChapter(advance)!.lineCount == 1,
        );
        expect(namesIn(advance), ['Nh6 idea']);
        expect(find.byType(SnackBar), findsNothing);
      });
    },
  );

  testWidgets('right-clicking empty space offers a chapter or folder', (
    tester,
  ) async {
    await pump(tester);
    final list = find.byType(ListView);
    final gesture = await tester.startGesture(
      tester.getBottomLeft(list) + const Offset(40, -10),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('New chapter…'), findsOneWidget);
    expect(find.text('New folder…'), findsOneWidget);
  });
}
