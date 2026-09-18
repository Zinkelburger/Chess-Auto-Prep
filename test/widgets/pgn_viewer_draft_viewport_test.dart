import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_game_view.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'an inline draft survives row eviction and saves to its original move',
    (tester) async {
      final moves = List.generate(
        2000,
        (i) => PgnMoveSnapshot.capture(
          PgnNodeData(
            san: i.isEven ? 'Nf3' : 'Nf6',
            comments: ['Source note $i'],
          ),
        ),
      );
      var selected = 1;
      int? editing = 0;
      late StateSetter update;
      final saves = <(int, String)>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return PgnMovetextView(
                  game: null,
                  moveHistory: moves,
                  variationsByPly: const {},
                  mainLineIndex: selected,
                  analysisPath: const [],
                  editingCommentIndex: editing,
                  canEditComments: true,
                  onMainLineMoveClicked: (_) {},
                  onShowMoveContextMenu: (_, _) {},
                  onSaveComment: (i, text) {
                    saves.add((i, text));
                    setState(() => editing = null);
                  },
                  onCancelEditingComment: () => setState(() => editing = null),
                  onGoToAnalysisNode: (_, _) {},
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'Draft retained across distant navigation',
      );
      update(() => selected = 1999);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      update(() => selected = 1);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Draft retained across distant navigation',
      );
      await tester.tap(find.byTooltip('Save comment'));
      await tester.pumpAndSettle();
      expect(saves, [(0, 'Draft retained across distant navigation')]);
      expect(tester.takeException(), isNull);
    },
  );
}
