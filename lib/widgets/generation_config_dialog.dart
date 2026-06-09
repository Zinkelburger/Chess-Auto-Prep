/// Modal dialog wrapping [RepertoireGenerationTab] for full generation config.
///
/// Opened from the toolbar sparkles button or the G shortcut key.
/// Contains the full generation config UI and starts generation on Build.
library;

import 'package:flutter/material.dart';

import 'repertoire_generation_tab.dart';

/// Shows the generation config dialog and returns true if generation was started.
Future<bool?> showGenerationConfigDialog(
  BuildContext context, {
  required String fen,
  required bool isWhiteRepertoire,
  required Map<String, dynamic>? currentRepertoire,
  required List<String> currentMoveSequence,
  required void Function(bool) onGeneratingChanged,
  required void Function(bool) onPauseChanged,
  required void Function(List<String>, String, String) onLineSaved,
  required VoidCallback onTreeReset,
  required void Function(dynamic tree) onTreeBuilt,
  GlobalKey<RepertoireGenerationTabState>? generationTabKey,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 20),
                  const SizedBox(width: 8),
                  Text('Generate Repertoire',
                      style: Theme.of(dialogCtx).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(dialogCtx).pop(false),
                  ),
                ],
              ),
            ),
            const Divider(),
            Flexible(
              child: RepertoireGenerationTab(
                key: generationTabKey,
                fen: fen,
                isWhiteRepertoire: isWhiteRepertoire,
                currentRepertoire: currentRepertoire,
                currentMoveSequence: currentMoveSequence,
                onGeneratingChanged: (generating) {
                  onGeneratingChanged(generating);
                  if (generating) {
                    Navigator.of(dialogCtx).pop(true);
                  }
                },
                onPauseChanged: onPauseChanged,
                onLineSaved: onLineSaved,
                onTreeReset: onTreeReset,
                onTreeBuilt: onTreeBuilt,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
