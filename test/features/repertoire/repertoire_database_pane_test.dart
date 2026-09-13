import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_database_pane.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/widgets/opening_tree_widget.dart';
import 'package:chess_auto_prep/widgets/opening_explorer/opening_explorer_panel.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'database offers saved continuations and opening explorer in one surface',
    (tester) async {
      String? played;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepertoireDatabasePane(
              tree: OpeningTree()..appendLine(['e4']),
              currentMoveSequence: const [],
              fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
              repertoireMovesAtPosition: () => {'e4'},
              onPlayMove: (move) => played = move,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(OpeningTreeWidget), findsOneWidget);
      expect(find.byTooltip('Copy moves'), findsNothing);
      await tester.tap(find.text('e4').first);
      expect(played, 'e4');
      await tester.tap(find.text('Opening explorer'));
      await tester.pump();
      expect(find.byType(OpeningExplorerPanel), findsOneWidget);
      expect(find.byType(OpeningTreeWidget), findsNothing);
      await tester.tap(find.text('Repertoire').first);
      await tester.pump();
      expect(find.byType(OpeningTreeWidget), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
