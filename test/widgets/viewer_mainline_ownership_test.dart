import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'typing a sideline note then a glyph saves both through host echo',
    (tester) async {
      var pgn = '1. e4 e5 (1... c5) *';
      final saves = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => PgnViewerWidget(
                pgnText: pgn,
                editMode: true,
                persistMoves: true,
                onCommentsChanged: (value) {
                  saves.add(value);
                  update(() => pgn = value);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('c5', findRichText: true));
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(PgnAnnotationPanel),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'Combined note');
      await tester.tap(find.byTooltip('Good move'));
      // A glyph save includes the visible draft without waiting for its timer.
      expect(saves.last, contains('Combined note'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final node = parsePgnGame(
        saves.last,
      ).moves.children.first.children[1].data;
      expect(node.comments, ['Combined note']);
      expect(node.nags, [1]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'focused variation refreshes snapshots and rejects stale panels',
    (tester) async {
      final control = PgnViewerWidgetController();
      final saves = <String>[];
      Widget host(String pgn) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PgnViewerWidget(
            controller: control,
            pgnText: pgn,
            editMode: true,
            onCommentsChanged: saves.add,
          ),
        ),
      );
      const first = '1. e4 e5 (1... c5 {Original note} 2. Nf3) *';
      await tester.pumpWidget(host(first));
      await tester.pumpAndSettle();
      final root = control
          .buildSolitaireScript(fromMainlinePly: 0, includeVariations: true)!
          .steps
          .firstWhere((step) => step.node != null)
          .node!;
      control.goToVariationNode(root, 1);
      await tester.pumpAndSettle();
      expect(control.focusVariation(), isTrue);
      await tester.pumpAndSettle();
      final oldPanel = tester.widget<PgnAnnotationPanel>(
        find.byType(PgnAnnotationPanel),
      );
      oldPanel.onCommentChanged('Updated focused note');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Updated focused note', findRichText: true),
        findsWidgets,
      );
      expect(root.comment, 'Original note');
      expect(saves, hasLength(1));
      await tester.pumpWidget(host('1. d4 d5 (1... Nf6) *'));
      await tester.pumpAndSettle();
      saves.clear();
      oldPanel.onCommentChanged('Late old-game note');
      oldPanel.onToggleNag(2);
      await tester.pumpAndSettle();
      expect(saves, isEmpty);
      expect(
        find.textContaining('Late old-game note', findRichText: true),
        findsNothing,
      );
      expect(control.mainLineMoves, ['d4', 'd5']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'old annotation callbacks cannot edit the same index after game replacement',
    (tester) async {
      final control = PgnViewerWidgetController();
      final saves = <String>[];
      Widget host(String pgn) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
