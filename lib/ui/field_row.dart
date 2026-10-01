import 'package:flutter/material.dart';

import 'theme.dart';

/// A control with its name: the name on the left, the control at the end of
/// the line. A stepper or a typeable choice says nothing about what it sets,
/// so every one in a column or a dialog sits in one of these.
class FieldRow extends StatelessWidget {
  const FieldRow({
    super.key,
    required this.label,
    required this.child,
    this.tooltip,
  });

  final String label;
  final Widget child;

  /// What the setting does, when its name does not say.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final name = Text(
      label,
      style: Theme.of(context).textTheme.bodySmall,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return SizedBox(
      height: fieldRowHeight,
      child: Row(
        children: [
          Expanded(
            child: tooltip == null
                ? name
                : Tooltip(message: tooltip, child: name),
          ),
          const SizedBox(width: Space.s),
          child,
        ],
      ),
    );
  }
}
