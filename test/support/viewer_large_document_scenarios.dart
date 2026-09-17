import 'package:chess_auto_prep/design_system/layout/anchored_document_viewport.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void viewerLargeDocumentScenarios() {
  testWidgets(
    'Viewer bounds 20000 annotated plies and mounts distant selections immediately',
    (tester) async {
      final pgn = StringBuffer('[Event "Large Viewer renewal"]\n\n');
      const sans = ['Nf3', 'Nf6', 'Ng1', 'Ng8'];
      for (var i = 0; i < 20000; i++) {
        if (i.isEven) pgn.write('${i ~/ 2 + 1}. ');
        pgn.write('${sans[i % 4]} ');
        if (i % 100 == 0) {
          pgn.write('{Passage $i. A stable explanatory note.} ');
        }
      }
      pgn.write('*');
      final control = PgnViewerWidgetController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PgnViewerWidget(pgnText: pgn.toString(), controller: control),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final viewport = find.byType(AnchoredDocumentViewport);
      final rows = tester
          .widget<AnchoredDocumentViewport>(viewport)
          .rows
          .revision;
      for (final ply in [19998, 101, 10001, 1, 20000]) {
        control.goToMainLineIndex(ply);
        await tester.pump();
        expect(control.mainLineIndex, ply);
        final view = tester.widget<PgnMovetextView>(
          find.byType(PgnMovetextView),
        );
        final selected = find.byKey(view.currentMoveKey!);
        expect(selected, findsOneWidget);
        final bounds = tester.getRect(viewport);
        expect(
          bounds.overlaps(tester.getRect(selected)),
          isTrue,
          reason: 'ply $ply must be mounted and visible in its first frame',
        );
        expect(find.byType(MoveChip).evaluate().length, lessThan(300));
        expect(
          tester.widget<AnchoredDocumentViewport>(viewport).rows.revision,
          same(rows),
          reason: 'navigation must reuse the immutable document index',
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Viewer bounds a 20000-ply sideline and retains focus navigation',
    (tester) async {
      final pgn = StringBuffer('1. e4 (');
      const sans = ['Nf3', 'Nf6', 'Ng1', 'Ng8'];
      for (var i = 0; i < 20000; i++) {
        if (i.isEven) pgn.write('${i ~/ 2 + 1}. ');
        pgn.write('${sans[i % 4]} ');
        if (i % 100 == 0) pgn.write('{Sideline passage $i.} ');
      }
      pgn.write(') e5 *');
      final control = PgnViewerWidgetController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PgnViewerWidget(pgnText: pgn.toString(), controller: control),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final view = tester.widget<PgnMovetextView>(find.byType(PgnMovetextView));
      var node = view.variationsByPly[0]!.single;
      while (node.children.isNotEmpty) {
        node = node.children.first;
      }
      control.goToVariationNode(node, 0);
      await tester.pump();
      expect(control.currentFen, node.fen);
      expect(find.byType(MoveChip).evaluate().length, lessThan(300));
      expect(control.focusVariation(), isTrue);
      await tester.pumpAndSettle();
      expect(control.currentFen, node.fen);
      expect(find.byType(MoveChip).evaluate().length, lessThan(300));
      expect(control.returnToParentLine(), isTrue);
      await tester.pumpAndSettle();
      expect(control.inVariation, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
