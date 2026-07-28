/// App-bar readout for a collection download running in the background.
///
/// A chessgames.com collection is a ~25-minute job that deliberately outlives
/// the dialog that started it, so Study mode needs somewhere to say it is
/// still going — and somewhere to stop it. Renders nothing while idle.
library;

import 'package:flutter/material.dart';

import '../../services/study_import/study_import_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

class StudyImportStatusChip extends StatelessWidget {
  const StudyImportStatusChip({super.key, this.controller});

  /// Defaults to the app-wide instance; injectable for widget tests.
  final StudyImportController? controller;

  @override
  Widget build(BuildContext context) {
    final import = controller ?? StudyImportController.instance;
    return ListenableBuilder(
      listenable: import,
      builder: (context, _) {
        if (!import.isRunning) return const SizedBox.shrink();
        return Tooltip(
          message: '${import.label}\n${import.message}',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: import.fraction == 0 ? null : import.fraction,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Importing ${import.gamesDone}/${import.gamesTotal}',
                  style: AppTextStyles.caption,
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Stop the download (keeps what has arrived)',
                  color: AppColors.onSurfaceMuted,
                  onPressed: import.cancel,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
