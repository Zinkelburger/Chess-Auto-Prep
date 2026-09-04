/// The chip the layout zones use to pick which view a column shows.
///
/// Three of them existed — the analyze main zone, the analyze context zone
/// and the edit context zone — spelling out the same twenty lines: a 14px
/// icon that turns accent when selected, a 12px label, compact density, no
/// checkmark. They are one control, and a fourth zone would have been a
/// fourth copy.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

class IconFilterChip extends StatelessWidget {
  const IconFilterChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final bool selected;

  /// Null disables the chip — the edit zone passes null while its tabs are
  /// locked, so a locked layout cannot be changed by clicking.
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: selected ? AppColors.accent : AppColors.onSurfaceMuted,
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
      selected: selected,
      onSelected: onSelected,
      visualDensity: VisualDensity.compact,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}
