/// Edit dialog for a stored tactics position.
///
/// Extracted from `tactics_control_panel.dart`. A self-contained
/// dialog that shows read-only game context plus editable mistake-type /
/// correct-line / analysis fields. On save it returns the updated
/// [TacticsPosition] (via `copyWith`); persistence stays with the caller.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/tactics_position.dart';
import '../../utils/app_messages.dart';

class TacticsEditDialog extends StatefulWidget {
  final TacticsPosition position;
  final int index;

  const TacticsEditDialog({
    super.key,
    required this.position,
    required this.index,
  });

  /// Show the dialog; resolves to the updated [TacticsPosition] on Save, or
  /// `null` if the user cancelled.
  static Future<TacticsPosition?> show(
    BuildContext context, {
    required TacticsPosition position,
    required int index,
  }) {
    return showDialog<TacticsPosition>(
      context: context,
      builder: (_) => TacticsEditDialog(position: position, index: index),
    );
  }

  @override
  State<TacticsEditDialog> createState() => _TacticsEditDialogState();
}

class _TacticsEditDialogState extends State<TacticsEditDialog> {
  late final TextEditingController _correctLineCtrl;
  late final TextEditingController _mistakeTypeCtrl;
  late final TextEditingController _analysisCtrl;

  @override
  void initState() {
    super.initState();
    final pos = widget.position;
    _correctLineCtrl = TextEditingController(text: pos.correctLine.join(' | '));
    _mistakeTypeCtrl = TextEditingController(text: pos.mistakeType);
    _analysisCtrl = TextEditingController(text: pos.mistakeAnalysis);
  }

  @override
  void dispose() {
    _correctLineCtrl.dispose();
    _mistakeTypeCtrl.dispose();
    _analysisCtrl.dispose();
    super.dispose();
  }

  Future<void> _copyToClipboard(String text, String message) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) showAppSnackBar(context, message);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, AppMessages.clipboardWriteFailed,
            isError: true);
      }
    }
  }

  void _save() {
    final updated = widget.position.copyWith(
      correctLine: _correctLineCtrl.text
          .split('|')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      mistakeType: _mistakeTypeCtrl.text.trim(),
      mistakeAnalysis: _analysisCtrl.text,
    );
    Navigator.pop(context, updated);
  }

  @override
  Widget build(BuildContext context) {
    final pos = widget.position;
    return AlertDialog(
      title: Text('Edit Tactic #${widget.index + 1}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Read-only context
              _readOnlyField('FEN', pos.fen),
              _readOnlyField('Game', '${pos.gameWhite} vs ${pos.gameBlack}'),
              _readOnlyField('Context', pos.positionContext),
              _readOnlyField('You Played', pos.userMove),
              _readOnlyField('Game ID', pos.gameId),
              if (pos.reviewCount > 0)
                _readOnlyField('Stats',
                    '${pos.successCount}/${pos.reviewCount} (${(pos.successRate * 100).toStringAsFixed(0)}%)'),
              const SizedBox(height: 8),
              // One-click export for reusing the puzzle elsewhere.
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _copyToClipboard(pos.fen, 'FEN copied.'),
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Copy FEN'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _copyToClipboard(
                      _correctLineCtrl.text
                          .split('|')
                          .map((s) => s.trim())
                          .where((s) => s.isNotEmpty)
                          .join(' '),
                      'Moves copied.',
                    ),
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Copy moves'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Editable fields',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 8),

              // Editable fields
              TextField(
                controller: _mistakeTypeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Mistake Type',
                  hintText: '? or ??',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _correctLineCtrl,
                decoration: const InputDecoration(
                  labelText: 'Correct Line (pipe-separated)',
                  hintText: 'Nf3 | e4 | Bb5',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _analysisCtrl,
                decoration: const InputDecoration(
                  labelText: 'Analysis',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        ElevatedButton(
            onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  Widget _readOnlyField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text('$label:',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
