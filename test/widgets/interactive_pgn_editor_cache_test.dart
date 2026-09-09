/// The editor's rendered movetext survives cursor moves: stepping through a
/// line repaints the two chips whose selection changed and nothing else.
library;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:chess_auto_prep/widgets/pgn/comment_editor.dart';

Widget _host(MoveTree tree, TreePath path) => MaterialApp(
  home: Scaffold(
    body: InteractivePgnEditor(tree: tree, currentPath: path),
  ),
);

/// The paragraphs the editor laid out: the `Text.rich` rows whose spans
/// carry the move chips.  (Chips are `Text.rich` too, so "any rich text"
/// would count them as well.)
List<Text> _paragraphs(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).where((t) {
      final span = t.textSpan;
      return span is TextSpan &&
          (span.children?.any((c) => c is WidgetSpan) ?? false);
    }).toList();

MoveChip _chip(WidgetTester tester, String san) => tester
    .widgetList<MoveChip>(find.byType(MoveChip))
    .firstWhere((c) => c.san == san);

Color? _chipBackground(WidgetTester tester, String san) =>
    _chip(tester, san).decoration?.color;

void main() {
  testWidgets('a cursor move keeps the paragraph and moves the highlight', (
    tester,
  ) async {
    final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3', 'Nc6']);
    await tester.pumpWidget(_host(tree, const TreePath([0, 0])));
    final before = _paragraphs(tester);
    expect(before, isNotEmpty);
    final e4 = _chip(tester, 'e4');
    final nc6 = _chip(tester, 'Nc6');
    expect(_chipBackground(tester, 'e5'), AppColors.pgnMoveCurrentBg);
    expect(_chipBackground(tester, 'Nf3'), isNull);

    await tester.pumpWidget(_host(tree, const TreePath([0, 0, 0])));
    final after = _paragraphs(tester);
    expect(after.length, before.length);
    for (var i = 0; i < before.length; i++) {
      expect(
        identical(before[i], after[i]),
        isTrue,
        reason: 'the movetext is cached across cursor moves',
      );
    }
    expect(_chipBackground(tester, 'e5'), isNull);
    expect(_chipBackground(tester, 'Nf3'), AppColors.pgnMoveCurrentBg);
    expect(
      identical(_chip(tester, 'e4'), e4),
      isTrue,
      reason: 'a chip whose selection did not change is not rebuilt',
    );
    expect(identical(_chip(tester, 'Nc6'), nc6), isTrue);
  });

  testWidgets('an edit through the tree re-renders the movetext', (
    tester,
  ) async {
    final tree = MoveTree.fromMoves(['e4', 'e5']);
    await tester.pumpWidget(_host(tree, const TreePath([0, 0])));
    final before = _paragraphs(tester);

    tree.setComment(const TreePath([0]), 'best by test');
    await tester.pumpWidget(_host(tree, const TreePath([0, 0])));
    final after = _paragraphs(tester);
    expect(identical(before.first, after.first), isFalse);
    expect(find.textContaining('best by test'), findsOneWidget);
  });

  testWidgets(
    'nested variations and prose keep rows, paths and cached layout',
    (tester) async {
      final tree = MoveTree.fromPgn('1. e4 (1. d4 d5 (1... Nf6) 2. c4) e5 *');
      tree.setComment(
        const TreePath([0]),
        'First paragraph.\n\nSecond paragraph.',
      );
      await tester.pumpWidget(_host(tree, const TreePath([0])));
      final before = _paragraphs(tester);
      Finder move(String san) => find.byWidgetPredicate(
        (widget) => widget is MoveChip && widget.san == san,
      );
      Rect rowRect(String san) => tester.getRect(
        find.ancestor(of: move(san), matching: find.byType(Text)),
      );
      final main = tester.getRect(move('e4'));
      final variation = tester.getRect(move('d4'));
      final nested = tester.getRect(move('Nf6'));
      final resumed = tester.getRect(move('e5'));
      expect(variation.top, greaterThan(main.bottom));
      expect(variation.left, greaterThan(main.left));
      expect(nested.top, greaterThan(variation.bottom));
      expect(nested.left, greaterThan(variation.left));
      expect(resumed.top, greaterThan(nested.bottom));
      expect(rowRect('e5').left, rowRect('e4').left);
      expect(rowRect('d4').left, greaterThan(rowRect('e4').left));
      expect(rowRect('Nf6').left, greaterThan(rowRect('d4').left));
      expect(
        tester.getRect(find.textContaining('First paragraph.')).bottom,
        lessThan(tester.getRect(find.textContaining('Second paragraph.')).top),
      );
      expect(
        tester.getRect(find.textContaining('Second paragraph.')).bottom,
        lessThan(variation.top),
      );
      expect(before.last.textSpan!.toPlainText(), startsWith('1...\u00a0'));
      expect(
        before.any((row) => row.textSpan!.toPlainText().contains('(')),
        isFalse,
      );

      const nestedPath = TreePath([1, 1]);
      expect(tree.nodeAt(nestedPath)?.san, 'Nf6');
      await tester.pumpWidget(_host(tree, nestedPath));
      final after = _paragraphs(tester);
      expect(after.length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(after[i], same(before[i]));
      }
      expect(_chipBackground(tester, 'e4'), isNull);
      expect(_chipBackground(tester, 'Nf6'), AppColors.pgnMoveCurrentBg);
      expect(tester.getRect(move('Nf6')), nested);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching trees at the same cursor replaces cached prose', (
    tester,
  ) async {
    final first = MoveTree.fromMoves(['e4']);
    final second = MoveTree.fromMoves(['e4']);
    first.setComment(const TreePath([0]), 'First chapter.');
    second.setComment(const TreePath([0]), 'Second chapter.');
    expect(second.version, first.version);

    await tester.pumpWidget(_host(first, const TreePath([0])));
    await tester.pumpWidget(_host(second, const TreePath([0])));
    expect(find.textContaining('First chapter.'), findsNothing);
    expect(find.textContaining('Second chapter.'), findsOneWidget);
    expect(_chipBackground(tester, 'e4'), AppColors.pgnMoveCurrentBg);
  });

  testWidgets(
    'switching chapters immediately keeps opening notes on their tree',
    (tester) async {
      final first = MoveTree.fromMoves(['e4'])..rootComment = 'First note';
      final second = MoveTree.fromMoves(['d4'])..rootComment = 'Second note';
      var active = first;
      Widget host() => MaterialApp(
        home: Scaffold(
          body: InteractivePgnEditor(
            tree: active,
            currentPath: TreePath.empty,
            showAnnotationPanel: true,
            onCommentChanged: (path, comment) =>
                active.setComment(path, comment),
          ),
        ),
      );
      await tester.pumpWidget(host());
      await tester.enterText(find.byType(TextField), 'Edited first note');
      // No debounce interval passes before the controller changes chapters.
      active = second;
      await tester.pumpWidget(host());
      await tester.pump(const Duration(milliseconds: 500));
      expect(first.rootComment, 'Edited first note');
      expect(second.rootComment, 'Second note');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Second note',
      );
      await tester.enterText(find.byType(TextField), 'Edited second note');
      active = first;
      await tester.pumpWidget(host());
      expect(first.rootComment, 'Edited first note');
      expect(second.rootComment, 'Edited second note');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Edited first note',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('variation comment editing retains its path and PGN tokens', (
    tester,
  ) async {
    final tree = MoveTree.fromPgn(
      '1. e4 (1. d4 {Original note. [%cal Gd2d4]}) e5 *',
    );
    TreePath? jumped;
    TreePath? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractivePgnEditor(
            tree: tree,
            currentPath: TreePath.empty,
            onJump: (path) => jumped = path,
            onCommentChanged: (path, comment) {
              saved = path;
              tree.setComment(path, comment);
            },
          ),
        ),
      ),
    );
    await tester.tap(
      find.byWidgetPredicate((w) => w is MoveChip && w.san == 'd4'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit Comment'));
    await tester.pumpAndSettle();
    expect(jumped, const TreePath([1]));
    expect(find.byType(PgnCommentEditor), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Updated note.');
    await tester.tap(find.byTooltip('Save comment'));
    await tester.pumpAndSettle();
    expect(saved, const TreePath([1]));
    expect(tree.nodeAt(saved!)!.comment, contains('Updated note.'));
    expect(tree.nodeAt(saved!)!.comment, contains('[%cal Gd2d4]'));
    expect(tree.roots.first.comment, isNull);
    expect(find.byType(PgnCommentEditor), findsNothing);
    expect(find.textContaining('Updated note.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
