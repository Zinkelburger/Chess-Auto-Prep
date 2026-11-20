import 'package:chess_auto_prep/chess/pgn/game_review.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart' show Opened;
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/document/session_results.dart';
import 'package:chess_auto_prep/workspace/reading/move_tree_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

/// A chapter whose introduction and whose first move both carry the tokens
/// an engine pass leaves behind.
const annotatedChapter = '''
// Color: White

[Event "Annotated"]
[Result "*"]

{Play the Exchange. [%eval 0.21]} 1. d4 ({A sideline. [%eval 0.05]} 1. c4 e5) 1... d5 {[%clk 0:29:41] Our move.} *
''';

Future<void> pumpTree(WidgetTester tester, SessionFixture fixture) async {
  await tester.binding.setSurfaceSize(const Size(400, 600));
  await tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(body: MoveTreeView(session: fixture.session)),
    ),
  );
  await tester.pump();
}

/// Two lines from 1. e4 e5, the second holding a move no reader can play,
/// so it is not read whole and no edit may write it.
const brokenSecondLine = '''
// Color: White

[Event "Fine"]
[Result "*"]

1. e4 e5 2. Nf3 *

[Event "Broken"]
[Result "*"]

1. e4 e5 2. Qq9 *
''';

/// Two lines from 1. d4, the second of them a branch at the first move.
const twoLines = '''
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 *
''';

void main() {
  testWidgets('Shift+F10 opens the focused move menu', (tester) async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);
    Focus.of(tester.element(find.textContaining('Nf6').first)).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('Copy line PGN'), findsOneWidget);
  });

  testWidgets('a move copies the line that leads to it, or its position', (
    tester,
  ) async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpTree(tester, fixture);

    await tester.longPress(find.textContaining('Nf6'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy line PGN'));
    await tester.pumpAndSettle();
    expect(copied, '1. d4 Nf6 *');

    await tester.longPress(find.textContaining('Nf6'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy FEN'));
    await tester.pumpAndSettle();
    expect(
      copied,
      startsWith('rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w'),
    );
  });

  testWidgets('Copy FEN still copies the clicked position after undo', (
    tester,
  ) async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    final session = fixture.session;
    session.setComment(const NodePath.root(), 'A new introduction.');
    await fixture.saver.flush();
    final expected = session.tree!.children.first.children.last.fen.value;
    final messenger = tester.binding.defaultBinaryMessenger;
    String? copied;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pumpTree(tester, fixture);

    fixture.store.hold = true;
    final undoing = session.undo();
    await tester.pump();
    expect(fixture.store.waiting, 1);
    await tester.tap(find.textContaining('Nf6'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    fixture.store.hold = false;
    fixture.store.releaseNext();
    expect(await undoing, isA<Restored>());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy FEN'));
    await tester.pumpAndSettle();

    expect(copied, expected);
  });

  testWidgets('a move offers what can be done to it, and does it', (
    tester,
  ) async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);

    await tester.longPress(find.textContaining('Nf6'));
    await tester.pumpAndSettle();
    expect(find.text('Promote variation'), findsOneWidget);
    expect(find.text('Delete from here'), findsOneWidget);
    await tester.tap(find.text('Make main line'));
    await tester.pumpAndSettle();

    expect(fixture.session.tree!.children.first.children.first.san, 'Nf6');
    expect(
      fixture.onDisk.indexOf('[Event "Indian"]'),
      lessThan(fixture.onDisk.indexOf('[Event "Queen\'s"]')),
    );
  });

  testWidgets('the menu opens where the move was right-clicked, and no move '
      'carries a menu of its own', (tester) async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);
    expect(find.byType(MenuAnchor), findsNothing);

    for (final move in ['Nf6', 'c4']) {
      final at = tester.getCenter(find.textContaining(move));
      await tester.tapAt(at, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      // Its first entry, inside the menu's own padding.
      final entry = tester.getTopLeft(
        find.widgetWithText(PopupMenuItem<VoidCallback>, 'Promote variation'),
      );
      expect(entry.dy - at.dy, inInclusiveRange(0, 32), reason: move);
      expect(entry.dx - at.dx, inInclusiveRange(0, 32), reason: move);
      // A click anywhere else puts it away.
      await tester.tapAt(const Offset(390, 590));
      await tester.pumpAndSettle();
      expect(find.text('Promote variation'), findsNothing);
    }
  });

  testWidgets('a move menu cannot delete from a newly opened file', (
    tester,
  ) async {
    final fixture = await openSession('[Event "A"]\n\n1. e4 e5 2. Nf3 *\n');
    addTearDown(fixture.dispose);
    final other = chapterRef('KID', 'B');
    const text = '[Event "B"]\n\n1. d4 d5 2. c4 *\n';
    fixture.store.documents[other] = Opened(text, scriptedRevision(text));
    await pumpTree(tester, fixture);

    fixture.store.hold = true;
    final opening = fixture.session.open(other);
    await tester.pump();
    expect(fixture.store.waiting, 1);
    await tester.tap(find.textContaining('e5'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    final delete = find.text('Delete from here');
    expect(delete, findsOneWidget);
    fixture.store.hold = false;
    fixture.store.releaseNext();
    expect(await opening, isA<DocumentOpened>());
    await tester.pumpAndSettle();
    if (delete.evaluate().isNotEmpty) {
      await tester.tap(delete);
      await tester.pumpAndSettle();
    }

    await fixture.saver.flush();
    expect(fixture.session.source, other);
    expect(fixture.session.tree!.mainLine.map((move) => move.san), [
      'd4',
      'd5',
      'c4',
    ]);
    expect((fixture.store.documents[other] as Opened).text, text);
  });

  testWidgets('an open delete menu preserves a replacement review line', (
    tester,
  ) async {
    final fixture = await openSession(
      '[Event "Reviewed"]\n\n1. e4 (1. d4 {[%cap_review_line 2]} d5) *\n',
    );
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);
    await tester.tap(find.textContaining('d5'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(
      fixture.session.apply(
        (chapter) => annotateGame(chapter, const [
          ReviewValue(0, '0.00', ['c2c4', 'd7d5']),
          ReviewValue(-250, '-2.50', []),
        ]),
      ),
      isNull,
    );
    await fixture.saver.flush();
    final reviewed = fixture.onDisk;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from here'));
    await tester.pumpAndSettle();
    await fixture.saver.flush();

    final replacement = fixture.session.tree!.children[1];
    expect(replacement.san, 'c4');
    expect(replacement.children.single.san, 'd5');
    expect(fixture.onDisk, reviewed);
  });

  testWidgets('an open delete menu still works after a comment edit', (
    tester,
  ) async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);
    await tester.longPress(find.textContaining('c4'));
    await tester.pumpAndSettle();
    fixture.session.setComment(const NodePath.root(), 'New introduction.');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from here'));
    await tester.pumpAndSettle();
    await fixture.saver.flush();

    expect(fixture.onDisk, contains('New introduction.'));
    expect(fixture.onDisk, contains('1. d4 d5 *'));
  });

  testWidgets('deleting from a move takes it off the screen quietly and undo '
      'puts it back', (tester) async {
    final fixture = await openSession(twoLines);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);

    await tester.longPress(find.textContaining('c4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from here'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(MoveTreeView),
        matching: find.textContaining('c4'),
      ),
      findsNothing,
    );
    expect(fixture.onDisk, contains('1. d4 d5 *'));
    expect(find.byType(SnackBar), findsNothing);

    await fixture.session.undo();
    await tester.pumpAndSettle();

    expect(fixture.onDisk, twoLines);
  });

  testWidgets('a delete that was refused says why', (tester) async {
    final fixture = await openSession(brokenSecondLine);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);

    await tester.longPress(find.textContaining('e5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from here'));
    await tester.pumpAndSettle();

    expect(fixture.session.refusedEdit, isA<EditNotWritten>());
  });

  testWidgets('shows the introduction without its machine tokens', (
    tester,
  ) async {
    final fixture = await openSession(annotatedChapter);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);

    expect(find.text('Play the Exchange.'), findsOneWidget);
    expect(find.text('Our move.'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data ?? '').contains('[%'),
      ),
      findsNothing,
      reason: 'engine tokens belong to the move, not to the reader',
    );
  });

  testWidgets('reads a note the file wrote before a move before it', (
    tester,
  ) async {
    final fixture = await openSession(annotatedChapter);
    addTearDown(fixture.dispose);
    await pumpTree(tester, fixture);

    final note = tester.getTopLeft(find.text('A sideline.'));
    final move = tester.getTopLeft(find.textContaining('c4'));
    expect(note.dy, lessThan(move.dy), reason: 'read before it');
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data ?? '').contains('[%'),
      ),
      findsNothing,
    );
  });

  testWidgets('another game of the file starts at the top of the list', (
    tester,
  ) async {
    // Two games, each with a long note on every move, so the list scrolls.
    final note = List.filled(40, 'words').join(' ');
    String game(String event) =>
        '[Event "$event"]\n[Result "*"]\n\n'
        '1. e4 {$note} e5 {$note} 2. Nf3 {$note} Nc6 {$note} '
        '3. Bb5 {$note} a6 {$note} 4. Ba4 {$note} Nf6 {$note} *\n';
    final fixture = await openSession('${game('One')}\n${game('Two')}');
    addTearDown(fixture.dispose);
    await fixture.session.open(fixture.ref, game: 0);
    await pumpTree(tester, fixture);

    final list = find.byType(Scrollable).first;
    ScrollPosition position() => tester.state<ScrollableState>(list).position;
    position().jumpTo(position().maxScrollExtent);
    await tester.pump();
    expect(position().pixels, greaterThan(0));

    fixture.session.showGame(1);
    await tester.pumpAndSettle();
    expect(position().pixels, 0);
  });
}
