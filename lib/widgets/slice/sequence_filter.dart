/// Shared move-sequence filter widget for PGN slice/search.
///
/// Finds games containing specific SAN moves in order, with configurable
/// gap tolerance between groups separated by `[gap]`.
library;

import 'package:flutter/material.dart';

import '../../services/pgn_parsing_service.dart' as pgn;

/// Stateful widget for the move sequence filter.
class SequenceFilter extends StatefulWidget {
  /// Called when the filter changes.
  final VoidCallback onChanged;

  /// Pre-populate from existing config.
  final String? initialPattern;
  final int initialGap;

  const SequenceFilter({
    super.key,
    required this.onChanged,
    this.initialPattern,
    this.initialGap = 4,
  });

  @override
  State<SequenceFilter> createState() => SequenceFilterState();
}

class SequenceFilterState extends State<SequenceFilter> {
  late final TextEditingController _sequenceController;
  late final TextEditingController _gapController;
  String? _error;

  /// Parsed sequence groups (or empty).
  List<List<String>> get groups {
    final text = _sequenceController.text.trim();
    if (text.isEmpty) return const [];
    return pgn.parseSequenceGroups(text);
  }

  /// Current max-gap setting.
  int get gap => int.tryParse(_gapController.text) ?? 4;

  /// Whether the filter has content.
  bool get hasFilter => _sequenceController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _sequenceController =
        TextEditingController(text: widget.initialPattern ?? '');
    _gapController = TextEditingController(text: widget.initialGap.toString());
  }

  @override
  void dispose() {
    _sequenceController.dispose();
    _gapController.dispose();
    super.dispose();
  }

  void _validate() {
    final text = _sequenceController.text.trim();
    if (text.isEmpty) {
      setState(() => _error = null);
      widget.onChanged();
      return;
    }
    final parsed = pgn.parseSequenceGroups(text);
    if (parsed.isEmpty) {
      setState(() => _error = 'No valid moves found');
      return;
    }
    for (final group in parsed) {
      for (final san in group) {
        if (!RegExp(r'^[a-hKQRBNO0-9x+#=]+$').hasMatch(san)) {
          setState(() => _error = "Invalid move token: '$san'");
          return;
        }
      }
    }
    setState(() => _error = null);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Move Sequence Filter',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.grey[300],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Find games containing specific moves in order. '
          'Use [gap] between groups that need not be consecutive.',
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _sequenceController,
          decoration: InputDecoration(
            hintText: 'e.g.  d5 e5 [gap] f6',
            hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: const OutlineInputBorder(),
            suffixIcon: _sequenceController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () {
                      _sequenceController.clear();
                      _validate();
                    },
                  )
                : null,
            suffixIconConstraints:
                const BoxConstraints(minWidth: 32, minHeight: 28),
          ),
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          onChanged: (_) => _validate(),
          onSubmitted: (_) => _validate(),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            if (_error != null)
              Expanded(
                child: Text(
                  _error!,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Spacer(),
            Text('Max gap: ',
                style: TextStyle(fontSize: 12, color: Colors.grey[400])),
            SizedBox(
              width: 40,
              child: TextField(
                controller: _gapController,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                keyboardType: TextInputType.number,
                onChanged: (_) {
                  if (_sequenceController.text.trim().isNotEmpty) {
                    widget.onChanged();
                  }
                },
              ),
            ),
            const SizedBox(width: 4),
            Text('ply',
                style: TextStyle(fontSize: 12, color: Colors.grey[400])),
          ],
        ),
      ],
    );
  }
}
