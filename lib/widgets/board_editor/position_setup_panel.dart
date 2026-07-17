/// Metadata controls for the board editor: side to move, castling rights,
/// en passant, FEN in/out, clear/start shortcuts, and a caller-labelled
/// primary action gated on position validity.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/board_editor_controller.dart';
import '../../utils/app_messages.dart';

class PositionSetupPanel extends StatefulWidget {
  final BoardEditorController controller;

  /// Label for the primary action button (e.g. "Use position",
  /// "Record solution").  Hidden when null.
  final String? actionLabel;

  /// Invoked with the validated position when the action button is pressed.
  final void Function(Position position)? onAction;

  const PositionSetupPanel({
    super.key,
    required this.controller,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<PositionSetupPanel> createState() => _PositionSetupPanelState();
}

class _PositionSetupPanelState extends State<PositionSetupPanel> {
  late final TextEditingController _fenCtrl;
  final FocusNode _fenFocus = FocusNode();

  BoardEditorController get _editor => widget.controller;

  @override
  void initState() {
    super.initState();
    _fenCtrl = TextEditingController(text: _editor.fen);
    _editor.addListener(_onEditorChanged);
    _fenFocus.addListener(_onFenFocusChanged);
  }

  @override
  void dispose() {
    _editor.removeListener(_onEditorChanged);
    _fenFocus.removeListener(_onFenFocusChanged);
    _fenFocus.dispose();
    _fenCtrl.dispose();
    super.dispose();
  }

  void _onEditorChanged() {
    if (!mounted) return;
    // Only push board→text while the user is not typing in the field,
    // otherwise every keystroke would be clobbered by the round-trip.
    if (!_fenFocus.hasFocus) {
      _fenCtrl.text = _editor.fen;
    }
    setState(() {});
  }

  void _onFenFocusChanged() {
    // On blur, re-sync the field with the canonical editor FEN.
    if (!_fenFocus.hasFocus) {
      _fenCtrl.text = _editor.fen;
    }
  }

  void _applyFenInput(String value) {
    if (!_editor.loadFen(value)) {
      showAppSnackBar(context, 'Could not parse FEN.', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _editor.validationError;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Side to move + board shortcuts ─────────────────────────
          Row(
            children: [
              SegmentedButton<Side>(
                segments: const [
                  ButtonSegment(
                    value: Side.white,
                    label: Text('White to move'),
                  ),
                  ButtonSegment(
                    value: Side.black,
                    label: Text('Black to move'),
                  ),
                ],
                selected: {_editor.turn},
                onSelectionChanged: (sel) => _editor.setTurn(sel.first),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.replay, size: 16),
                label: const Text('Start position'),
                onPressed: _editor.setStartPosition,
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.clear, size: 16),
                label: const Text('Clear board'),
                onPressed: _editor.clear,
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Castling rights ────────────────────────────────────────
          Text('Castling', style: theme.textTheme.labelLarge),
          Row(
            children: [
              _castleBox(
                'White O-O',
                _editor.whiteKingside,
                _editor.whiteKingsideAllowed,
                _editor.setWhiteKingside,
              ),
              _castleBox(
                'White O-O-O',
                _editor.whiteQueenside,
                _editor.whiteQueensideAllowed,
                _editor.setWhiteQueenside,
              ),
            ],
          ),
          Row(
            children: [
              _castleBox(
                'Black O-O',
                _editor.blackKingside,
                _editor.blackKingsideAllowed,
                _editor.setBlackKingside,
              ),
              _castleBox(
                'Black O-O-O',
                _editor.blackQueenside,
                _editor.blackQueensideAllowed,
                _editor.setBlackQueenside,
              ),
            ],
          ),

          // ── En passant ─────────────────────────────────────────────
          if (_editor.epCandidates.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text('En passant', style: theme.textTheme.labelLarge),
                const SizedBox(width: 12),
                DropdownButton<Square?>(
                  value: _editor.epSquare,
                  isDense: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('none')),
                    for (final sq in _editor.epCandidates)
                      DropdownMenuItem(value: sq, child: Text(sq.name)),
                  ],
                  onChanged: _editor.setEpSquare,
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),

          // ── FEN in/out ─────────────────────────────────────────────
          TextField(
            controller: _fenCtrl,
            focusNode: _fenFocus,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'FEN',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    tooltip: 'Copy FEN',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _editor.fen));
                      showAppSnackBar(context, 'FEN copied.');
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.content_paste, size: 16),
                    tooltip: 'Paste FEN',
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      final text = data?.text;
                      if (text != null && text.trim().isNotEmpty && mounted) {
                        _applyFenInput(text);
                      }
                    },
                  ),
                ],
              ),
            ),
            onSubmitted: _applyFenInput,
          ),

          // ── Validation + action ────────────────────────────────────
          if (error != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.warning_amber,
                  size: 16,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (widget.actionLabel != null) ...[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _editor.validPosition == null
                  ? null
                  : () => widget.onAction?.call(_editor.validPosition!),
              child: Text(widget.actionLabel!),
            ),
          ],
        ],
      ),
    );
  }

  Widget _castleBox(
    String label,
    bool value,
    bool allowed,
    ValueChanged<bool> onChanged,
  ) {
    return Expanded(
      child: CheckboxListTile(
        title: Text(label, style: const TextStyle(fontSize: 13)),
        value: value,
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        onChanged: allowed ? (v) => onChanged(v ?? false) : null,
      ),
    );
  }
}
