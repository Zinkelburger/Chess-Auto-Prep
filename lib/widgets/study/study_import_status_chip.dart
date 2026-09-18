/// App-bar readout for a collection download running in the background.
///
/// A chessgames.com collection is a ~25-minute job that deliberately outlives
/// the dialog that started it, so Study mode needs somewhere to say it is
/// still going — and somewhere to stop it. Renders nothing while idle.
library;

import 'package:flutter/material.dart';

import '../../features/studies/controllers/study_import_controller.dart';
import '../../design_system/theme/app_typography.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/study_import_labels.dart';

class StudyImportStatusChip extends StatelessWidget {
  const StudyImportStatusChip({
    super.key,
    required this.controller,
    required this.onReview,
  });

  final StudyImportController controller;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final import = controller;
    return ListenableBuilder(
      listenable: import,
      builder: (context, _) {
        if (!import.isRunning) {
          if (import.needsPublicationReview) {
            return Tooltip(
              message: AppLocalizations.of(context).studyImportReview,
              child: TextButton.icon(
                onPressed: onReview,
                icon: const Icon(Icons.warning_amber),
                label: Text(
                  AppLocalizations.of(context).studyImportReviewAction,
                ),
              ),
            );
          }
          return const SizedBox.shrink();
        }
        return Tooltip(
          message:
              '${import.label}\n${studyImportProgressLabel(AppLocalizations.of(context), import.progress, import.gamesTotal)}',
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
                  AppLocalizations.of(
                    context,
                  ).studyImportProgress(import.gamesDone, import.gamesTotal),
                  style: AppTypography.caption(context),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: AppLocalizations.of(context).studyImportStop,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
