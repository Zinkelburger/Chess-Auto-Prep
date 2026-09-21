import 'package:flutter/material.dart';

import 'theme.dart';

/// A row of words at the top of a pane, one of them underlined: what the
/// pane is showing, and the other things it could show instead.
///
/// The old viewer switched its right column this way and it was the one
/// part of that screen nobody complained about: no second pane, no menu,
/// one glance says what is there and one click changes it. [trailing] is
/// for the one control that belongs to the chosen tab and nowhere else.
class PaneTabs extends StatelessWidget {
  const PaneTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
    this.trailing,
  });

  final List<String> tabs;
  final int selected;
  final ValueChanged<int> onSelected;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: paneTabHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            for (final (index, tab) in tabs.indexed)
              _Tab(
                label: tab,
                selected: index == selected,
                onTap: () => onSelected(index),
              ),
            const Spacer(),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Space.m),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? scheme.primary : Colors.transparent,
              width: paneTabUnderline,
            ),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
