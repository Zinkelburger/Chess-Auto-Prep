import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/library/library_panel.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/move_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

/// The move field under the board, in each place the user plays moves:
/// a typed move takes the path a move made on the board takes, so it is
/// saved, taken back, judged and graded the same.
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  final field = find.descendant(
    of: find.byType(MoveField),
    matching: find.byType(TextField),
  );

  bool fieldHasFocus(WidgetTester tester) =>
      tester.widget<TextField>(field).focusNode!.hasFocus;

  String kidOnDisk() => switch (w.store.documents[kidMain]) {
    Opened(:final text) => text,
    _ => '',
  };

  String words(WidgetTester tester) =>
      tester.widget<TextField>(field).controller!.text;

  /// The window with the KID chapter open: Black to move after 1. e4.
  Future<void> openKid(WidgetTester tester) async {
    await w.pumpShell(tester);
    await tester.tap(
      find
          .descendant(
            of: find.byType(LibraryPanel),
            matching: find.text('Main'),
          )
          .last,
    );
    await tester.pumpAndSettle();
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  group('on a chapter', () {
    testWidgets('/ goes to the field, and a new move is played into the '
        'chapter the moment it is named', (tester) async {
      await openKid(tester);
      expect(find.byTooltip('Type a move (/)'), findsOneWidget);
      expect(fieldHasFocus(tester), isFalse);
      await key(tester, LogicalKeyboardKey.slash);
      expect(fieldHasFocus(tester), isTrue);
      await tester.enterText(field, 'N');
      await tester.pump();
      expect(w.session.cursor, const NodePath.root(), reason: 'which knight?');
      await tester.enterText(field, 'Nf6');
      await tester.pumpAndSettle();
      expect(w.session.currentMove?.san, 'Nf6');
      expect(kidOnDisk(), contains('Nf6'), reason: 'saved');
      expect(words(tester), isEmpty);
      expect(fieldHasFocus(tester), isTrue, reason: 'the next move goes too');
    });

    testWidgets('a move the chapter holds is followed, not written again', (
      tester,
    ) async {
      await openKid(tester);
      final before = kidOnDisk();
      await key(tester, LogicalKeyboardKey.slash);
      await tester.enterText(field, 'c5');
      await tester.pumpAndSettle();
      expect(w.session.cursor, NodePath.of([0]));
      expect(kidOnDisk(), before);
    });

    testWidgets('Enter plays the one move the words leave', (tester) async {
      await openKid(tester);
      await key(tester, LogicalKeyboardKey.slash);
      await tester.enterText(field, 'Nh');
      await tester.pump();
      expect(w.session.cursor, const NodePath.root());
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(w.session.currentMove?.san, 'Nh6');
      expect(fieldHasFocus(tester), isTrue);
    });

    testWidgets('words no move is written as are marked, never played or '
        'asked about', (tester) async {
      await openKid(tester);
      await key(tester, LogicalKeyboardKey.slash);
      await tester.enterText(field, 'Ke7');
      await tester.pump();
      final error = Theme.of(tester.element(field)).colorScheme.error;
      final border = tester
          .widget<TextField>(field)
          .decoration!
          .enabledBorder!
          .borderSide;
      expect(border.color, error);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(w.session.cursor, const NodePath.root());
      expect(find.byType(Dialog), findsNothing);
      expect(words(tester), 'Ke7', reason: 'left to be put right');
    });

    testWidgets('Esc clears the words and gives the keys back to the board', (
      tester,
    ) async {
      await openKid(tester);
      await key(tester, LogicalKeyboardKey.slash);
      await tester.enterText(field, 'N');
      await tester.pump();
      await key(tester, LogicalKeyboardKey.keyF);
      expect(w.session.flipped, isFalse, reason: 'the words have the keys');
      await key(tester, LogicalKeyboardKey.escape);
      expect(words(tester), isEmpty);
      expect(fieldHasFocus(tester), isFalse);
      await key(tester, LogicalKeyboardKey.keyF);
      expect(w.session.flipped, isTrue, reason: 'the keys are back');
    });
  });

  testWidgets('on the analysis board a typed move is taken back by Ctrl+Z', (
    tester,
  ) async {
    await w.pumpShell(tester);
    await w.requests.newAnalysisBoard();
    await tester.pumpAndSettle();
    expect(w.session.isScratch, isTrue);
    await key(tester, LogicalKeyboardKey.slash);
    await tester.enterText(field, 'e2e4');
    await tester.pumpAndSettle();
    expect(w.session.currentMove?.san, 'e4');
    await key(tester, LogicalKeyboardKey.escape);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(w.session.tree?.children, isEmpty);
  });

  testWidgets('in Tactics a typed move is judged as the board judges it, '
      'and nothing is written into the set', (tester) async {
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.tactics);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play (4)'));
    await tester.pumpAndSettle();
    expect(find.text('Black to play · 2 moves'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.slash);
    await tester.enterText(field, 'd5');
    await tester.pumpAndSettle();
    expect(find.text('Incorrect — d5 is not it.'), findsOneWidget);
    await tester.enterText(field, 'e5');
    await tester.pumpAndSettle();
    expect(find.text('Correct! (1/2)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(w.session.currentMove?.san, 'Nf3', reason: 'the reply came');
    expect(w.session.tree?.children.map((move) => move.san), ['e5']);
  });

  testWidgets('in a Train drill a letter typed on the lesson starts the '
      'move, which is graded; the lesson then has the keys again', (
    tester,
  ) async {
    await openKid(tester);
    await tester.tap(find.text('Train'));
    await tester.pumpAndSettle();
    w.lineTrainer.learn();
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.space);
    expect(find.text('Your move'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.keyC);
    expect(words(tester), 'c');
    expect(fieldHasFocus(tester), isTrue);
    // The rest arrives as text, as the platform types it into the field.
    await tester.enterText(field, 'c5');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    final attempt = w.progress.attempts.single;
    expect(attempt.played, 'c5');
    expect(attempt.correct, isTrue);
    expect(fieldHasFocus(tester), isFalse, reason: 'the lesson has the keys');
  });
}
