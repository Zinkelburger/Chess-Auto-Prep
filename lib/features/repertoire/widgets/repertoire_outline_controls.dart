/// Controls for the Builder's collapsible, resizable chapter outline.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';

class RepertoireOutlineStrip extends StatelessWidget {
  const RepertoireOutlineStrip({super.key, required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onExpand,
      child: SizedBox(
        width: 28,
        child: Column(
          children: [
            const SizedBox(height: 8),
            const Tooltip(
              message: 'Show chapters',
              child: Icon(
                Icons.keyboard_double_arrow_left,
                size: 16,
                color: AppColors.onSurfaceMuted,
              ),
            ),
            const SizedBox(height: 12),
            RotatedBox(
              quarterTurns: 1,
              child: Text(
                'Chapters',
                style: AppTextStyles.caption.copyWith(
                  fontSize: 12,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Drag the outline's right edge, clamped to the available workspace.
class RepertoireOutlineResizeHandle extends StatelessWidget {
  const RepertoireOutlineResizeHandle({
    super.key,
    required this.currentWidth,
    required this.minWidth,
    required this.maxWidth,
    required this.onWidthChanged,
    required this.onDragEnd,
  });

  final double currentWidth;
  final double minWidth;
  final double maxWidth;
  final ValueChanged<double> onWidthChanged;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          // The outline's left edge stays fixed while its right edge follows
          // the pointer, including after a drag reaches either width limit.
          final panelLeft = box.localToGlobal(Offset.zero).dx - currentWidth;
          onWidthChanged(
            (details.globalPosition.dx - panelLeft)
                .clamp(minWidth, maxWidth)
                .toDouble(),
          );
        },
        onHorizontalDragEnd: (_) => onDragEnd(),
        child: SizedBox(
          width: 7,
          child: Center(child: Container(width: 1, color: AppColors.outline)),
        ),
      ),
    );
  }
}
