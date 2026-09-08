import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/app_shortcuts.dart';

/// One compact reference, with aligned columns and a rule between each row.
class KeyboardShortcutsSection extends StatelessWidget {
  const KeyboardShortcutsSection({super.key});

  Widget _cell(String text, {bool heading = false, bool muted = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Text(
          text,
          style: heading
              ? AppTextStyles.bodyStrong
              : muted
              ? AppTextStyles.muted
              : AppTextStyles.body,
        ),
      );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.divider),
          borderRadius: BorderRadius.circular(6),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Table(
            columnWidths: const {
              0: FlexColumnWidth(3),
              1: FixedColumnWidth(140),
              2: FlexColumnWidth(1.5),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: const TableBorder(
              horizontalInside: BorderSide(color: AppColors.divider),
              verticalInside: BorderSide(color: AppColors.divider),
            ),
            children: [
              TableRow(
                decoration: const BoxDecoration(
                  color: AppColors.surfaceElevated,
                ),
                children: [
                  _cell('Action', heading: true),
                  _cell('Key', heading: true),
                  _cell('Where', heading: true),
                ],
              ),
              for (final entry in shortcutReference)
                TableRow(
                  children: [
                    _cell(entry.description),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceElevated,
                            border: Border.all(color: AppColors.outline),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            entry.shortcut.label,
                            style: AppTextStyles.mono,
                          ),
                        ),
                      ),
                    ),
                    _cell(entry.group, muted: true),
                  ],
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      const Text(
        'Text fields keep their normal editing keys. Tab moves between controls. '
        'Hover a button to see its shortcut.',
        style: AppTextStyles.muted,
      ),
    ],
  );
}
