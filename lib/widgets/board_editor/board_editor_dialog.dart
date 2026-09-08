/// Full board editor in a dialog, laid out like the lichess editor: the far
/// side's spare pieces above the board, the near side's below, and the
/// position controls beside it. Resolves to the validated [Position] on
/// confirm, or `null` when cancelled.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../core/board_editor_controller.dart';
import 'board_editor_widget.dart';
import 'piece_palette.dart';
import 'position_setup_panel.dart';

class BoardEditorDialog extends StatefulWidget {
  /// Seed the editor with this FEN (defaults to the standard start position).
  final String? initialFen;

  /// Label for the confirm button.
  final String actionLabel;

  const BoardEditorDialog({
    super.key,
    this.initialFen,
    this.actionLabel = 'Use position',
  });

  /// Show the editor; resolves to the chosen [Position] or `null`.
  static Future<Position?> show(
    BuildContext context, {
    String? initialFen,
    String actionLabel = 'Use position',
  }) {
    return showDialog<Position>(
      context: context,
      builder: (_) =>
          BoardEditorDialog(initialFen: initialFen, actionLabel: actionLabel),
    );
  }

  @override
  State<BoardEditorDialog> createState() => _BoardEditorDialogState();
}

class _BoardEditorDialogState extends State<BoardEditorDialog> {
  late final BoardEditorController _controller;

  @override
  void initState() {
    super.initState();
    _controller = BoardEditorController(initialFen: widget.initialFen);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 700;

              final boardColumn = Center(
                child: BoardWithSpares(controller: _controller),
              );

              final setupColumn = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        'Set up position',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Cancel',
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: PositionSetupPanel(
                      controller: _controller,
                      actionLabel: widget.actionLabel,
                      onAction: (position) => Navigator.pop(context, position),
                    ),
                  ),
                ],
              );

              return wide
                  ? Row(
                      children: [
                        Expanded(flex: 5, child: boardColumn),
                        const SizedBox(width: 16),
                        Expanded(flex: 4, child: setupColumn),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(flex: 5, child: boardColumn),
                        const SizedBox(height: 12),
                        Expanded(flex: 4, child: setupColumn),
                      ],
                    );
            },
          ),
        ),
      ),
    );
  }
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
