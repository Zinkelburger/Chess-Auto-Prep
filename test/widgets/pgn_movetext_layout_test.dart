/// Movetext layout regressions after own-row comments/variations.
///
/// When a comment or variation breaks the mainline Wrap run, the next Black
/// move must keep its `N...` prefix (same as start-from-Black games).
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPgn(WidgetTester tester, String pgn) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PgnViewerWidget(pgnText: pgn)),
      ),
    );
  }

  Future<void> pumpMovetext(
    WidgetTester tester, {
    required List<PgnNodeData> moveHistory,
    Map<int, List<MoveNode>> variationsByPly = const {},
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PgnMovetextView(
              game: null,
              moveHistory: moveHistory,
              variationsByPly: variationsByPly,
              mainLineIndex: 0,
              analysisPath: const [],
              editingCommentIndex: null,
              canEditComments: false,
              onMainLineMoveClicked: (_) {},
              onShowMoveContextMenu: (_, _) {},
              onSaveComment: (_, _) {},
              onCancelEditingComment: () {},
              onGoToAnalysisNode: (_, _) {},
            ),
          ),
        ),
      ),
    );
  }

  List<String> richPlainTexts(WidgetTester tester) => tester
      .widgetList<RichText>(find.byType(RichText))
      .map((r) => r.text.toPlainText())
      .where((t) => t.trim().isNotEmpty)
      .toList();

  testWidgets('black move after white comment keeps 1... prefix', (
    tester,
  ) async {
    await pumpPgn(tester, '1. e4 {note} e5 2. Nf3 *');
    await tester.pumpAndSettle();

    expect(find.textContaining('1...', findRichText: true), findsOneWidget);
    expect(find.textContaining('note', findRichText: true), findsOneWidget);
  });

  testWidgets('black move after variation keeps 1... prefix', (tester) async {
    await pumpMovetext(
      tester,
      moveHistory: [
        PgnNodeData(san: 'e4'),
        PgnNodeData(san: 'e5'),
      ],
      variationsByPly: {
        1: [MoveNode(san: 'c5', fen: 'after-c5')],
      },
    );
    await tester.pump();

    final plain = richPlainTexts(tester);
    expect(
      plain.any((t) => t.contains('c5') || t.contains('( ')),
      isTrue,
      reason: 'sideline row should render; got: $plain',
    );
    expect(
      plain.any((t) => t.contains('1...')),
      isTrue,
      reason: 'mainline Black after sideline needs 1...; got: $plain',
    );
  });

  testWidgets('plain comment sits outside the mainline move RichText', (
    tester,
  ) async {
    await pumpPgn(tester, '1. d4 {Opening idea} Nf6 *');
    await tester.pumpAndSettle();

    final commentFinder = find.textContaining(
      'Opening idea',
      findRichText: true,
    );
    expect(commentFinder, findsOneWidget);

    // Comment is not glued into the same RichText as "1. d4".
    final commentRt = tester.widget<RichText>(commentFinder);
    expect(commentRt.text.toPlainText(), isNot(contains('1.')));
    expect(commentRt.text.toPlainText(), isNot(contains('d4')));
  });

  testWidgets('variation comment prose stays proportional, moves monospace', (
    tester,
  ) async {
    await pumpMovetext(
      tester,
      moveHistory: [
        PgnNodeData(san: 'e4'),
        PgnNodeData(san: 'e5'),
      ],
      variationsByPly: {
        1: [MoveNode(san: 'c5', fen: 'after-c5', comment: 'a fighting choice')],
      },
    );
    await tester.pump();

    final rowFinder = find.textContaining(
      'a fighting choice',
      findRichText: true,
    );
    expect(rowFinder, findsOneWidget);
    final row = tester.widget<RichText>(rowFinder);

    // The row root must not set a fontFamily: comment prose (which sets no
    // family of its own) would inherit it and render as code. The bracket /
    // move spans opt into monospace explicitly instead.
    final rootStyle = row.text.style;
    expect(
      rootStyle?.fontFamily,
      isNull,
      reason: 'variation row root leaked a fontFamily into comment prose',
    );

    var sawMonospaceSpan = false;
    row.text.visitChildren((span) {
      if (span is TextSpan && span.style?.fontFamily == 'monospace') {
        sawMonospaceSpan = true;
      }
      return true;
    });
    expect(
      sawMonospaceSpan,
      isTrue,
      reason: 'bracket/move-number spans should still set monospace',
    );
  });
}
