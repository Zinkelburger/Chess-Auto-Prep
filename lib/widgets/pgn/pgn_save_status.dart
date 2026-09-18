/// Quiet, fixed-width file status: no spinner, toast, or layout shift on save.
library;

import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../design_system/theme/app_typography.dart';

class PgnSaveStatus extends StatelessWidget {
  const PgnSaveStatus({
    super.key,
    required this.filePath,
    required this.autoSave,
    required this.dirty,
    this.saving = false,
    this.error,
  });

  final String? filePath;
  final bool autoSave;
  final bool dirty;
  final bool saving;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final failed = error != null && dirty;
    final String label;
    final String explanation;
    if (failed) {
      label = AppLocalizations.of(context).generationRecoveryNotSaved;
      explanation = error!;
    } else if (filePath == null) {
      label = AppLocalizations.of(context).pgnNotSavedFile;
      explanation = AppLocalizations.of(context).pgnChooseSaveFile;
    } else if (saving || (autoSave && dirty)) {
      label = AppLocalizations.of(context).documentSaving;
      explanation = AppLocalizations.of(context).pgnSavingPath(filePath!);
    } else if (dirty) {
      label = AppLocalizations.of(context).documentDirty;
      explanation = AppLocalizations.of(context).pgnManualSavePath(filePath!);
    } else {
      label = autoSave
          ? AppLocalizations.of(context).pgnAutoSaved
          : AppLocalizations.of(context).pgnManualSaved;
      explanation = autoSave
          ? AppLocalizations.of(context).pgnAutoSavePath(filePath!)
          : AppLocalizations.of(context).pgnNeedsManualSavePath(filePath!);
    }
    return SizedBox(
      width: 150,
      child: Tooltip(
        message: explanation,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.caption(context).copyWith(
            color: failed
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
