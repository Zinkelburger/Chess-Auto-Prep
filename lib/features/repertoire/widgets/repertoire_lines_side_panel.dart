/// Wide-layout side panel hosting the Lines/Draft and Tree surfaces, plus the
/// divider you drag to resize it.
///
/// The panel exists so those surfaces stay clickable while the PGN editor
/// holds the middle column; collapsing it to a strip hands all that width
/// back. Both pieces were inline builders on the screen's state class, which
/// is why the strip's label and the drag arithmetic had no tests.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';

/// What the first side-panel tab is currently showing. The collapsed strip
/// names it, so a session or draft running behind a collapsed panel is still
/// visible.
enum RepertoireLinesSurface { lines, draft, session }

class RepertoireLinesSidePanel extends StatelessWidget {
  const RepertoireLinesSidePanel({
    super.key,
    required this.collapsed,
    required this.width,
    required this.surface,
    required this.lineCount,
    required this.tabController,
    required this.tabs,
    required this.children,
    required this.onCollapsedChanged,
    this.stripLabel,
    this.hideTooltip = 'Hide lines (L)',
    this.showTooltip = 'Show lines (L)',
  });

  final bool collapsed;

  /// Label on the collapsed strip when the panel is not showing lines,
  /// drafts or sessions — e.g. "Analysis". Null keeps the surface-based label.
  final String? stripLabel;
  final String hideTooltip;
  final String showTooltip;

  /// Expanded width, already resolved against the available space.
  final double width;

  final RepertoireLinesSurface surface;
  final int lineCount;

  final TabController tabController;
  final List<Widget> tabs;
  final List<Widget> children;

  final ValueChanged<bool> onCollapsedChanged;

  @override
  Widget build(BuildContext context) {
    if (collapsed) return _buildStrip(context);

    return SizedBox(
      width: width,
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_double_arrow_right, size: 16),
                onPressed: () => onCollapsedChanged(true),
                tooltip: hideTooltip,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              Expanded(
                child: TabBar(
                  controller: tabController,
                  // Scrollable so narrow panel widths shrink the bar instead
                  // of overflowing the tab labels.
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: tabs,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  indicatorSize: TabBarIndicatorSize.label,
                  dividerHeight: 0,
                ),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: tabController,
              physics: const NeverScrollableScrollPhysics(),
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStrip(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (surface) {
      RepertoireLinesSurface.session => ('Session', theme.colorScheme.primary),
      RepertoireLinesSurface.draft => ('Draft', AppColors.warning),
      RepertoireLinesSurface.lines => (
        stripLabel ?? 'Lines ($lineCount)',
        AppColors.onSurfaceMuted,
      ),
    };
    final highlighted = surface != RepertoireLinesSurface.lines;

    return InkWell(
      onTap: () => onCollapsedChanged(false),
      child: SizedBox(
        width: 28,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Tooltip(
              message: showTooltip,
              child: const Icon(
                Icons.keyboard_double_arrow_left,
                size: 16,
                color: AppColors.onSurfaceMuted,
              ),
            ),
            const SizedBox(height: 12),
            RotatedBox(
              quarterTurns: 1,
              child: Text(
                label,
                style: AppTextStyles.caption.copyWith(
                  fontSize: 12,
                  color: color,
                  fontWeight: highlighted ? FontWeight.w600 : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Divider between the PGN column and the Lines side panel; drag it to
/// resize.
///
/// Reports the width the panel should take, derived from where the cursor is
/// rather than from accumulated deltas, so the panel edge stays under the
/// pointer even after a drag runs into [minWidth] or [maxWidth].
class RepertoireLinesPanelDragHandle extends StatelessWidget {
  const RepertoireLinesPanelDragHandle({
    super.key,
    required this.currentWidth,
    required this.minWidth,
    required this.maxWidth,
    required this.onWidthChanged,
    required this.onDragEnd,
    this.panelOnLeft = false,
  });

  final double currentWidth;
  final double minWidth;
  final double maxWidth;
  final ValueChanged<double> onWidthChanged;
  final VoidCallback onDragEnd;

  /// True when the panel being resized sits to the *left* of this handle
  /// (the outline column); false for a panel to the right (analysis column).
  final bool panelOnLeft;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          if (panelOnLeft) {
            // The panel runs from its own left edge (fixed) to this handle.
            final panelLeft = box.localToGlobal(Offset.zero).dx - currentWidth;
            onWidthChanged(
              (details.globalPosition.dx - panelLeft)
                  .clamp(minWidth, maxWidth)
                  .toDouble(),
            );
            return;
          }
          // The panel runs from this handle's right edge to its own right
          // edge, which does not move during the drag.
          final panelRight =
              box.localToGlobal(Offset(box.size.width, 0)).dx + currentWidth;
          onWidthChanged(
            (panelRight - details.globalPosition.dx)
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
