import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/utils/pgn_nags.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';

enum _Surface { editor, mainline, variation }

void main() {
  for (final surface in _Surface.values) {
    testWidgets('${surface.name}: NAGs and borderless states keep geometry', (
      tester,
    ) async {
      const nags = [1, 14, 200];
      final tree = MoveTree.fromMoves(['e4']);
      final node = tree.roots.single..nags = nags;
      var jumps = 0;

      Future<void> pumpSurface(bool selected) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: surface == _Surface.editor
                  ? InteractivePgnEditor(
                      tree: tree,
                      currentPath: selected
                          ? const TreePath([0])
                          : TreePath.empty,
                      onJump: (path) {
                        expect(path, const TreePath([0]));
                        jumps++;
                      },
                    )
                  : PgnMovetextView(
                      game: null,
                      moveHistory: surface == _Surface.mainline
                          ? [PgnNodeData(san: 'e4', nags: nags)]
                          : const [],
                      variationsByPly: surface == _Surface.variation
                          ? {
                              0: [node],
                            }
                          : const {},
                      mainLineIndex: selected ? 1 : 0,
                      analysisPath: selected && surface == _Surface.variation
                          ? [node]
                          : const [],
                      editingCommentIndex: null,
                      canEditComments: false,
                      onMainLineMoveClicked: (_) => jumps++,
                      onShowMoveContextMenu: (_, _) {},
                      onSaveComment: (_, _) {},
                      onCancelEditingComment: () {},
                      onGoToAnalysisNode: (actual, ply) {
                        expect(actual, same(node));
                        expect(ply, 0);
                        jumps++;
                      },
                    ),
            ),
          ),
        ),
      );

      final chipFinder = find.byType(MoveChip);
      BoxDecoration paintedDecoration() =>
          tester
                  .widget<Container>(
                    find.descendant(
                      of: chipFinder,
                      matching: find.byType(Container),
                    ),
                  )
                  .decoration!
              as BoxDecoration;

      await pumpSurface(false);
      final chip = tester.widget<MoveChip>(chipFinder);
      expect(chip.nagSuffix, '!⩲\$200');
      expect(chip.nagStyle.color, nagColor(1));
      expect(chip.nagStyle.fontWeight, FontWeight.bold);
      expect(chip.nagStyle.fontSize, 15);
      final originalSize = tester.getSize(chipFinder);
      final idle = paintedDecoration();
      expect(idle.color, isNull);
      expect((idle.border! as Border).top.color, Colors.transparent);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(tester.getCenter(chipFinder));
      await tester.pump();
      expect(paintedDecoration().color, AppColors.pgnMoveHoverBg);
      expect(paintedDecoration().border, idle.border);
      expect(tester.getSize(chipFinder), originalSize);

      await tester.tap(chipFinder);
      expect(jumps, 1);
      await pumpSurface(true);
      expect(paintedDecoration().color, AppColors.pgnMoveCurrentBg);
      expect(paintedDecoration().border, idle.border);
      expect(tester.getSize(chipFinder), originalSize);
      expect(tester.widget<MoveChip>(chipFinder).nagStyle, chip.nagStyle);

      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(paintedDecoration().color, AppColors.pgnMoveCurrentBg);
      expect(tester.getSize(chipFinder), originalSize);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });
  }
}
