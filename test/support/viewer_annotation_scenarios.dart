import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';

void viewerAnnotationScenarios() {
  const original =
      '1. e4 e5 (1... c5 2. Nf3 d6 (2... Nc6 \$1 {Deep original})) *';
  testWidgets(
    'incoming nested notes update the focused reader and serialize on its next edit',
    (tester) async {
      final control = PgnViewerWidgetController();
      final saves = <String>[];
      var loads = 0;
      Widget host(String pgn) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PgnViewerWidget(
            pgnText: pgn,
            controller: control,
            editMode: true,
            onGameLoaded: () => loads++,
            onCommentsChanged: saves.add,
          ),
        ),
      );
      await tester.pumpWidget(host(original));
      await tester.pumpAndSettle();
      final target = control
          .buildSolitaireScript(fromMainlinePly: 0, includeVariations: true)!
          .steps
          .firstWhere((step) => step.node?.san == 'Nc6')
          .node!;
      control.goToVariationNode(target, 1);
      await tester.pumpAndSettle();
      expect(control.focusVariation(), isTrue);
      await tester.pumpAndSettle();
      final fen = control.currentFen;
      await tester.pumpWidget(
        host(
          '1. e4 e5 (1... c5 2. Nf3 d6 ({Deep introduction} 2... Nc6 {Incoming nested note})) *',
        ),
      );
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(control.currentFen, fen);
      expect(
        find.textContaining('Incoming nested note', findRichText: true),
        findsWidgets,
      );
      expect(
        find.textContaining('Deep original', findRichText: true),
        findsNothing,
      );
      final panel = tester.widget<PgnAnnotationPanel>(
        find.byType(PgnAnnotationPanel),
      );
      expect(panel.comment, 'Incoming nested note');
      expect(panel.nags, isEmpty);
      expect(target.comment, 'Deep original');
      expect(target.nags, [1]);
      panel.onToggleNag(2);
      await tester.pumpAndSettle();
      final game = parsePgnGame(saves.single);
      final saved = game
          .moves
          .children
          .first
          .children[1]
          .children
          .single
          .children[1]
          .data;
      expect(saved.san, 'Nc6');
      expect(saved.comments, ['Incoming nested note']);
      expect(saved.startingComments, ['Deep introduction']);
      expect(saved.nags, [2]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a changed nested branch reloads instead of retaining obsolete moves',
    (tester) async {
      final control = PgnViewerWidgetController();
      var loads = 0;
      Widget host(String pgn) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PgnViewerWidget(
            pgnText: pgn,
            controller: control,
            onGameLoaded: () => loads++,
          ),
        ),
      );
      await tester.pumpWidget(host(original));
      await tester.pumpAndSettle();
      final target = control
          .buildSolitaireScript(fromMainlinePly: 0, includeVariations: true)!
          .steps
          .firstWhere((step) => step.node?.san == 'Nc6')
          .node!;
      control.goToVariationNode(target, 1);
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        host('1. e4 e5 (1... c5 2. Nf3 d6 (2... Nf6 {Replacement})) *'),
      );
      await tester.pumpAndSettle();
      expect(loads, 2);
      final branches = control
          .buildSolitaireScript(fromMainlinePly: 0, includeVariations: true)!
          .steps;
      expect(branches.where((step) => step.node?.san == 'Nc6'), isEmpty);
      expect(branches.where((step) => step.node?.san == 'Nf6'), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
