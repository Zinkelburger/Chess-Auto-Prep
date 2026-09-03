/// The labelled mode picker that is also the navigation.
///
/// It reads `Tactics ▾`: the current mode, and the menu of the others behind
/// it. It sits at the **right** end of every app bar, immediately before that
/// bar's settings control (a gear, or the "App settings…" row of its overflow
/// menu), because that is the side the pointer already lives on — it spent a
/// while as the bar's title on the left, which meant crossing the window for
/// every mode switch. The menu is grouped (Train / Build / Analyse / Lab),
/// text only, 13px rows via [AppMenuEntryRow] like every other menu in the
/// app, and shows the Ctrl+digit chord beside each mode.
///
/// The chords themselves are bound once in `MainScreen`, not here.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../theme/app_colors.dart';
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
    return PopupMenuButton<AppMode>(
      key: switcherKey,
      tooltip: locked
          ? 'Locked — repertoire generation in progress'
          : 'Switch mode (Ctrl+1…${availableModeMenuOrder().length})',
      enabled: !locked,
      onSelected: context.read<AppState>().setMode,
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      itemBuilder: (context) => [
        for (final group in availableAppModeGroups()) ...[
          PopupMenuItem<AppMode>(
            enabled: false,
            height: 28,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              group.heading.toUpperCase(),
              style: AppTextStyles.eyebrow,
            ),
          ),
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
