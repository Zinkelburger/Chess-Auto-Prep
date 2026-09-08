/// Mode picker, placed between Actions and the settings gear in app bars.
/// Its grouped menu and Ctrl+digit shortcuts share the app mode registry.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_text_styles.dart';
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
    final picker = PopupMenuButton<AppMode>(
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
      // Drawn exactly like the Actions anchor beside it: label, drop arrow,
      // no box. The current mode's name is the whole label, so the bar
      // still says where you are without a "View" prefix.
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              mode.label,
              style: AppTextStyles.bodyStrong.copyWith(
                color: locked ? AppColors.onSurfaceDisabled : AppColors.ink,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.arrow_drop_down,
              size: 20,
              color: locked ? AppColors.onSurfaceDisabled : AppColors.ink,
            ),
          ],
        ),
      ),
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
