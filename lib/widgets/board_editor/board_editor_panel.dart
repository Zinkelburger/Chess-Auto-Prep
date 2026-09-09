import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../core/board_editor_controller.dart';
import 'board_editor_widget.dart';
import 'piece_palette.dart';
import 'position_setup_panel.dart';

/// Complete embedded editor. The caller owns and disposes [controller].
///
/// Listens through its children; parent flows can listen to the same controller
/// for board changes and [BoardEditorController.hasUnappliedFen]. This panel
/// scrolls vertically and needs a bounded width. In a bounded-height parent,
/// give it the available height with Expanded or SizedBox.
class BoardEditorPanel extends StatefulWidget {
  const BoardEditorPanel({
    super.key,
    required this.controller,
    this.actionLabel,
    this.onAction,
    this.advancedInitiallyExpanded = false,
    this.maxBoardSize = 440,
  }) : assert(maxBoardSize > 0);

  final BoardEditorController controller;
  final String? actionLabel;
  final ValueChanged<Position>? onAction;
  final bool advancedInitiallyExpanded;
  final double maxBoardSize;

  @override
  State<BoardEditorPanel> createState() => _BoardEditorPanelState();
}

class _BoardEditorPanelState extends State<BoardEditorPanel> {
  final _scroll = ScrollController();
  BoardEditorController get controller => widget.controller;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 700;
      final boardSize = math.min(
        widget.maxBoardSize,
        wide ? (constraints.maxWidth - 16) / 2 : constraints.maxWidth,
      );
      final board = SizedBox(
        width: boardSize,
        height: boardSize + 2 * SparePieceRow.heightFor(boardSize) + 16,
        child: BoardWithSpares(controller: controller),
      );
      final controls = PositionSetupPanel(
        controller: controller,
        actionLabel: widget.actionLabel,
        onAction: widget.onAction,
        advancedInitiallyExpanded: widget.advancedInitiallyExpanded,
        scrollable: false,
      );
      return Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scroll,
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    board,
                    const SizedBox(width: 16),
                    Expanded(child: controls),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: board),
                    const SizedBox(height: 12),
                    controls,
                  ],
                ),
        ),
      );
    },
  );
}

/// The board with a strip of spare pieces above and below it, sized so the
/// three fit the space together. The strips follow the orientation: the
/// far side's pieces are above the board, the near side's below.
class BoardWithSpares extends StatelessWidget {
  const BoardWithSpares({super.key, required this.controller});

  final BoardEditorController controller;

  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        // Strips are an eighth of the board tall until the cap kicks in, so
        // size for that first and take the cap into account if it applies.
        var board = width < (height - 2 * _gap) / 1.25
            ? width
            : (height - 2 * _gap) / 1.25;
        final strip = SparePieceRow.heightFor(board);
        if (strip < board / 8) {
          final fromHeight = height - 2 * _gap - 2 * strip;
          board = width < fromHeight ? width : fromHeight;
        }
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final far = controller.flipped ? Side.white : Side.black;
            final near = far.opposite;
            return SizedBox(
              width: board,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SparePieceRow(
                    side: far,
                    tool: controller.tool,
                    onSelect: controller.selectTool,
                  ),
                  const SizedBox(height: _gap),
                  SizedBox(
                    width: board,
                    height: board,
                    child: BoardEditorWidget(controller: controller),
                  ),
                  const SizedBox(height: _gap),
                  SparePieceRow(
                    side: near,
                    tool: controller.tool,
                    onSelect: controller.selectTool,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
