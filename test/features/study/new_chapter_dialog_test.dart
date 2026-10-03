import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/features/study/new_chapter_dialog.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _rookEnding = '8/8/4k3/8/8/4K3/4R3/8 w - - 0 1';

void main() {
  testWidgets('a chapter from a position keeps the FEN typed, and the '
      'dialog closes with the field still in use', (tester) async {
    NewChapter? answered;
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                answered = await showNewChapterDialog(context),
            child: const Text('Ask'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Chapter name'))
          .controller!
          .text,
      isEmpty,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Chapter name'),
      'Chapter 3',
    );
    await tester.tap(find.text('Position'));
    await tester.pumpAndSettle();
    final fen = find.widgetWithText(TextField, 'FEN');
    await tester.enterText(fen, _rookEnding);

    // Away and back: the field comes back with what was typed in it.
    await tester.tap(find.text('Initial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Position'));
    await tester.pumpAndSettle();
    expect(find.text(_rookEnding), findsOneWidget);

    // Create with the FEN field focused: it is still on screen, losing its
    // focus, while the dialog closes.
    await tester.enterText(fen, _rookEnding);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(answered?.name, 'Chapter 3');
    expect(answered?.root, const Fen(_rookEnding));
    expect(answered?.orientation, isNull);
  });

  testWidgets('a position half set up survives the window narrowing and the '
      'editor moving under the form', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1300, 1400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showNewChapterDialog(context),
            child: const Text('Ask'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Position'));
    await tester.pumpAndSettle();
    // An empty board: no game starts from it, so only the editor holds it.
    await tester.tap(find.text('Clear board'));
    await tester.pumpAndSettle();
    const empty = '8/8/8/8/8/8/8/8 w - - 0 1';
    expect(find.text(empty), findsOneWidget);
    final beside = tester.getTopLeft(find.text('Clear board'));

    tester.view.physicalSize = const Size(1000, 1400);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Clear board')).dy,
      greaterThan(beside.dy),
      reason: 'the editor is under the form now',
    );
    expect(find.text(empty), findsOneWidget);
  });
}
