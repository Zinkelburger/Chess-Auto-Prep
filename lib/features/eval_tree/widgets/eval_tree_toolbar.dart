import 'package:flutter/material.dart';

import '../controllers/eval_tree_controller.dart';
import '../models/eval_tree_snapshot.dart';

class EvalTreeToolbar extends StatelessWidget {
  final EvalTreeController controller;
  final EvalTreeNodeSnapshot currentNode;
  final int visibleNodeCount;
  final int totalNodeCount;
  final bool hitDisplayCap;

  const EvalTreeToolbar({
    super.key,
    required this.controller,
    required this.currentNode,
    required this.visibleNodeCount,
    required this.totalNodeCount,
    required this.hitDisplayCap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _toolButton(
            icon: Icons.home,
            tooltip: 'Go to tree root',
            onPressed: currentNode.parentId == null ? null : controller.goRoot,
          ),
          _toolButton(
            icon: Icons.arrow_upward,
            tooltip: 'Go to parent',
            onPressed:
                currentNode.parentId == null ? null : controller.goParent,
          ),
          _toolButton(
            icon: Icons.center_focus_strong,
            tooltip: 'Focus selected node',
            onPressed: () => controller.requestFocusSelection(),
          ),
          _toolButton(
            icon:
                controller.showAncestorSpine ? Icons.account_tree : Icons.park,
            tooltip: controller.showAncestorSpine
                ? 'Hide ancestor spine'
                : 'Show ancestor spine',
            onPressed: controller.toggleAncestorSpine,
            active: controller.showAncestorSpine,
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Metric',
                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
              ),
              const SizedBox(width: 6),
              SegmentedButton<EvalTreeMetricDisplayMode>(
                segments: const [
                  ButtonSegment<EvalTreeMetricDisplayMode>(
                    value: EvalTreeMetricDisplayMode.cpl,
                    label: Text('CPL'),
                  ),
                  ButtonSegment<EvalTreeMetricDisplayMode>(
                    value: EvalTreeMetricDisplayMode.eval,
                    label: Text('Eval'),
                  ),
                ],
                selected: {controller.metricDisplayMode},
                onSelectionChanged: (selection) =>
                    controller.setMetricDisplayMode(selection.first),
                showSelectedIcon: false,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  ),
                  textStyle: const WidgetStatePropertyAll(
                    TextStyle(fontSize: 10),
                  ),
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Ahead',
                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
              ),
              SizedBox(
                width: 132,
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: Colors.blue[400],
                    inactiveTrackColor: Colors.grey[700],
                    thumbColor: Colors.blue[300],
                  ),
                  child: Slider(
                    value: controller.visibleDepth.toDouble(),
                    min: 1,
                    max: 8,
                    divisions: 7,
                    label: '${controller.visibleDepth}',
                    onChanged: (value) =>
                        controller.setVisibleDepth(value.round()),
                  ),
                ),
              ),
              Text(
                '${controller.visibleDepth}',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[400],
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hitDisplayCap)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.warning_amber,
                    size: 13,
                    color: Colors.amber[400],
                  ),
                ),
              Text(
                '$visibleNodeCount / $totalNodeCount',
                style: TextStyle(
                  fontSize: 10,
                  color: hitDisplayCap ? Colors.amber[400] : Colors.grey[600],
                ),
              ),
              Text(
                '  |  ${currentNode.subtreeSize} subtree',
                style: TextStyle(fontSize: 10, color: Colors.grey[600]),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool active = false,
  }) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        icon: Icon(
          icon,
          size: 16,
          color: onPressed == null
              ? Colors.grey[700]
              : active
                  ? Colors.blue[300]
                  : Colors.grey[400],
        ),
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}
