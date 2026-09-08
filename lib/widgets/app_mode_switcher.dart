/// View picker, placed between Actions and the settings gear in app bars.
/// Its grouped menu and Ctrl+digit shortcuts share the app mode registry.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
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
    return PopupMenuButton<AppMode>(
      key: switcherKey,
      tooltip: locked
          ? 'Locked — repertoire generation in progress'
          : 'Switch mode (Ctrl+1…${availableModeMenuOrder().length})',
      enabled: !locked,
      onSelected: context.read<AppState>().setMode,
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      popUpAnimationStyle: AppMotion.menuAnimation,
      itemBuilder: (context) => [
        for (final group in availableAppModeGroups()) ...[
          appMenuHeadingItem<AppMode>(group.heading),
          for (final m in group.modes)
            PopupMenuItem<AppMode>(
              value: m,
              height: 32,
              child: AppMenuEntryRow(
                entry: AppMenuEntry(
                  label: m.label,
                  onRun: () {},
                  shortcut: 'Ctrl+${m.shortcutNumber}',
                  checked: m == mode ? true : null,
                ),
              ),
            ),
        ],
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              mode.label,
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down,
              size: 20,
              color: locked ? AppColors.onSurfaceDisabled : AppColors.ink,
            ),
          ],
        ),
      ),
    );
  }
}
