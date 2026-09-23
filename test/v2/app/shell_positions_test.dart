import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/features/library/library_panel.dart';
import 'package:chess_auto_prep/v2/workspace/finds_panel.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

const afterE4E5 = Fen(
  'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
);

SearchNode leaf(String name, int cp) =>
    HorizonNode(fen: Fen('$name w - - 0 1'), evalForUs: Eval(cp));

/// The list column's second list: what the searches pointed out, one click
/// from the board.
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Future<void> ctrlP(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+P swaps the list for the Positions; a click puts the '
      'line on a board at the position', (tester) async {
    // A search from after 1.e4 e5 in which only 2.Nf3 holds.
    await w.parts.workspace.finds.record(
      OurNode.over(
        fen: afterE4E5,
        evalForUs: const Eval(30),
        candidates: [
          CandidateMove(
            move: const MoveRef(uci: 'g1f3', san: 'Nf3'),
            child: leaf('nf3', 30),
          ),
          CandidateMove(
            move: const MoveRef(uci: 'd1h5', san: 'Qh5'),
            child: leaf('qh5', -200),
          ),
        ],
      ),
      rootFen: Fen.initial,
      prefix: const ['e4', 'e5'],
      side: Side.white,
      elo: 1800,
    );
    await w.pumpShell(tester);
    expect(find.byType(LibraryPanel), findsOneWidget);

    await ctrlP(tester);
    expect(find.byType(FindsPanel), findsOneWidget);
    expect(find.byType(LibraryPanel), findsNothing);
    expect(
      find.textContaining('e5 2.Nf3!', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(find.textContaining('e5 2.Nf3!', findRichText: true));
    await tester.pumpAndSettle();
    expect(w.session.isScratch, isTrue);
    expect(w.session.fen, afterE4E5);
    expect(w.session.currentMove?.san, 'e5');
    expect(w.session.orientation, Side.white);

    await ctrlP(tester);
    expect(find.byType(LibraryPanel), findsOneWidget);
  });

  testWidgets('the top bar button switches too, and says its key', (
    tester,
  ) async {
    await w.pumpShell(tester);
    await tester.tap(find.byTooltip('What the searches found (Ctrl+P)'));
    await tester.pumpAndSettle();
    expect(find.byType(FindsPanel), findsOneWidget);
    expect(find.textContaining('Nothing found yet'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to the list (Ctrl+P)'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryPanel), findsOneWidget);
  });
}
