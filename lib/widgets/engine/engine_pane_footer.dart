/// Compact footer for the unified engine pane showing cumulative probability.
library;

import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
import '../../services/analysis_service.dart';
import '../../services/probability_service.dart';
import '../../theme/app_colors.dart';

class EnginePaneFooter extends StatelessWidget {
  final EngineSettings settings;
  final AnalysisService analysis;
  final ProbabilityService probabilityService;
  final String fen;
  final Map<String, double>? maiaProbs;
  final bool isWhiteRepertoire;
  final VoidCallback? onSetRoot;

  const EnginePaneFooter({
    super.key,
    required this.settings,
    required this.analysis,
    required this.probabilityService,
    required this.fen,
    required this.maiaProbs,
    this.isWhiteRepertoire = true,
    this.onSetRoot,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: AppColors.divider, width: 0.5),
            ),
          ),
          // Mothballed: Lichess Explorer stats hidden.
          // Keep "Set as root" button if available.
          child: Row(
            children: [
              if (onSetRoot != null)
                SizedBox(
                  height: 26,
                  child: TextButton.icon(
                    onPressed: onSetRoot,
                    icon: const Icon(Icons.my_location, size: 14),
                    label: const Text(
                      'Set as root',
                      style: TextStyle(fontSize: 11),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              const Spacer(),
            ],
          ),
        );
      },
    );
  }
}
