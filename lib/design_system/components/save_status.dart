import 'package:flutter/material.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

enum SaveStatusTone { normal, error }

/// Localized presentation only: callers own state, draft and action semantics.
/// No file operations, dialogs or automatic retries live in this control.
class SaveStatus extends StatelessWidget {
  const SaveStatus({
    super.key,
    required this.message,
    this.busy = false,
    this.tone = SaveStatusTone.normal,
    this.actions = const [],
  });
  final String message;
  final bool busy;
  final SaveStatusTone tone;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (busy) ...[
              const SizedBox(
                width: AppSpacing.lg,
                height: AppSpacing.lg,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            Expanded(
              child: Text(
                message,
                style: AppTypography.body(context).copyWith(
                  color: tone == SaveStatusTone.error
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
            ),
          ],
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: actions,
          ),
        ],
      ],
    ),
  );
}
