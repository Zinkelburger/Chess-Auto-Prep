import 'package:flutter/material.dart';

import '../../../utils/tree_colors.dart';
import '../controllers/eval_tree_controller.dart';
import '../models/eval_tree_snapshot.dart';
import '../services/eval_tree_layout_engine.dart';

class EvalTreeNodeChip extends StatelessWidget {
  final EvalTreeSnapshot snapshot;
  final EvalTreeNodeSnapshot node;
  final EvalTreeLayoutNode layoutNode;
  final EvalTreeMetricDisplayMode metricDisplayMode;
  final VoidCallback onTap;

  const EvalTreeNodeChip({
    super.key,
    required this.snapshot,
    required this.node,
    required this.layoutNode,
    required this.metricDisplayMode,
    required this.onTap,
  });

  String _tooltipMessage() {
    final label = EvalTreeLayoutEngine.secondaryLabelForNode(
      snapshot,
      node,
      metricDisplayMode,
    );
    if (label != null && label.isNotEmpty) return label;
    return node.displayLabel;
  }

  @override
  Widget build(BuildContext context) {
    final secondaryLabel = EvalTreeLayoutEngine.secondaryLabelForNode(
      snapshot,
      node,
      metricDisplayMode,
    );
    final fillColor = graphNodeColor(
      snapshot: snapshot,
      node: node,
    );
    final textColor = nodeTextColor(fillColor);
    final secondaryTextColor = nodeSecondaryTextColor(fillColor);
    final textOutline = nodeTextOutline(fillColor);
    final borderColor = layoutNode.isSelected
        ? nodeSelectionColor(fillColor)
        : node.isRepertoireMove
            ? kNodeAccentRepertoire
            : Colors.transparent;

    return Tooltip(
      message: _tooltipMessage(),
      waitDuration: const Duration(milliseconds: 300),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: layoutNode.size.width,
          height: layoutNode.size.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: borderColor,
                width: layoutNode.isSelected
                    ? 2.5
                    : (node.isRepertoireMove ? 1.5 : 0),
              ),
              boxShadow: layoutNode.isSelected
                  ? [
                      BoxShadow(
                        color: borderColor.withValues(alpha: 0.28),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: EvalTreeLayoutEngine.nodeHorizontalPadding,
                vertical: EvalTreeLayoutEngine.nodeVerticalPadding,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    node.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: EvalTreeLayoutEngine.nodeTitleFontSize,
                      fontWeight: layoutNode.isSelected
                          ? FontWeight.bold
                          : FontWeight.w500,
                      fontFamily: EvalTreeLayoutEngine.nodeFontFamily,
                      shadows: textOutline,
                    ),
                  ),
                  if (secondaryLabel != null)
                    Text(
                      secondaryLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: secondaryTextColor,
                        fontSize: EvalTreeLayoutEngine.nodeSecondaryFontSize,
                        fontFamily: EvalTreeLayoutEngine.nodeFontFamily,
                        shadows: textOutline,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
