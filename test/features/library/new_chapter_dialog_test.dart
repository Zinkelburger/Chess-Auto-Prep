// The builder's New chapter: what it offers to start from, and what the
// dialog answers for each choice.

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/features/library/new_chapter_dialog.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Chapter _chapter(String text) => parseChapter(name: 'Main', text: text);

const _kingsGambit =
    '// Main\n// Color: White\n\n[Event "Main"]\n\n1. e4 e5 2. f4 exf4 *\n';

void main() {
  group('the moves offered from the board', () {
    test('are the line from the start to the cursor', () {
      expect(
        rootMovesFromBoard(_chapter(_kingsGambit), NodePath.of([0, 0, 0])),
        ['e4', 'e5', 'f4'],
      );
    });

    test('are none at the start of a chapter from the start', () {
      expect(
        rootMovesFromBoard(_chapter(_kingsGambit), const NodePath.root()),
        isNull,
      );
    });

    test('begin with the root line of a chapter that starts later', () {
      final rooted = _chapter('// Main\n// Root: 1. e4 e5\n\n');
      expect(rootMovesFromBoard(rooted, const NodePath.root()), ['e4', 'e5']);
    });

    test('are none for a chapter from a position no line reaches', () {
      final bare = _chapter(
        '// Main\n\n[Event "Rook"]\n[SetUp "1"]\n'
        '[FEN "8/8/4k3/8/8/4K3/4R3/8 w - - 0 1"]\n\n1. Re1+ *\n',
      );
      expect(rootMovesFromBoard(bare, NodePath.of([0])), isNull);
    });
  });

  group('the dialog', () {
    late NewChapter? answered;

    /// Opens the dialog over [fromBoard] and types [name] into it.
    Future<void> ask(
      WidgetTester tester,
      String name, {
      List<String>? fromBoard,
    }) async {
      answered = null;
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => answered = await showNewChapterDialog(
                context,
                fromBoard: fromBoard,
              ),
              child: const Text('Ask'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Chapter name'),
        name,
      );
    }

    Future<void> create(WidgetTester tester) async {
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
    }

    testWidgets('starts from the board unless told otherwise', (tester) async {
      await ask(tester, "King's Gambit", fromBoard: const ['e4', 'e5', 'f4']);
      expect(find.text('From here'), findsOneWidget);
      expect(find.text('1.e4 e5 2.f4'), findsOneWidget);
      await create(tester);

      expect(answered?.name, "King's Gambit");
      expect(answered?.rootMoves, ['e4', 'e5', 'f4']);
    });

    testWidgets('From the start drops the board moves', (tester) async {
      await ask(tester, 'Open games', fromBoard: const ['e4', 'e5', 'f4']);
      await tester.tap(find.text('From the start'));
      await tester.pumpAndSettle();
      expect(
        find.text('1.e4 e5 2.f4'),
        findsNothing,
        reason: 'the moves it would start after are shown only From here',
      );
      await create(tester);

      expect(answered?.name, 'Open games');
      expect(answered?.rootMoves, isEmpty);
    });

    testWidgets('with nothing on the board asks only the name', (tester) async {
      await ask(tester, 'Main');
      expect(find.text('From here'), findsNothing);
      await create(tester);

      expect(answered?.name, 'Main');
      expect(answered?.rootMoves, isEmpty);
    });
  });
}
