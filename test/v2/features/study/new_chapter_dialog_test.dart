import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/features/study/new_chapter_dialog.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _rookEnding = '8/8/4k3/8/8/4K3/4R3/8 w - - 0 1';

void main() {
  testWidgets('a chapter from a position keeps the FEN typed, and the '
      'dialog closes with the field still in use', (tester) async {
    NewChapter? answered;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => answered = await showNewChapterDialog(
              context,
              suggested: 'Chapter 3',
            ),
            child: const Text('Ask'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
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
}
