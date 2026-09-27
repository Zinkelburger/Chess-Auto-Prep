import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/app_state.dart';
import '../../design_system/layout/workspace_navigation_controller.dart';
import '../../widgets/app_mode_switcher.dart';
import '../../widgets/app_overflow_menu.dart';
import '../../widgets/app_settings_button.dart';
import '../../l10n/generated/app_localizations.dart';

/// Child destinations own their form/picker actions. Do not expose commands
/// against the board that happens to remain mounted underneath them.
class WorkspaceDestinationToolbar extends StatelessWidget
    implements PreferredSizeWidget {
  const WorkspaceDestinationToolbar({
    super.key,
    required this.mode,
    required this.navigation,
  });
  final AppMode mode;
  final WorkspaceNavigationController navigation;
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) => AppBar(
    automaticallyImplyLeading: false,
    titleSpacing: 16,
    title: Text(mode.label),
    actions: [
      AppOverflowMenu(
        entries: [
          AppMenuEntry(
            label: AppLocalizations.of(context).backToPreviousView,
            icon: Icons.arrow_back,
            onRun: () => unawaited(navigation.maybePop()),
          ),
        ],
      ),
      const AppModeSwitcher(),
      // The retained root app bar owns settings registration; this is only an
      // entry point, so opening a picker never replaces that owner's builder.
      IconButton(
        tooltip: 'Settings',
        icon: const Icon(Icons.settings_outlined, size: 20),
        onPressed: () => unawaited(openAppSettings(context, initialMode: mode)),
      ),
    ],
  );
}
