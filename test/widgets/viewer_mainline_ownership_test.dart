import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'old annotation callbacks cannot edit the same index after game replacement',
    (tester) async {
      final control = PgnViewerWidgetController();
      final saves = <String>[];
      Widget host(String pgn) => MaterialApp(
        home: Scaffold(
          body: PgnViewerWidget(
            controller: control,
            pgnText: pgn,
            editMode: true,
            onCommentsChanged: saves.add,
          ),
        ),
      );
      await tester.pumpWidget(host('1. e4 e5 *'));
      await tester.pumpAndSettle();
      control.goToMainLineIndex(1);
      await tester.pumpAndSettle();
      final oldPanel = tester.widget<PgnAnnotationPanel>(
        find.byType(PgnAnnotationPanel),
      );
      await tester.pumpWidget(host('1. d4 d5 *'));
      await tester.pumpAndSettle();
      control.goToMainLineIndex(1);
      await tester.pumpAndSettle();
      oldPanel.onCommentChanged('Late note for e4');
      oldPanel.onToggleNag(2);
      await tester.pumpAndSettle();
      expect(saves, isEmpty);
      final panel = tester.widget<PgnAnnotationPanel>(
        find.byType(PgnAnnotationPanel),
      );
      expect(panel.comment, isEmpty);
      expect(panel.nags, isEmpty);
      expect(control.mainLineMoves, ['d4', 'd5']);
      panel.onCommentChanged('Current d4 note');
      await tester.pumpAndSettle();
      expect(parsePgnGame(saves.single).moves.children.single.data.comments, [
        'Current d4 note',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('sideline introductions render before the move they introduce', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PgnViewerWidget(
            pgnText:
                '1. e4 e5 ({Sideline introduction} 1... c5 {Trailing note}) *',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final intro = find.textContaining(
      'Sideline introduction',
      findRichText: true,
    );
    final move = find.text('c5', findRichText: true);
    final note = find.textContaining('Trailing note', findRichText: true);
    expect(intro, findsOneWidget);
    expect(move, findsOneWidget);
    expect(tester.getTopLeft(intro).dy, lessThan(tester.getTopLeft(move).dy));
    expect(tester.getTopLeft(move).dy, lessThan(tester.getTopLeft(note).dy));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
