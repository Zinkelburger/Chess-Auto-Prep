import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../l10n/generated/app_localizations.dart';

/// Bootstrap UI when no repertoire is loaded or training cannot start yet.
class RepertoireSelectorPanel extends StatelessWidget {
  final bool isLoading;
  final String loadingStatus;
  final String? error;
  final bool progressNeedsReload;
  final bool hasLines;
  final bool canStartTraining;
  final VoidCallback onSelectRepertoire;
  final VoidCallback? onStartTraining;
  final VoidCallback? onRetry;

  /// Opens the loaded repertoire in the Builder. Shown beside the error so an
  /// empty repertoire has a way forward other than picking a different one.
  final VoidCallback? onOpenInBuilder;

  const RepertoireSelectorPanel({
    super.key,
    required this.isLoading,
    this.loadingStatus = 'Loading repertoire…',
    this.error,
    this.progressNeedsReload = false,
    required this.hasLines,
    required this.canStartTraining,
    required this.onSelectRepertoire,
    this.onStartTraining,
    this.onRetry,
    this.onOpenInBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(loadingStatus, textAlign: TextAlign.center),
          ],
        ),
      );
    }

    if (error != null || progressNeedsReload) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: AppColors.danger),
            const SizedBox(height: 12),
            Text(
              progressNeedsReload
                  ? AppLocalizations.of(context).trainingProgressPartial
                  : error!,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (onRetry != null)
                  FilledButton(
                    onPressed: onRetry,
                    child: Text(
                      progressNeedsReload
                          ? AppLocalizations.of(context).trainingReloadProgress
                          : 'Retry',
                    ),
                  ),
                if (onOpenInBuilder != null)
                  FilledButton(
                    onPressed: onOpenInBuilder,
                    child: const Text('Add lines in Repertoire Builder'),
                  ),
                if (onOpenInBuilder != null)
                  OutlinedButton(
                    onPressed: onSelectRepertoire,
                    child: const Text('Select Repertoire'),
                  )
                else
                  FilledButton(
                    onPressed: onSelectRepertoire,
                    child: const Text('Select Repertoire'),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    if (canStartTraining && onStartTraining != null) {
      return Center(
        child: FilledButton(
          onPressed: onStartTraining,
          child: const Text('Start Training'),
        ),
      );
    }

    if (!hasLines) {
      return const Center(child: Text('No lines available.'));
    }

    return const SizedBox.shrink();
  }
}
