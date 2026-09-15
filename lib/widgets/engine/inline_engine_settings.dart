import 'package:flutter/material.dart';
import '../analysis/stockfish_settings_dialog.dart';

/// Contextual shortcut to the shared analysis preferences.
class InlineEngineSettings extends StatelessWidget {
  const InlineEngineSettings({super.key});
  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.tune, size: 20),
    tooltip: 'Engine settings',
    onPressed: () => showStockfishSettingsDialog(context),
  );
}
