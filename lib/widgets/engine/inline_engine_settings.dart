import 'package:flutter/material.dart';

import '../../constants/engine_defaults.dart';
import '../../models/engine_settings.dart';
import '../../theme/app_text_styles.dart';
import '../common/number_stepper.dart';

/// Compact controls using the same persisted preferences as global settings.
class InlineEngineSettings extends StatelessWidget {
  const InlineEngineSettings({super.key});

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      SizedBox(
        width: 320,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListenableBuilder(
            listenable: EngineSettings.instance,
            builder: (context, _) {
              final settings = EngineSettings.instance;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Engine settings',
                    style: AppTextStyles.bodyStrong,
                  ),
                  const SizedBox(height: 8),
                  _row(
                    'Cores',
                    settings.cores,
                    1,
                    EngineSettings.systemCores,
                    (v) => settings.cores = v,
                  ),
                  _row(
                    'Lines',
                    settings.multiPv,
                    kMinMultiPv,
                    kMaxMultiPv,
                    (v) => settings.multiPv = v,
                  ),
                  _row(
                    'Depth',
                    settings.depth,
                    kMinDepth,
                    kMaxDepth,
                    (v) => settings.depth = v,
                  ),
                  _row(
                    'Memory (MB)',
                    settings.hashMb,
                    kMinHashMb,
                    kMaxHashMb,
                    (v) => settings.hashMb = v,
                    step: 16,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Shared with global engine settings.',
                    style: AppTextStyles.caption,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ],
    builder: (context, controller, _) => IconButton(
      icon: const Icon(Icons.settings_outlined, size: 18),
      tooltip: 'Engine settings',
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    ),
  );

  Widget _row(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged, {
    int step = 1,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(child: Text(label, style: AppTextStyles.body)),
        NumberStepper(
          value: value,
          min: min,
          max: max,
          step: step,
          onChanged: onChanged,
        ),
      ],
    ),
  );
}
