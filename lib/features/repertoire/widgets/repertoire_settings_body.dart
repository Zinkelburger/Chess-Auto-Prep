import 'package:flutter/material.dart';

import '../../../models/board_size.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/settings/settings_widgets.dart';

/// Live board layout and an explicit Apply for changing the repertoire's side.
class RepertoireSettingsBody extends StatefulWidget {
  const RepertoireSettingsBody({
    super.key,
    required this.isWhiteRepertoire,
    required this.onSideChanged,
    required this.boardSize,
    required this.onBoardSizeChanged,
    this.sideChangeEnabled = true,
  });
  final bool isWhiteRepertoire;
  final ValueChanged<bool> onSideChanged;
  final BoardSize boardSize;
  final ValueChanged<BoardSize> onBoardSizeChanged;
  final bool sideChangeEnabled;

  @override
  State<RepertoireSettingsBody> createState() => _RepertoireSettingsBodyState();
}

class _RepertoireSettingsBodyState extends State<RepertoireSettingsBody> {
  late bool _isWhite = widget.isWhiteRepertoire;
  late BoardSize _boardSize = widget.boardSize;

  @override
  void didUpdateWidget(RepertoireSettingsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isWhiteRepertoire != widget.isWhiteRepertoire) {
      _isWhite = widget.isWhiteRepertoire;
    }
    if (oldWidget.boardSize != widget.boardSize) _boardSize = widget.boardSize;
  }

  @override
  Widget build(BuildContext context) => SettingsGroup(
    title: 'Repertoire options',
    icon: Icons.menu_book_outlined,
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Side you play', style: AppTextStyles.bodyStrong),
            const SizedBox(height: 8),
            Text(
              widget.sideChangeEnabled
                  ? 'Changing the side flips the board and treats the other side’s moves as yours. Choose a side, then apply it.'
                  : 'The playing side is locked while a build is running.',
              style: AppTextStyles.muted,
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('White')),
                ButtonSegment(value: false, label: Text('Black')),
              ],
              selected: {_isWhite},
              showSelectedIcon: false,
              onSelectionChanged: widget.sideChangeEnabled
                  ? (v) {
                      if (!mounted) return;
                      setState(() => _isWhite = v.first);
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed:
                  widget.sideChangeEnabled &&
                      _isWhite != widget.isWhiteRepertoire
                  ? () {
                      if (!mounted) return;
                      widget.onSideChanged(_isWhite);
                    }
                  : null,
              child: const Text('Apply playing side'),
            ),
            const Divider(height: 36),
            const Text('Board size', style: AppTextStyles.bodyStrong),
            const SizedBox(height: 8),
            const Text(
              'A smaller board leaves more room for engine lines and notation. Size changes apply immediately.',
              style: AppTextStyles.muted,
            ),
            const SizedBox(height: 16),
            SegmentedButton<BoardSize>(
              segments: [
                for (final size in BoardSize.values)
                  ButtonSegment(value: size, label: Text(size.label)),
              ],
              selected: {_boardSize},
              showSelectedIcon: false,
              onSelectionChanged: (v) {
                if (!mounted) return;
                setState(() => _boardSize = v.first);
                widget.onBoardSizeChanged(v.first);
              },
            ),
          ],
        ),
      ),
    ],
  );
}
