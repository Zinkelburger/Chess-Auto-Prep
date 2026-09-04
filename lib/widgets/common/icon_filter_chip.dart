/// The chip a layout zone uses to pick which view its column shows: a 14px
/// icon that turns accent when selected, a 12px label, compact density, no
/// checkmark.
///
/// Three copies of those twenty lines existed when this was extracted — the
/// analyze main zone, the analyze context zone and the edit context zone.
/// The first two turned out to be dead code from before the builder's layout
/// rethink and were deleted in the same pass, so today the edit context zone
/// is the only caller.
///
/// It stays a widget of its own rather than going back inline, because the
/// tests beside it are the only coverage this control has ever had, and a
/// tab row is the sort of thing the next zone will want.
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
