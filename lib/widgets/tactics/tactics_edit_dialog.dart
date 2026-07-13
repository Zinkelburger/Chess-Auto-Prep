/// Edit dialog for a stored tactics position.
///
/// Every field of the tactic is editable — it's the user's data — but the
/// chess-bearing fields are validated live so an illegal state can't be
/// saved: the FEN must parse to a legal position, and the played move /
/// correct line / solution PV must be legal move sequences from that FEN
/// (UCI or SAN tokens, matching what imports produce). Save stays disabled
/// while anything is invalid. On save it returns the updated
/// [TacticsPosition] (via `copyWith`); persistence stays with the caller.
library;

import 'package:dartchess/dartchess.dart';
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
  static const _mistakeTypes = {
    '??': '?? Blunder',
    '?': '? Mistake',
    '?!': '?! Inaccuracy',
    'custom': 'Custom puzzle',
  };

  late final TextEditingController _fenCtrl;
  late final TextEditingController _userMoveCtrl;
  late final TextEditingController _correctLineCtrl;
  late final TextEditingController _solutionPvCtrl;
  late final TextEditingController _analysisCtrl;
  late final TextEditingController _whiteCtrl;
  late final TextEditingController _blackCtrl;
  late final TextEditingController _dateCtrl;
  late final TextEditingController _urlCtrl;
  late String _mistakeType;

  String? _fenError;
  String? _userMoveError;
  String? _correctLineError;
  String? _solutionPvError;

  @override
  void initState() {
    super.initState();
    final pos = widget.position;
    _fenCtrl = TextEditingController(text: pos.fen);
    _userMoveCtrl = TextEditingController(text: pos.userMove);
    _correctLineCtrl = TextEditingController(text: pos.correctLine.join(' | '));
    _solutionPvCtrl = TextEditingController(text: pos.solutionPv.join(' | '));
    _analysisCtrl = TextEditingController(text: pos.mistakeAnalysis);
    _whiteCtrl = TextEditingController(text: pos.gameWhite);
    _blackCtrl = TextEditingController(text: pos.gameBlack);
    _dateCtrl = TextEditingController(text: pos.gameDate);
    _urlCtrl = TextEditingController(text: pos.gameUrl);
    _mistakeType =
        _mistakeTypes.containsKey(pos.mistakeType) ? pos.mistakeType : '?';
    _validate();
  }

  @override
  void dispose() {
    _fenCtrl.dispose();
    _userMoveCtrl.dispose();
    _correctLineCtrl.dispose();
    _solutionPvCtrl.dispose();
    _analysisCtrl.dispose();
    _whiteCtrl.dispose();
    _blackCtrl.dispose();
    _dateCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  bool get _isValid =>
      _fenError == null &&
      _userMoveError == null &&
      _correctLineError == null &&
      _solutionPvError == null;

  List<String> _splitLine(String text) => text
      .split('|')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  static final _uciPattern = RegExp(r'^[a-h][1-8][a-h][1-8][qrbn]?$');

  /// Parse one move token (UCI or SAN — imports store both) against [pos].
  static Move? _parseMoveToken(Position pos, String token) {
    final move =
        _uciPattern.hasMatch(token) ? Move.parse(token) : pos.parseSan(token);
    if (move == null || !pos.isLegal(move)) return null;
    return move;
  }

  /// Null if every token is a legal move played in sequence from [start];
  /// otherwise an error naming the first bad token.
  static String? _validateMoveSequence(Position start, List<String> tokens) {
    var pos = start;
    for (final token in tokens) {
      final move = _parseMoveToken(pos, token);
      if (move == null) return 'Illegal move "$token"';
      pos = pos.play(move);
    }
    return null;
  }

  void _validate() {
    // FEN first — everything else is validated against it.
    Position? start;
    final fen = _fenCtrl.text.trim();
    if (fen.isEmpty) {
      _fenError = 'FEN cannot be blank';
    } else {
      try {
        start = Chess.fromSetup(Setup.parseFen(fen));
        _fenError = null;
      } catch (_) {
        _fenError = 'Not a legal FEN position';
      }
    }

    if (start == null) {
      // Move fields can't be checked without a position; don't pile on
      // errors that will re-resolve once the FEN is fixed.
      _userMoveError = null;
      _correctLineError = null;
      _solutionPvError = null;
      return;
    }

    final userMove = _userMoveCtrl.text.trim();
    _userMoveError = userMove.isEmpty || _parseMoveToken(start, userMove) != null
        ? null
        : 'Not a legal move from this FEN';

    final line = _splitLine(_correctLineCtrl.text);
    _correctLineError = line.isEmpty
        ? 'Need at least one solution move'
        : _validateMoveSequence(start, line);

    final pv = _splitLine(_solutionPvCtrl.text);
    _solutionPvError = pv.isEmpty ? null : _validateMoveSequence(start, pv);
  }

  void _onChanged() => setState(_validate);

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
      fen: _fenCtrl.text.trim(),
      userMove: _userMoveCtrl.text.trim(),
      correctLine: _splitLine(_correctLineCtrl.text),
      solutionPv: _splitLine(_solutionPvCtrl.text),
      mistakeType: _mistakeType,
      mistakeAnalysis: _analysisCtrl.text,
      gameWhite: _whiteCtrl.text.trim(),
      gameBlack: _blackCtrl.text.trim(),
      gameDate: _dateCtrl.text.trim(),
      gameUrl: _urlCtrl.text.trim(),
    );
    Navigator.pop(context, updated);
  }

  @override
  Widget build(BuildContext context) {
    final pos = widget.position;
    return AlertDialog(
      title: Text('Edit Tactic #${widget.index + 1}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // One-click export for reusing the puzzle elsewhere.
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () =>
                        _copyToClipboard(_fenCtrl.text.trim(), 'FEN copied.'),
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Copy FEN'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _copyToClipboard(
                      _splitLine(_correctLineCtrl.text).join(' '),
                      'Moves copied.',
                    ),
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Copy moves'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Puzzle',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 8),
              _textField(
                controller: _fenCtrl,
                label: 'FEN (position to solve)',
                errorText: _fenError,
                monospace: true,
              ),
              const SizedBox(height: 12),
              _textField(
                controller: _userMoveCtrl,
                label: 'Move you played (UCI or SAN, may be empty)',
                hint: 'c6e5 or Nxe5',
                errorText: _userMoveError,
                monospace: true,
              ),
              const SizedBox(height: 12),
              _textField(
                controller: _correctLineCtrl,
                label: 'Correct line (moves separated by |)',
                hint: 'Nf3 | e4 | Bb5',
                errorText: _correctLineError,
                monospace: true,
              ),
              const SizedBox(height: 12),
              _textField(
                controller: _solutionPvCtrl,
                label: 'Solution display line (optional, separated by |)',
                hint: 'Longer engine line shown with the solution',
                errorText: _solutionPvError,
                monospace: true,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _mistakeType,
                decoration: const InputDecoration(
                  labelText: 'Mistake type',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final entry in _mistakeTypes.entries)
                    DropdownMenuItem(
                        value: entry.key, child: Text(entry.value)),
                ],
                onChanged: (v) => setState(() => _mistakeType = v ?? '?'),
              ),
              const SizedBox(height: 12),
              _textField(
                controller: _analysisCtrl,
                label: 'Analysis / note (shown after solving)',
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              const Text('Game info',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                      child: _textField(
                          controller: _whiteCtrl, label: 'White player')),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _textField(
                          controller: _blackCtrl, label: 'Black player')),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                      child: _textField(
                          controller: _dateCtrl,
                          label: 'Date',
                          hint: 'YYYY.MM.DD')),
                  const SizedBox(width: 8),
                  Expanded(
                      flex: 2,
                      child:
                          _textField(controller: _urlCtrl, label: 'Game URL')),
                ],
              ),
              if (pos.gameId.isNotEmpty || pos.reviewCount > 0) ...[
                const SizedBox(height: 12),
                if (pos.gameId.isNotEmpty)
                  _readOnlyField('Game ID', pos.gameId),
                if (pos.reviewCount > 0)
                  _readOnlyField('Stats',
                      '${pos.successCount}/${pos.reviewCount} (${(pos.successRate * 100).toStringAsFixed(0)}%)'),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _isValid ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    String? hint,
    String? errorText,
    bool monospace = false,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      onChanged: (_) => _onChanged(),
      maxLines: maxLines,
      style: monospace
          ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
          : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: errorText,
        errorMaxLines: 2,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
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
