/// Persistent status bar showing at-a-glance repertoire health metrics.
library;

import 'package:flutter/material.dart';

import '../../models/build_tree_node.dart';
import '../../services/engine/engine_lifecycle.dart';

class RepertoireStatusBar extends StatelessWidget {
  final BuildTree? tree;
  final int trapCount;
  final int lineCount;
  final double? coveragePercent;

  const RepertoireStatusBar({
    super.key,
    this.tree,
    this.trapCount = 0,
    this.lineCount = 0,
    this.coveragePercent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          if (coveragePercent != null) ...[
            _StatusItem(
              label: 'Coverage',
              value: '${coveragePercent!.toStringAsFixed(0)}%',
              color: coveragePercent! >= 80
                  ? Colors.green
                  : coveragePercent! >= 50
                      ? Colors.amber
                      : Colors.red,
            ),
            _divider(),
          ],
          _StatusItem(
              label: 'Traps', value: '$trapCount'),
          _divider(),
          _StatusItem(
              label: 'Lines', value: '$lineCount'),
          const Spacer(),
          ListenableBuilder(
            listenable: EngineLifecycle(),
            builder: (context, _) {
              final state = EngineLifecycle().state;
              return _StatusItem(
                label: 'Engine',
                value: switch (state) {
                  EngineState.off => 'OFF',
                  EngineState.idle => 'idle',
                  EngineState.analyzing => 'analyzing',
                  EngineState.generating => 'generating',
                },
                color: state == EngineState.off
                    ? Colors.grey
                    : Colors.teal,
              );
            },
          ),
          if (tree != null) ...[
            _divider(),
            _StatusItem(
              label: 'Tree',
              value: '${tree!.totalNodes} nodes',
            ),
          ],
        ],
      ),
    );
  }

  Widget _divider() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8),
      child: SizedBox(
        height: 14,
        child: VerticalDivider(width: 1, thickness: 1),
      ),
    );
  }
}

class _StatusItem extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _StatusItem({
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[500],
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            color: color ?? Colors.grey[400],
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
