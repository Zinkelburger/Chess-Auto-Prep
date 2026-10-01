import 'package:flutter/material.dart';

import 'theme.dart';

/// One of a set of things that are each on or off — a time control, a kind
/// of mistake — or the chosen one of a few. As small as a chip goes, and
/// with no tick: a chip that grows a tick when pressed pushes the ones
/// after it along the line.
class ToggleChip extends StatelessWidget {
  const ToggleChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;

  /// Null while the choice cannot change.
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) => FilterChip(
    label: Text(label),
    selected: selected,
    onSelected: onSelected,
    showCheckmark: false,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: EdgeInsets.zero,
    labelPadding: const EdgeInsets.symmetric(horizontal: Space.s),
    labelStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: selected
          ? Theme.of(context).colorScheme.onSurface
          : Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
