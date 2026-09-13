/// Quiet, fixed-width file status: no spinner, toast, or layout shift on save.
library;

import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

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
      label = 'Not saved';
      explanation = error!;
    } else if (filePath == null) {
      label = 'Not saved to a file';
      explanation = 'Use Save as… to choose a PGN file.';
    } else if (saving || (autoSave && dirty)) {
      label = 'Saving…';
      explanation = 'Saving changes to $filePath';
    } else if (dirty) {
      label = 'Unsaved changes';
      explanation = 'Autosave is off. Use Save to write changes to $filePath';
    } else {
      label = autoSave ? 'Autosave on · Saved' : 'Autosave off · Saved';
      explanation = autoSave
          ? 'Changes save automatically to $filePath'
          : 'Changes need a manual save to $filePath';
    }
    return SizedBox(
      width: 150,
      child: Tooltip(
        message: explanation,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.caption.copyWith(
            color: failed ? AppColors.danger : AppColors.onSurfaceMuted,
          ),
        ),
      ),
    );
  }
}
