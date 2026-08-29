/// The editor's rendered movetext survives cursor moves: stepping through a
/// line repaints the two chips whose selection changed and nothing else.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';

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
}
