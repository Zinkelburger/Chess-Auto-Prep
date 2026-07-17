import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Bootstrap UI when no repertoire is loaded or training cannot start yet.
class RepertoireSelectorPanel extends StatelessWidget {
  final bool isLoading;
  final String? error;
  final bool hasLines;
  final bool canStartTraining;
  final VoidCallback onSelectRepertoire;
  final VoidCallback? onStartTraining;

  const RepertoireSelectorPanel({
    super.key,
    required this.isLoading,
    this.error,
    required this.hasLines,
    required this.canStartTraining,
    required this.onSelectRepertoire,
    this.onStartTraining,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading repertoire...'),
          ],
        ),
      );
    }

    if (error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: AppColors.danger),
            const SizedBox(height: 12),
            Text(error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onSelectRepertoire,
              child: const Text('Select Repertoire'),
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
