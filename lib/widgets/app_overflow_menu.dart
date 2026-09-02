/// The one overflow menu every screen's app bar uses.
///
/// Each screen used to hand-roll its own `PopupMenuButton` — different item
/// widgets, different icon sizes, some with subtitles, some without — so the
/// same action looked like a different control depending on where you found
/// it. This is that menu, once: a `⋮` button, an [AppMenuEntry] per row, and
/// a rule that rows are labels rather than labels-plus-an-explaining-sentence.
///
/// The bar itself is meant to stay at four controls: title, one primary
/// action, this menu, and the mode switcher. Anything occasional belongs in
/// here.
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'info_hint.dart';

/// One row of an [AppOverflowMenu] (or of any other app menu that wants the
/// same shape).
class AppMenuEntry {
  const AppMenuEntry({
    required this.label,
    required this.onRun,
    this.icon,
    this.leading,
    this.enabled = true,
    this.dividerAbove = false,
    this.checked,
    this.shortcut,
    this.hint,
  }) : assert(
         icon == null || leading == null,
         'Give an entry an icon or a leading widget, not both.',
       );

  final String label;
  final VoidCallback onRun;

  /// Leading icon. Mutually exclusive with [leading].
  final IconData? icon;

  /// Leading widget for the rare row that needs more than an icon (a colour
  /// swatch, say). Mutually exclusive with [icon].
  final Widget? leading;

  final bool enabled;

  /// Draws a separator above this row, for grouping settings away from
  /// actions.
  final bool dividerAbove;

  /// Non-null turns the row into a toggle and shows a check when true.
  final bool? checked;

  /// Keyboard shortcut hint shown right-aligned, e.g. `Ctrl+V`.
  final String? shortcut;

  /// Explanation for a row whose label genuinely cannot carry what it does —
  /// shown as a trailing hoverable ⓘ, never as a sentence under the label.
  /// Prose under every row is what turned these menus into walls of text; a
  /// hint the reader opts into costs nothing until they want it.
  final String? hint;
}

/// Trailing `⋮` menu for an app bar.
class AppOverflowMenu extends StatelessWidget {
  const AppOverflowMenu({
    super.key,
    required this.entries,
    this.tooltip = 'More actions',
  });

  final List<AppMenuEntry> entries;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final rows = entries;
    if (rows.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<int>(
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: tooltip,
      onSelected: (i) => rows[i].onRun(),
      itemBuilder: (_) => [
        for (var i = 0; i < rows.length; i++) ...[
          if (rows[i].dividerAbove && i > 0) const PopupMenuDivider(),
          PopupMenuItem<int>(
            value: i,
            enabled: rows[i].enabled,
            child: AppMenuEntryRow(entry: rows[i]),
          ),
        ],
      ],
    );
  }
}

/// An [AppMenuEntry] rendered as a menu row. Public so screens with a
/// bespoke menu (the mode switcher, a picker) can still match the shape.
class AppMenuEntryRow extends StatelessWidget {
  const AppMenuEntryRow({super.key, required this.entry});

  final AppMenuEntry entry;

  @override
  Widget build(BuildContext context) {
    final muted = !entry.enabled;
    final leading =
        entry.leading ??
        (entry.icon == null
            ? null
            : Icon(
                entry.icon,
                size: 18,
                color: muted ? AppColors.onSurfaceDisabled : null,
              ));
    return Row(
      children: [
        if (leading != null) ...[
          SizedBox(width: 18, height: 18, child: Center(child: leading)),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            entry.label,
            style: TextStyle(
              fontSize: 13,
              color: muted ? AppColors.onSurfaceDisabled : null,
            ),
          ),
        ),
        if (entry.hint != null) ...[
          const SizedBox(width: 12),
          InfoHint(entry.hint!, size: 15),
        ],
        if (entry.shortcut != null) ...[
          const SizedBox(width: 16),
          Text(
            entry.shortcut!,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ],
        if (entry.checked == true) ...[
          const SizedBox(width: 12),
          const Icon(Icons.check, size: 16, color: AppColors.success),
        ],
      ],
    );
  }
}
