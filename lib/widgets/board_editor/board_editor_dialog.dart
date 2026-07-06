/// Full board editor in a dialog.  Resolves to the validated [Position] on
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
      builder: (_) => BoardEditorDialog(
        initialFen: initialFen,
        actionLabel: actionLabel,
      ),
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
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 700;

              final boardColumn = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: BoardEditorWidget(controller: _controller),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  PiecePalette(controller: _controller),
                ],
              );

              final setupColumn = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text('Set up position',
                          style: Theme.of(context).textTheme.titleMedium),
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
                      onAction: (position) =>
                          Navigator.pop(context, position),
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
