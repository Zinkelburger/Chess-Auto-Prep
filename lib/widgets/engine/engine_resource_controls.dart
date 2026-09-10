import 'package:flutter/material.dart';

import '../../constants/engine_defaults.dart';
import '../../models/engine_settings.dart';
import '../../theme/app_text_styles.dart';
import '../common/number_stepper.dart';

/// Resource controls shared by board analysis and tournament participants.
class EngineResourceControls extends StatelessWidget {
  const EngineResourceControls({
    super.key,
    required this.cores,
    required this.hashMb,
    required this.onCoresChanged,
    required this.onHashChanged,
  });

  final int cores;
  final int hashMb;
  final ValueChanged<int> onCoresChanged;
  final ValueChanged<int> onHashChanged;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _row(
        'Cores',
        'engine-cores',
        cores,
        1,
        EngineSettings.systemCores,
        onCoresChanged,
      ),
      _row(
        'Memory (MB)',
        'engine-memory',
        hashMb,
        kMinHashMb,
        kMaxHashMb,
        onHashChanged,
        step: 16,
      ),
    ],
  );

  Widget _row(
    String label,
    String key,
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
          key: Key(key),
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
