/// Modal dialog wrapping [RepertoireGenerationTab] for full generation config.
///
/// Opened from the toolbar sparkles button or the G shortcut key.
/// Contains the full generation config UI and starts generation on Build.
library;

import 'package:flutter/material.dart';

import '../core/generation_session_controller.dart';
import 'repertoire_generation_tab.dart';

/// Shows the generation config dialog and returns true if generation was started.
Future<bool?> showGenerationConfigDialog(
  BuildContext context, {
  required String fen,
  required bool isWhiteRepertoire,
  required Map<String, dynamic>? currentRepertoire,
  required List<String> currentMoveSequence,
  required void Function(List<String>, String, String) onLineSaved,
  required GenerationSessionController generationController,
  GlobalKey<RepertoireGenerationTabState>? generationTabKey,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => _GenerationConfigDialog(
      fen: fen,
      isWhiteRepertoire: isWhiteRepertoire,
      currentRepertoire: currentRepertoire,
      currentMoveSequence: currentMoveSequence,
      onLineSaved: onLineSaved,
      generationController: generationController,
      generationTabKey: generationTabKey,
    ),
  );
}

class _GenerationConfigDialog extends StatefulWidget {
  final String fen;
  final bool isWhiteRepertoire;
  final Map<String, dynamic>? currentRepertoire;
  final List<String> currentMoveSequence;
  final void Function(List<String>, String, String) onLineSaved;
  final GenerationSessionController generationController;
  final GlobalKey<RepertoireGenerationTabState>? generationTabKey;

  const _GenerationConfigDialog({
    required this.fen,
    required this.isWhiteRepertoire,
    required this.currentRepertoire,
    required this.currentMoveSequence,
    required this.onLineSaved,
    required this.generationController,
    required this.generationTabKey,
  });

  @override
  State<_GenerationConfigDialog> createState() =>
      _GenerationConfigDialogState();
}

class _GenerationConfigDialogState extends State<_GenerationConfigDialog> {
  @override
  void initState() {
    super.initState();
    widget.generationController.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.generationController.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (widget.generationController.isGenerating && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
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
                      style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
            ),
            const Divider(),
            Flexible(
              child: RepertoireGenerationTab(
                key: widget.generationTabKey,
                fen: widget.fen,
                isWhiteRepertoire: widget.isWhiteRepertoire,
                currentRepertoire: widget.currentRepertoire,
                currentMoveSequence: widget.currentMoveSequence,
                generationController: widget.generationController,
                onLineSaved: widget.onLineSaved,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
