import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/models/trap_reply.dart';
import 'package:chess_auto_prep/features/traps/services/trap_line_builder.dart';
import 'package:chess_auto_prep/features/traps/widgets/traps_browser.dart';
import 'package:chess_auto_prep/models/move_tree.dart';

TrapLineInfo _scandiTrap() {
  return const TrapLineInfo(
    movesSan: [
      'e4',
      'd5',
      'exd5',
      'Qxd5',
      'Nc3',
      'Qa5',
      'Bc4',
      'Nf6',
      'd3',
      'Bg4',
      'f3',
      'Bh5',
      'Bd2',
    ],
    trapScore: 0.5,
    popularProb: 0.4,
    popularMove: 'Nc6',
    bestMove: 'e6',
    popularEvalCp: 252,
    bestEvalCp: 10,
    evalDiffCp: 200,
    cumulativeProb: 0.01,
    trickSurplus: 0.1,
    expectimaxValue: 0.59,
    wpEval: 0.51,
    fen: 'rn2kb1r/ppp1pppp/5n2/q6b/2B5/2NP1P2/PPPB2PP/R2QK1NR b KQkq - 2 7',
    refutationMove: 'Nd5',
    refutationEvalCp: 260,
    allReplies: [
      TrapReply(
        san: 'Nc6',
        probability: 0.4,
        evalAfterCp: 252,
        classification: TrapReplyClass.blunder,
      ),
      TrapReply(
        san: 'e6',
        probability: 0.3,
        evalAfterCp: 10,
        classification: TrapReplyClass.good,
      ),
    ],
  );
}

void main() {
  group('TrapLineBuilder', () {
    test('builds annotated tree with cursor at the trap position', () {
      final trap = _scandiTrap();
      final built = TrapLineBuilder.build(trap);

      expect(built, isNotNull);
      final (:tree, :cursor) = built!;

      expect(cursor.length, trap.movesSan.length);
      expect(tree.fenAt(cursor), trap.fen);
      expect(tree.nodeAt(cursor)!.comment, contains('Nc6'));

      // Popular blunder is the mainline continuation, annotated + punished.
      final blunder = tree.nodeAt(cursor)!.children.first;
      expect(blunder.san, 'Nc6');
      expect(blunder.nags, [4]);
      expect(blunder.comment, contains('40%'));
      expect(blunder.children.first.san, 'Nd5');

      // Best defence is present as a variation.
      final sans = tree.nodeAt(cursor)!.children.map((c) => c.san);
      expect(sans, contains('e6'));
    });

    test('recovers a trap-rooted annotated line when moves cannot replay', () {
      // Same trap, but the stored SAN lead-up is corrupt/stale ("Zz9" cannot
      // parse), so the full replay fails. The FEN is still good, so we should
      // recover a tree rooted at the trap position with annotated replies.
      final trap = TrapLineInfo(
        movesSan: const ['e4', 'd5', 'Zz9'],
        trapScore: 0.5,
        popularProb: 0.4,
        popularMove: 'Nc6',
        bestMove: 'e6',
        popularEvalCp: 252,
        bestEvalCp: 10,
        evalDiffCp: 200,
        cumulativeProb: 0.01,
        trickSurplus: 0.1,
        expectimaxValue: 0.59,
        wpEval: 0.51,
        fen: 'rn2kb1r/ppp1pppp/5n2/q6b/2B5/2NP1P2/PPPB2PP/R2QK1NR b KQkq - 2 7',
        refutationMove: 'Nd5',
        refutationEvalCp: 260,
        allReplies: const [
          TrapReply(
            san: 'Nc6',
            probability: 0.4,
            evalAfterCp: 252,
            classification: TrapReplyClass.blunder,
          ),
        ],
      );

      final built = TrapLineBuilder.build(trap);
      expect(built, isNotNull);
      final (:tree, :cursor) = built!;

      // Rooted at the trap position: no lead-up moves, board on the trap FEN.
      expect(cursor, TreePath.empty);
      expect(tree.fenAt(cursor), trap.fen);

      // The annotated blunder + punish still survive.
      final blunder = tree.roots.first;
      expect(blunder.san, 'Nc6');
      expect(blunder.nags, [4]);
      expect(blunder.children.first.san, 'Nd5');
    });

    test('legacy trap without allReplies still gets both key replies', () {
      final trap = TrapLineInfo(
        movesSan: const ['e4', 'e5'],
        trapScore: 0.3,
        popularProb: 0.5,
        popularMove: 'Nf3',
        bestMove: 'Nc3',
        popularEvalCp: 50,
        bestEvalCp: 20,
        evalDiffCp: 30,
        cumulativeProb: 0.1,
        trickSurplus: 0.05,
        expectimaxValue: 0.55,
        wpEval: 0.5,
      );
      final built = TrapLineBuilder.build(trap);
      expect(built, isNotNull);
      final sans = built!.tree.nodeAt(built.cursor)!.children.map((c) => c.san);
      expect(sans, containsAll(['Nf3', 'Nc3']));
    });
  });

  testWidgets('tapping a trap row loads the annotated line onto the board', (
    tester,
  ) async {
    final controller = RepertoireController();
    final trap = _scandiTrap();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrapsBrowser(
            traps: [trap],
            boardPreview: BoardPreviewController(),
            onTrapSelected: (t) {
              final built = TrapLineBuilder.build(t)!;
              controller.loadAnnotatedTree(built.tree, cursor: built.cursor);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap the trap row (the '#1' rank label lives inside the InkWell).
    await tester.tap(find.text('#1'));
    await tester.pumpAndSettle();

    expect(controller.moveHistory, trap.movesSan);
    expect(controller.fen, trap.fen);
    // The opponent's blunder is explorable one ply forward.
    expect(
      controller.tree.nodeAt(TreePath(controller.path.toList()))!.children,
      isNotEmpty,
    );
  });
}
