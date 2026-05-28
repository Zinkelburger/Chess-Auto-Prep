/// Compact footer for the unified engine pane showing cumulative probability.
library;

import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
import '../../services/analysis_service.dart';
import '../../services/probability_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/chess_utils.dart' show formatCount;
import '../lichess_db_info_icon.dart';

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
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.grey[800]!, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          if (settings.showProbability) ...[
            ValueListenableBuilder<double>(
              valueListenable: probabilityService.cumulativeProbability,
              builder: (_, cumulative, __) {
                final dbMuted =
                    settings.isAnalysisColumnMuted(EngineSettings.colDb);
                return Tooltip(
                  message: 'Cumulative probability along this line\n'
                      'Tap value to dim the DB column.',
                  child: InkWell(
                    onTap: () {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        settings.toggleAnalysisColumnMuted(
                            EngineSettings.colDb);
                      });
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Cumulative DB',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[500]),
                          ),
                          const LichessDbInfoIcon(size: 12),
                          const SizedBox(width: 2),
                          Text(
                            '${cumulative.toStringAsFixed(1)}%',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color:
                                  AppColors.lichessDbColor(muted: dbMuted),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            if (onSetRoot != null) ...[
              const SizedBox(width: 8),
              SizedBox(
                height: 26,
                child: TextButton.icon(
                  onPressed: onSetRoot,
                  icon: const Icon(Icons.my_location, size: 14),
                  label:
                      const Text('Set as root', style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ],
          const Spacer(),
          if (settings.showProbability)
            ValueListenableBuilder<ExplorerResponse?>(
              valueListenable: probabilityService.currentPosition,
              builder: (_, posData, __) {
                if (posData == null || posData.totalGames == 0) {
                  return const SizedBox.shrink();
                }
                return Text(
                  '${formatCount(posData.totalGames)} games',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                );
              },
            ),
        ],
      ),
    );
      },
    );
  }

}
