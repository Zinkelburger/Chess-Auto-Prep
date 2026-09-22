import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_game_view.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/utils/pgn_nags.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';

enum _Surface { editor, mainline, variation }

Color _paintedBackground(WidgetTester tester, Finder text) {
  var color = Colors.transparent;
  tester.element(text).visitAncestorElements((element) {
    final widget = element.widget;
    Color? behind;
    if (widget is DecoratedBox && widget.decoration is BoxDecoration) {
      behind = (widget.decoration as BoxDecoration).color;
    } else if (widget is Material) {
      behind = widget.color;
    }
    if (behind != null) color = Color.alphaBlend(color, behind);
    return color.a < 1;
  });
  expect(color.a, 1, reason: 'the assertion uses the painted opaque surface');
  return color;
}

double _contrast(Color a, Color b) {
  final first = a.computeLuminance() + .05;
  final second = b.computeLuminance() + .05;
  return first > second ? first / second : second / first;
}

void main() {
  for (final light in [false, true]) {
    testWidgets(
      'all NAG inks contrast with rendered move and glyph fills (${light ? 'light' : 'dark'})',
      (tester) async {
        final theme = light ? AppTheme.light() : AppTheme.dark();
        final tree = MoveTree.fromMoves(['e4']);
        for (final nag in kMoveNags) {
          tree.roots.single.nags = [nag.id];
          tree.markMutated();
          for (final selected in [false, true]) {
            await tester.pumpWidget(
              MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,

                theme: theme,
                home: Scaffold(
                  body: InteractivePgnEditor(
                    tree: tree,
                    currentPath: selected
                        ? const TreePath([0])
                        : TreePath.empty,
                    showAnnotationPanel: true,
                    onToggleNag: (_, _) {},
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final chip = tester.widget<MoveChip>(find.byType(MoveChip));
            expect(chip.nagSuffix, nag.symbol);
            final notation = find.descendant(
              of: find.byType(MoveChip),
              matching: find.byType(RichText),
            );
            expect(
              _contrast(
                chip.nagStyle.color!,
                _paintedBackground(tester, notation),
              ),
              greaterThanOrEqualTo(4.5),
              reason: '${nag.symbol} notation',
            );
            if (!selected) {
              final mouse = await tester.createGesture(
                kind: PointerDeviceKind.mouse,
              );
              await mouse.addPointer(location: const Offset(700, 500));
              await mouse.moveTo(tester.getCenter(find.byType(MoveChip)));
              await tester.pump();
              expect(
                _contrast(
                  chip.nagStyle.color!,
                  _paintedBackground(tester, notation),
                ),
                greaterThanOrEqualTo(4.5),
                reason: '${nag.symbol} hovered notation',
              );
              await mouse.removePointer();
              await tester.pump();
            }
            if (selected) {
              final glyph = find.byWidgetPredicate(
                (w) => w is GlyphButton && w.symbol == nag.symbol,
              );
              final label = find.descendant(
                of: glyph,
                matching: find.byType(Text),
              );
              final text = tester.widget<Text>(label);
              expect(
                _contrast(
                  text.style!.color!,
                  _paintedBackground(
                    tester,
                    find.descendant(of: glyph, matching: find.byType(RichText)),
                  ),
                ),
                greaterThanOrEqualTo(4.5),
                reason: '${nag.symbol} active annotation',
              );
            }
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,

          theme: AppTheme.dark(),
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
                          ? [
                              PgnMoveSnapshot.capture(
                                PgnNodeData(san: 'e4', nags: nags),
                              ),
                            ]
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
      expect(chip.nagStyle.color, isNotNull);
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
      expect(
        paintedDecoration().color,
        AppTheme.dark().colorScheme.surfaceContainerHighest,
      );
      expect(paintedDecoration().border, idle.border);
      expect(tester.getSize(chipFinder), originalSize);

      await tester.tap(chipFinder);
      expect(jumps, 1);
      await pumpSurface(true);
      expect(
        paintedDecoration().color,
        AppTheme.dark().colorScheme.primaryContainer,
      );
      expect(paintedDecoration().border, idle.border);
      expect(tester.getSize(chipFinder), originalSize);
      expect(tester.widget<MoveChip>(chipFinder).nagStyle, chip.nagStyle);

      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(
        paintedDecoration().color,
        AppTheme.dark().colorScheme.primaryContainer,
      );
      expect(tester.getSize(chipFinder), originalSize);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });
  }
}
