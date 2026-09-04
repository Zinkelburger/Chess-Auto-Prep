/// Movetext layout regressions after own-row comments/variations.
///
/// When a comment or variation breaks the mainline Wrap run, the next Black
/// move must keep its `N...` prefix (same as start-from-Black games).
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
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

  testWidgets('notation is mono while comment prose remains the UI face', (
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

    var sawProse = false;
    row.text.visitChildren((span) {
      if (span.toPlainText().contains('a fighting choice')) {
        sawProse = true;
        expect(span.style?.fontFamily, 'Inter');
      }
      return true;
    });
    expect(sawProse, isTrue);
    final c5 = tester
        .widgetList<MoveChip>(find.byType(MoveChip))
        .singleWhere((chip) => chip.san == 'c5');
    expect(c5.sanStyle.fontFamily, 'SourceCodePro');
  });

  testWidgets('brief simple variation stays inline and parenthesized', (
    tester,
  ) async {
    final c5 = MoveNode(san: 'c5', fen: 'f1');
    c5.children.add(MoveNode(san: 'Nf3', fen: 'f2'));
    await pumpMovetext(
      tester,
      moveHistory: [
        PgnNodeData(san: 'e4'),
        PgnNodeData(san: 'e5'),
      ],
      variationsByPly: {
        1: [c5],
      },
    );
    await tester.pump();

    final texts = richPlainTexts(tester);
    expect(
      texts.any(
        (text) =>
            text.contains('(1...') && text.contains('2.') && text.contains(')'),
      ),
      isTrue,
      reason: 'short variation should read as an inline aside: $texts',
    );
  });

  testWidgets('commented variation gets a separate unbracketed row', (
    tester,
  ) async {
    await pumpMovetext(
      tester,
      moveHistory: [
        PgnNodeData(san: 'e4'),
        PgnNodeData(san: 'e5'),
      ],
      variationsByPly: {
        1: [MoveNode(san: 'c5', fen: 'f1', comment: 'The Sicilian')],
      },
    );
    await tester.pump();

    final row = richPlainTexts(
      tester,
    ).firstWhere((text) => text.contains('The Sicilian'));
    expect(row, isNot(contains('(')));
    expect(row, isNot(contains(')')));
    expect(
      tester
          .widgetList<MoveChip>(find.byType(MoveChip))
          .any((chip) => chip.san == 'c5'),
      isTrue,
    );
  });

  testWidgets('long plain comments receive a dedicated reading surface', (
    tester,
  ) async {
    final longComment = List.filled(
      35,
      'This explanation needs room to breathe in a course chapter.',
    ).join(' ');
    await pumpPgn(tester, '1. d4 {$longComment} d5 *');
    await tester.pumpAndSettle();

    final text = find.textContaining(
      'This explanation needs room',
      findRichText: true,
    );
    expect(text, findsOneWidget);
    expect(
      find.ancestor(of: text, matching: find.byType(Container)),
      findsWidgets,
    );
  });

  testWidgets('sub-variations get their own row, indented past their parent', (
    tester,
  ) async {
    // 1. e4 (1. d4 d5 (1... Nf6) 2. c4) e5
    //          ^ depth 1            ^ depth 2, own row
    final d4 = MoveNode(san: 'd4', fen: 'after-d4');
    final d5 = MoveNode(san: 'd5', fen: 'after-d5');
    d4.children.add(d5);
    d5.children.add(MoveNode(san: 'c4', fen: 'after-c4'));
    d5.children.add(MoveNode(san: 'Nf6', fen: 'after-Nf6'));

    await pumpMovetext(
      tester,
      moveHistory: [
        PgnNodeData(san: 'e4'),
        PgnNodeData(san: 'e5'),
      ],
      variationsByPly: {
        0: [d4],
      },
    );
    await tester.pump();

    // The sub-variation is on a row of its own, not spliced into its parent.
    final nf6Row = find.ancestor(
      of: find.text('Nf6', findRichText: true),
      matching: find.byType(RichText),
    );
    expect(nf6Row, findsWidgets);
    final rowTexts = richPlainTexts(tester);
    expect(
      rowTexts.any((t) => t.contains('Nf6') && !t.contains('c4')),
      isTrue,
      reason:
          'sub-variation should not share a row with the parent line; '
          'got: $rowTexts',
    );

    // ...and it is indented further left-padded than the depth-1 row it hangs
    // off, so depth survives at a glance.
    double leftPadOf(String san) {
      final pad = tester
          .widgetList<Padding>(
            find.ancestor(
              of: find.text(san, findRichText: true),
              matching: find.byType(Padding),
            ),
          )
          .map((p) => p.padding.resolve(TextDirection.ltr).left)
          .fold<double>(0, (a, b) => a + b);
      return pad;
    }

    expect(leftPadOf('Nf6'), greaterThan(leftPadOf('d4')));
  });

  testWidgets('sidelines past depth 2 fold behind a disclosure stub', (
    tester,
  ) async {
    // Depth-3 alternatives must not render until the reader opens them.
    final d4 = MoveNode(san: 'd4', fen: 'f1'); // depth 1
    final d5 = MoveNode(san: 'd5', fen: 'f2');
    d4.children.add(d5);
    final c4 = MoveNode(san: 'c4', fen: 'f3');
    final nf3 = MoveNode(san: 'Nf3', fen: 'f4'); // depth 2 alternative
    d5.children.addAll([c4, nf3]);
    // Branch under the depth-2 line -> its alternatives land at depth 3.
    final e6 = MoveNode(san: 'e6', fen: 'f5');
    final dxc4 = MoveNode(san: 'dxc4', fen: 'f6');
    nf3.children.addAll([e6, dxc4]);

    await pumpMovetext(
      tester,
      moveHistory: [PgnNodeData(san: 'e4')],
      variationsByPly: {
        0: [d4],
      },
    );
    await tester.pump();

    expect(find.text('dxc4', findRichText: true), findsNothing);
    expect(find.textContaining('1 more line'), findsOneWidget);

    await tester.tap(find.textContaining('1 more line'));
    await tester.pump();

    expect(find.text('dxc4', findRichText: true), findsOneWidget);
  });

  testWidgets(
    'Chessable dummy intro is promoted; comments stay upright, Z0 is hidden',
    (tester) async {
      await pumpPgn(
        tester,
        '1. Z0 ({Welcome to this course} 1. d4 {We intend to play} '
        'Z0 2. Nf3 {and} Z0 3. e3 {next.}) *',
      );
      await tester.pumpAndSettle();

      expect(find.text('d4'), findsWidgets);
      expect(find.text('Nf3'), findsWidgets);
      expect(find.text('e3'), findsWidgets);
      expect(
        find.textContaining('Welcome to this course', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('We intend to play', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('next.', findRichText: true), findsOneWidget);
      expect(find.text('Z0'), findsNothing);
      expect(find.text('--'), findsNothing);

      var sawWelcome = false;
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          if (span is TextSpan &&
              (span.text?.contains('Welcome to this course') ?? false)) {
            sawWelcome = true;
            expect(span.style?.fontStyle, anyOf(isNull, FontStyle.normal));
          }
          return true;
        });
      }
      expect(sawWelcome, isTrue);
    },
  );
}
