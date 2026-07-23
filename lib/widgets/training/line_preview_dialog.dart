/// Read-only "book view" of a repertoire line: board beside the annotated
/// movetext. Lets the user read through a line — one they already know, or
/// one they don't want to drill right now — without touching training state.
library;

import 'package:dartchess/dartchess.dart' show Position;
import 'package:flutter/material.dart';

import '../../models/repertoire_line.dart';
import '../../theme/app_colors.dart';
import '../chess_board_widget.dart';
import '../pgn_viewer_widget.dart';

class LinePreviewDialog extends StatefulWidget {
  final RepertoireLine line;

  /// Label for the edit handoff ("Edit in Builder" / "Edit in Study").
  final String editLabel;
  final VoidCallback? onEdit;
  final VoidCallback? onTrain;

  const LinePreviewDialog({
    super.key,
    required this.line,
    required this.editLabel,
    this.onEdit,
    this.onTrain,
  });

  @override
  State<LinePreviewDialog> createState() => _LinePreviewDialogState();
}

class _LinePreviewDialogState extends State<LinePreviewDialog> {
  late Position _position = widget.line.startPosition;

  bool get _isBlackLine => widget.line.color.toLowerCase() == 'black';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color:
                          (_isBlackLine
                                  ? AppColors.sideBlack
                                  : AppColors.sideWhite)
                              .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _isBlackLine ? 'Black' : 'White',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.line.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: ChessBoardWidget(
                            position: _position,
                            enableUserMoves: false,
                            flipped: _isBlackLine,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    flex: 4,
                    child: PgnViewerWidget(
                      pgnText: widget.line.fullPgn,
                      onPositionChanged: (position) =>
                          setState(() => _position = position),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  if (widget.onEdit != null)
                    TextButton.icon(
                      onPressed: widget.onEdit,
                      icon: const Icon(Icons.edit, size: 16),
                      label: Text(widget.editLabel),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                  if (widget.onTrain != null) ...[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: widget.onTrain,
                      icon: const Icon(Icons.school_outlined, size: 16),
                      label: const Text('Train this line'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
