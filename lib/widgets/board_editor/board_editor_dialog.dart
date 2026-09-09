/// Full board editor in a dialog, laid out like the lichess editor: the far
/// side's spare pieces above the board, the near side's below, and the
/// position controls beside it. Resolves to the validated [Position] on
/// confirm, or `null` when cancelled.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../core/board_editor_controller.dart';
import 'board_editor_panel.dart';

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
          child: Column(
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
                child: BoardEditorPanel(
                  controller: _controller,
                  actionLabel: widget.actionLabel,
                  onAction: (position) {
                    if (!mounted) return;
                    Navigator.pop(context, position);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
