import 'dart:io';

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

void main() {
  late Directory tmp;
  late String root;
  late RepertoireOutlineController controller;

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
    controller = RepertoireOutlineController(
      service: RepertoireOutlineService(
        storage: IOStorageService(
          documentsRoot: tmp,
          supportRoot: tmp,
          repertoiresRoot: Directory(root),
        ),
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

  testWidgets('lists folders, chapters and the active chapter\'s lines', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('French'), findsOneWidget);
    expect(find.text('Sidelines'), findsOneWidget);
    expect(find.text('Advance'), findsOneWidget);
    // Active chapter is unfolded; a collapsed folder's chapter is not shown.
    expect(find.text('Main line'), findsOneWidget);
    expect(find.text('Nh6 idea'), findsOneWidget);
    expect(find.text('Exchange'), findsNothing);
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
    await tester.tap(find.text('At this position'));
    await tester.pumpAndSettle();
    expect(find.text('Nh6 idea'), findsOneWidget);
    expect(find.text('Main line'), findsNothing);
  });

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

  testWidgets('a line dragged onto another chapter moves there, with Undo', (
    tester,
  ) async {
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
      expect(find.text('Moved "Nh6 idea" to "Exchange".'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await untilOutline(tester, (o) => o.findChapter(advance)!.lineCount == 2);
      expect(namesIn(advance), ['Main line', 'Nh6 idea']);
      expect(namesIn(exchange), ['Exchange']);
    });
  });

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
      expect(find.text('Reordered "Nh6 idea".'), findsOneWidget);
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
      expect(find.text('Moved 2 lines to "Exchange".'), findsOneWidget);
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
      expect(find.text('Made "Nh6 idea" from 1 line.'), findsOneWidget);
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
      expect(find.text('Moved "Exchange" to the top level.'), findsOneWidget);
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

  testWidgets('deleting a line needs no confirmation and can be undone', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await pump(tester);
      final advance = p.join(root, 'Advance.pgn');
      await rightClick(tester, find.text('Main line'));
      await tester.tap(find.text('Delete line'));
      await untilOutline(tester, (o) => o.findChapter(advance)!.lineCount == 1);
      expect(namesIn(advance), ['Nh6 idea']);
      expect(find.text('Deleted "Main line".'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await untilOutline(tester, (o) => o.findChapter(advance)!.lineCount == 2);
      expect(namesIn(advance), ['Main line', 'Nh6 idea']);
    });
  });

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
