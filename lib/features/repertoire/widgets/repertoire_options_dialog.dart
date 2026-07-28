/// Settings for the repertoire that is currently open.
///
/// Deliberately boring: labelled dropdowns in titled sections, one decision
/// per row. Switching the side you play flips every "our move" in the
/// builder, so it lives behind this dialog instead of a one-click menu item
/// where it can be hit by accident.
library;

import 'package:flutter/material.dart';

import '../../../models/board_size.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';

Future<void> showRepertoireOptionsDialog({
  required BuildContext context,
  required bool isWhiteRepertoire,
  required ValueChanged<bool> onSideChanged,
  required BoardSize boardSize,
  required ValueChanged<BoardSize> onBoardSizeChanged,
  bool sideChangeEnabled = true,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _RepertoireOptionsDialog(
      isWhiteRepertoire: isWhiteRepertoire,
      onSideChanged: onSideChanged,
      boardSize: boardSize,
      onBoardSizeChanged: onBoardSizeChanged,
      sideChangeEnabled: sideChangeEnabled,
    ),
  );
}

class _RepertoireOptionsDialog extends StatefulWidget {
  const _RepertoireOptionsDialog({
    required this.isWhiteRepertoire,
    required this.onSideChanged,
    required this.boardSize,
    required this.onBoardSizeChanged,
    required this.sideChangeEnabled,
  });

  final bool isWhiteRepertoire;
  final ValueChanged<bool> onSideChanged;
  final BoardSize boardSize;
  final ValueChanged<BoardSize> onBoardSizeChanged;
  final bool sideChangeEnabled;

  @override
  State<_RepertoireOptionsDialog> createState() =>
      _RepertoireOptionsDialogState();
}

class _RepertoireOptionsDialogState extends State<_RepertoireOptionsDialog> {
  late bool _isWhite = widget.isWhiteRepertoire;
  late BoardSize _boardSize = widget.boardSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Repertoire settings'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionTitle('This repertoire'),
            DropdownButtonFormField<bool>(
              initialValue: _isWhite,
              decoration: const InputDecoration(
                labelText: 'Side you play',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: true, child: Text('White')),
                DropdownMenuItem(value: false, child: Text('Black')),
              ],
              onChanged: widget.sideChangeEnabled
                  ? (v) {
                      if (v == null) return;
                      setState(() => _isWhite = v);
                    }
                  : null,
            ),
            _caption(
              widget.sideChangeEnabled
                  ? 'Which side this repertoire prepares. Changing it flips '
                        'the board and treats the other side\'s moves as yours.'
                  : 'Locked while a build is running.',
            ),
            const Divider(height: 28),
            _sectionTitle('Layout'),
            DropdownButtonFormField<BoardSize>(
              initialValue: _boardSize,
              decoration: const InputDecoration(
                labelText: 'Board size',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final size in BoardSize.values)
                  DropdownMenuItem(value: size, child: Text(size.label)),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _boardSize = v);
                widget.onBoardSizeChanged(v);
              },
            ),
            _caption(
              'A smaller board gives the engine lines and PGN beside it more '
              'room. Also on the board-size button under the move list.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_isWhite != widget.isWhiteRepertoire) {
              widget.onSideChanged(_isWhite);
            }
            Navigator.of(context).pop();
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: AppColors.onSurfaceSoft,
      ),
    ),
  );

  Widget _caption(String text, {TextStyle? style}) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(text, style: style ?? AppTextStyles.caption),
  );
}
