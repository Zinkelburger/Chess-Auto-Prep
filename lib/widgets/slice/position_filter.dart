/// Shared position filter widget for PGN slice/search.
///
/// Renders a text field accepting FEN or SAN moves, with Apply/Clear controls
/// and an optional "Board position" chip.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../utils/fen_utils.dart';

/// Result of attempting to parse a position input string.
class PositionParseResult {
  final String? fen;
  final String? error;
  const PositionParseResult.ok(this.fen) : error = null;
  const PositionParseResult.err(this.error) : fen = null;
  bool get isValid => fen != null;
}

/// Try to interpret [input] as either a FEN or a SAN move sequence.
PositionParseResult parsePositionInput(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return const PositionParseResult.ok(null);

  if (trimmed.contains('/')) {
    try {
      final fullFen = expandFen(trimmed);
      Chess.fromSetup(Setup.parseFen(fullFen));
      return PositionParseResult.ok(normalizeFen(fullFen));
    } catch (e) {
      return PositionParseResult.err('Invalid FEN: $e');
    }
  }

  return _parseSanSequence(trimmed);
}

PositionParseResult _parseSanSequence(String input) {
  final tokens = input
      .replaceAll(RegExp(r'\d+\.+'), '')
      .replaceAll(RegExp(r'(1-0|0-1|1/2-1/2|\*)'), '')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();

  if (tokens.isEmpty) {
    return const PositionParseResult.err('No moves found');
  }

  Position pos = Chess.initial;
  for (int i = 0; i < tokens.length; i++) {
    try {
      final move = pos.parseSan(tokens[i]);
      if (move == null) {
        return PositionParseResult.err(
            "Could not parse move ${i + 1}: '${tokens[i]}'");
      }
      pos = pos.play(move);
    } catch (e) {
      return PositionParseResult.err("Invalid move ${i + 1}: '${tokens[i]}'");
    }
  }
  return PositionParseResult.ok(normalizeFen(pos.fen));
}

/// Stateful position filter widget.
///
/// Call [PositionFilterState.parsedFen] to get the current valid FEN (or null).
class PositionFilter extends StatefulWidget {
  /// Current board FEN (for the "Board position" chip).
  final String? currentFen;

  /// Called when the filter changes (after Apply or Clear).
  final ValueChanged<String?> onChanged;

  /// Initial value to pre-populate.
  final String? initialValue;

  const PositionFilter({
    super.key,
    this.currentFen,
    required this.onChanged,
    this.initialValue,
  });

  @override
  State<PositionFilter> createState() => PositionFilterState();
}

class PositionFilterState extends State<PositionFilter> {
  late final TextEditingController _controller;
  PositionParseResult _parse = const PositionParseResult.ok(null);

  String? get parsedFen => _parse.fen;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
    if (widget.initialValue != null && widget.initialValue!.isNotEmpty) {
      _parse = parsePositionInput(widget.initialValue!);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void apply() {
    setState(() {
      _parse = parsePositionInput(_controller.text);
    });
    widget.onChanged(_parse.fen);
  }

  void clear() {
    _controller.clear();
    setState(() {
      _parse = const PositionParseResult.ok(null);
    });
    widget.onChanged(null);
  }

  bool get hasFilter => _parse.isValid && _parse.fen != null;

  @override
  Widget build(BuildContext context) {
    final showError = _parse.error != null;
    final showOk = _parse.isValid && _parse.fen != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Position Filter',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.grey[300],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: InputDecoration(
                  hintText: 'FEN or moves, e.g. 1. e4 c6',
                  hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: const OutlineInputBorder(),
                  suffixIcon: showOk || showError
                      ? Icon(
                          showOk ? Icons.check_circle : Icons.error_outline,
                          size: 18,
                          color: showOk ? Colors.green : Colors.red,
                        )
                      : null,
                  suffixIconConstraints:
                      const BoxConstraints(minWidth: 32, minHeight: 28),
                ),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                onSubmitted: (_) => apply(),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              height: 36,
              child: OutlinedButton(
                onPressed: apply,
                child: const Text('Apply', style: TextStyle(fontSize: 12)),
              ),
            ),
            if (hasFilter || _controller.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: clear,
                  tooltip: 'Clear position filter',
                ),
              ),
          ],
        ),
        if (showError)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _parse.error!,
              style: const TextStyle(fontSize: 11, color: Colors.red),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (widget.currentFen != null) ...[
          const SizedBox(height: 4),
          _BoardPositionChip(
            currentFen: widget.currentFen!,
            isActive: hasFilter,
            onTap: () {
              if (hasFilter) {
                clear();
              } else {
                _controller.text = widget.currentFen!;
                apply();
              }
            },
          ),
        ],
      ],
    );
  }
}

class _BoardPositionChip extends StatelessWidget {
  final String currentFen;
  final bool isActive;
  final VoidCallback onTap;

  const _BoardPositionChip({
    required this.currentFen,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
    final normalizedCurrent = normalizeFen(currentFen);
    final isStart = normalizedCurrent == startFen;

    return Tooltip(
      message: isStart
          ? 'Navigate to a position on the board first'
          : isActive
              ? 'Remove board position filter'
              : 'Use the current board position',
      child: GestureDetector(
        onTap: isStart ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isStart
                ? Colors.grey[800]
                : isActive
                    ? Colors.blue[700]
                    : Colors.grey[800],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? Colors.blue[400]! : Colors.grey[700]!,
              width: isActive ? 1.5 : 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.grid_on,
                size: 12,
                color: isStart
                    ? Colors.grey[600]
                    : isActive
                        ? Colors.blue[100]
                        : Colors.grey[400],
              ),
              const SizedBox(width: 4),
              Text(
                'Board position',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                  color: isStart
                      ? Colors.grey[600]
                      : isActive
                          ? Colors.blue[100]
                          : Colors.grey[400],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
