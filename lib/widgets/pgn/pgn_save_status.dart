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
    final l10n = AppLocalizations.of(context);
    final failed = error != null && dirty;
    final String label;
    final String explanation;
    if (failed) {
      label = l10n.generationRecoveryNotSaved;
      explanation = error!;
    } else if (filePath == null) {
      label = l10n.pgnNotSavedFile;
      explanation = l10n.pgnChooseSaveFile;
    } else if (saving || (autoSave && dirty)) {
      label = l10n.documentSaving;
      explanation = l10n.pgnSavingPath(filePath!);
    } else if (dirty) {
      label = l10n.documentDirty;
      explanation = l10n.pgnManualSavePath(filePath!);
    } else {
      label = autoSave ? l10n.pgnAutoSaved : l10n.pgnManualSaved;
      explanation = autoSave
          ? l10n.pgnAutoSavePath(filePath!)
          : l10n.pgnNeedsManualSavePath(filePath!);
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
