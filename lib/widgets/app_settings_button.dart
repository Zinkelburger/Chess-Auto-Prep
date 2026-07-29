import 'package:flutter/material.dart';

import '../screens/settings_screen.dart';

/// App-bar gear that opens the global [SettingsScreen].
///
/// Sits beside [AppModeMenuButton] on every mode's app bar so accounts,
/// engine resources, and the eval database are reachable from anywhere —
/// not just the repertoire toolbar's overflow menu.
class AppSettingsButton extends StatelessWidget {
  const AppSettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.settings_outlined),
      tooltip: 'App settings',
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      ),
    );
  }
}
