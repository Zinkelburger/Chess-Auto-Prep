import 'package:flutter/material.dart';

import '../../theme/app_text_styles.dart';
import '../analysis/stockfish_settings_dialog.dart';

/// Compact controls using the same persisted preferences as global settings.
class InlineEngineSettings extends StatefulWidget {
  const InlineEngineSettings({super.key});

  @override
  State<InlineEngineSettings> createState() => _InlineEngineSettingsState();
}

class _InlineEngineSettingsState extends State<InlineEngineSettings> {
  final _formKey = GlobalKey<FormState>();

  @override
  Widget build(BuildContext context) => MenuAnchor(
    onClose: () => _formKey.currentState?.save(),
    menuChildren: [
      SizedBox(
        width: 320,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Engine settings', style: AppTextStyles.bodyStrong),
                SizedBox(height: 8),
                StockfishSettingsBody(showBulkDepth: false),
              ],
            ),
          ),
        ),
      ),
    ],
    builder: (context, controller, _) => IconButton(
      icon: const Icon(Icons.settings_outlined, size: 16),
      tooltip: 'Engine settings',
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    ),
  );
}
