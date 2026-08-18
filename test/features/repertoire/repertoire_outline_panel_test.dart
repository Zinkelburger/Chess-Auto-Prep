import 'dart:io';

import 'package:chess_auto_prep/features/repertoire/controllers/repertoire_outline_controller.dart';
import 'package:chess_auto_prep/features/repertoire/models/repertoire_outline.dart';
import 'package:chess_auto_prep/features/repertoire/services/repertoire_outline_service.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_outline_panel.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
      service: RepertoireOutlineService(storage: IOStorageService()),
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

  Future<void> pump(
    WidgetTester tester, {
    ValueChanged<String>? onOpenChapter,
    void Function(String, OutlineLine)? onOpenLine,
    ValueChanged<String>? onGenerateInto,
    List<String> currentMoves = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
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
      await tester.tap(find.text('OK'));

      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (!controller.isLoading &&
            controller.outline?.findChapter(
                  p.join(root, 'Advance Variation.pgn'),
                ) !=
                null) {
          break;
        }
      }
      await tester.pumpAndSettle();

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

  testWidgets('a rename with a slash is refused in the dialog', (tester) async {
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Main line')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'a/b');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Names cannot contain'), findsOneWidget);
  });
}
