import 'package:flutter/material.dart';

import '../screens/settings_screen.dart';

/// Pushes the global [SettingsScreen].
///
/// Screens reach settings through an "App settings…" row in their overflow
/// menu rather than a gear of their own — the bar is meant to hold the title,
/// one primary action, that menu, and the mode switcher, and a gear on every
/// bar was one control's worth of chrome repeated five times. This is the
/// shared push so every row lands in the same place.
Future<void> openAppSettings(BuildContext context) {
  return Navigator.push<void>(
    context,
    MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
  );
}

/// App-bar gear that opens the global [SettingsScreen].
///
/// Only for bars with no overflow menu to put the row in (the mode-picker
/// home screen). Everywhere else, use an "App settings…" [AppMenuEntry].
class AppSettingsButton extends StatelessWidget {
  const AppSettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.settings_outlined),
      tooltip: 'App settings',
      onPressed: () => openAppSettings(context),
    );
  }
}
