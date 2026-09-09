import 'package:flutter/material.dart';

import '../../constants/engine_defaults.dart';
import '../../models/bulk_analysis_settings.dart';
import '../../models/engine_settings.dart';
import '../../theme/app_text_styles.dart';
import '../common/number_stepper.dart';
import '../app_settings_button.dart';

Future<void> showStockfishSettingsDialog(BuildContext context) =>
    openAppSettings(context, initialGlobalSection: 3);

/// The same controls in global settings and the compact engine popup.
class StockfishSettingsBody extends StatelessWidget {
  const StockfishSettingsBody({super.key, this.showBulkDepth = true});

  final bool showBulkDepth;

  @override
  Widget build(BuildContext context) {
    final settings = EngineSettings.instance;
    final bulk = BulkAnalysisSettings.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, bulk]),
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row(
            'Cores',
            'engine-cores',
            settings.cores,
            1,
            EngineSettings.systemCores,
            (v) => settings.cores = v,
          ),
          _row(
            'Memory (MB)',
            'engine-memory',
            settings.hashMb,
            kMinHashMb,
            kMaxHashMb,
            (v) => settings.hashMb = v,
            step: 16,
          ),
          _row(
            'Board depth',
            'engine-board-depth',
            settings.depth,
            kMinDepth,
            kMaxDepth,
            (v) => settings.depth = v,
          ),
          if (showBulkDepth)
            _row(
              'Bulk depth',
              'engine-bulk-depth',
              bulk.depth,
              BulkAnalysisSettings.minDepth,
              BulkAnalysisSettings.maxDepth,
              bulk.setDepth,
            ),
          _row(
            'Lines',
            'engine-lines',
            settings.multiPv,
            kMinMultiPv,
            kMaxMultiPv,
            (v) => settings.multiPv = v,
          ),
          _row(
            'PV rows per line',
            'engine-pv-rows',
            settings.pvRows,
            kMinPvRows,
            kMaxPvRows,
            (v) => settings.pvRows = v,
          ),
        ],
      ),
    );
  }

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
