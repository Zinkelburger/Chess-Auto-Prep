/// The shared boolean controls, and the rule for choosing between them.
///
/// - [AppCheckbox] — an option in a form or dialog that takes effect later,
///   when the user presses Start / Import / Export.
/// - [AppSwitch] — a toggle that takes effect the moment it flips: live
///   panes, session behavior, persisted machine settings.
/// - `FilterChip` is reserved for filtering a visible list — never for a
///   boolean setting. `SettingsSwitchRow`/`SettingsSwitchTile` stay as the
///   full-width settings-screen variants of [AppSwitch].
///
/// Both widgets replace hand-rolled checkbox/switch rows that had drifted
/// apart across panels (generation form, eval sources, tactics import,
/// dialogs); keep new booleans on these so they can't drift again.
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'info_hint.dart';

/// Compact checkbox + tappable label, with an optional trailing [InfoHint].
class AppCheckbox extends StatelessWidget {
  const AppCheckbox({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.tooltip,
    this.enabled = true,
    this.disabledReason,
    this.subtitle,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Explanation surfaced as a trailing ⓘ hint.
  final String? tooltip;

  final bool enabled;

  /// Replaces [tooltip] while disabled, so the control explains its
  /// inertness instead of silently doing nothing.
  final String? disabledReason;

  /// Muted caption rendered under the label.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final hint = !enabled && disabledReason != null ? disabledReason : tooltip;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The ⓘ sits outside the InkWell so reaching for the explanation
        // can't flip the value.
        Flexible(
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: enabled ? () => onChanged(!value) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: value,
                      onChanged: enabled ? (v) => onChanged(v ?? false) : null,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        color: enabled ? null : AppColors.onSurfaceMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (hint != null) ...[const SizedBox(width: 4), InfoHint(hint)],
      ],
    );
    if (subtitle == null) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        Padding(
          padding: const EdgeInsets.only(left: 30),
          child: Text(
            subtitle!,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.onSurfaceSoft,
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact label + switch (24 px high, like the inline engine bars), with an
/// optional trailing [InfoHint] between label and switch.
class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.tooltip,
    this.enabled = true,
    this.disabledReason,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Explanation surfaced as a ⓘ hint.
  final String? tooltip;

  final bool enabled;

  /// Replaces [tooltip] while disabled, so the control explains its
  /// inertness instead of silently doing nothing.
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final hint = !enabled && disabledReason != null ? disabledReason : tooltip;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: GestureDetector(
            onTap: enabled ? () => onChanged(!value) : null,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: enabled ? null : AppColors.onSurfaceMuted,
              ),
            ),
          ),
        ),
        if (hint != null) ...[const SizedBox(width: 4), InfoHint(hint)],
        const SizedBox(width: 4),
        SizedBox(
          height: 24,
          child: FittedBox(
            child: Switch(value: value, onChanged: enabled ? onChanged : null),
          ),
        ),
      ],
    );
  }
}
