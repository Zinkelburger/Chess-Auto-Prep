/// Mode picker, placed between Actions and the settings gear in app bars.
/// Its grouped menu follows the app mode registry.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../theme/app_colors.dart';
import 'app_overflow_menu.dart';

class AppModeSwitcher extends StatelessWidget {
  const AppModeSwitcher({super.key});

  /// Finder handle for tests: the one control that opens the mode menu.
  static const Key switcherKey = Key('app-mode-switcher');

  @override
  Widget build(BuildContext context) {
    final locked = context.select<AppState, bool>(
      (s) => s.isRepertoireGenerating,
    );
    final mode = context.select<AppState, AppMode>((s) => s.currentMode);
    final picker = AppOverflowMenu(
      key: switcherKey,
      label: mode.label,
      tooltip: locked
          ? 'Locked — repertoire generation in progress'
          : 'Switch mode',
      enabled: !locked,
      openOnHover: true,
      entries: [
        for (final group in availableAppModeGroups())
          for (final m in group.modes)
            AppMenuEntry(
              heading: m == group.modes.first ? group.heading : null,
              label: m.label,
              checked: m == mode,
              onRun: () => context.read<AppState>().setMode(m),
            ),
      ],
    );
    // Keep screen actions separate from app navigation on every top bar.
    // The separator and its breathing room are outside the menu's hit area.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 16),
        const SizedBox(
          height: 28,
          child: VerticalDivider(width: 1, color: AppColors.outline),
        ),
        const SizedBox(width: 16),
        picker,
        const SizedBox(width: 8),
      ],
    );
  }
}
