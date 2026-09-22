import '../../features/settings/widgets/settings_section_status.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';

import '../../constants/engine_defaults.dart';
import '../../features/settings/controllers/bulk_analysis_settings.dart';
import '../../features/settings/controllers/engine_settings.dart';
import '../../theme/app_text_styles.dart';
import '../common/number_stepper.dart';
import '../engine/engine_resource_controls.dart';
import '../app_settings_button.dart';

Future<void> showStockfishSettingsDialog(BuildContext context) =>
    openAppSettings(context, initialGlobalSection: 3);

/// The same controls in global settings and the compact engine popup.
class StockfishSettingsBody extends StatelessWidget {
  const StockfishSettingsBody({super.key, this.showBulkDepth = true});

  final bool showBulkDepth;

  @override
  Widget build(BuildContext context) {
    final settings = context.read<EngineSettings>();
    final bulk = context.read<BulkAnalysisSettings>();
    return ListenableBuilder(
      listenable: Listenable.merge([settings, bulk]),
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSectionStatus(
            owner: settings,
            policy: 'Saved engine changes apply to the next search or job.',
          ),
          if (showBulkDepth)
            SettingsSectionStatus(
              owner: bulk,
              policy: 'Game analysis depth applies to the next job.',
            ),
          EngineResourceControls(
            cores: settings.editing.cores,
            hashMb: settings.editing.hashMb,
            onCoresChanged: (v) => settings.cores = v,
            onHashChanged: (v) => settings.hashMb = v,
          ),
          _row(
            'Board analysis depth',
            'engine-board-depth',
            settings.editing.depth,
            kMinDepth,
            kMaxDepth,
            (v) => settings.depth = v,
          ),
          if (showBulkDepth)
            _row(
              'Game analysis depth',
              'engine-bulk-depth',
              bulk.editing.depth,
              BulkAnalysisSettings.minDepth,
              BulkAnalysisSettings.maxDepth,
              (value) => bulk.setDepth(value).catchError((Object _) {}),
            ),
          _row(
            'Suggested lines',
            'engine-lines',
            settings.editing.multiPv,
            kMinMultiPv,
            kMaxMultiPv,
            (v) => settings.multiPv = v,
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
