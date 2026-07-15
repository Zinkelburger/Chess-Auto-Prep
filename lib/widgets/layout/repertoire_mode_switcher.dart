/// Edit / Analyze segmented control for the repertoire builder app bar.
library;

import 'package:flutter/material.dart';

import 'repertoire_mode.dart';

class RepertoireModeSwitcher extends StatelessWidget {
  const RepertoireModeSwitcher({
    super.key,
    required this.mode,
    required this.onModeChanged,
    this.enabled = true,
  });

  final RepertoireMode mode;
  final ValueChanged<RepertoireMode> onModeChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: SegmentedButton<RepertoireMode>(
          segments: const [
            ButtonSegment(
              value: RepertoireMode.edit,
              label: Text('Edit'),
              icon: Icon(Icons.edit_outlined, size: 16),
            ),
            ButtonSegment(
              value: RepertoireMode.analyze,
              label: Text('Analyze'),
              icon: Icon(Icons.analytics_outlined, size: 16),
            ),
          ],
          selected: {mode},
          onSelectionChanged: enabled
              ? (selection) {
                  if (selection.isNotEmpty) {
                    onModeChanged(selection.first);
                  }
                }
              : null,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: WidgetStatePropertyAll(theme.textTheme.labelSmall),
          ),
        ),
      ),
    );
  }
}
