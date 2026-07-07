/// Shared position filter widget for PGN slice/search.
///
/// Renders a text field accepting FEN or SAN moves, with Apply/Clear controls
/// and an optional "Board position" chip. All state lives on the
/// [SliceFilterController] passed in by the host.
library;

import 'package:flutter/material.dart';

import '../../core/slice_filter_controller.dart';
import '../../utils/fen_utils.dart';
import '../position_preview_icon.dart';

class PositionFilter extends StatelessWidget {
  final SliceFilterController controller;

  /// Current board FEN (for the "Board position" chip).
  final String? currentFen;

  const PositionFilter({
    super.key,
    required this.controller,
    this.currentFen,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.positionText]),
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final parse = controller.positionParse;
    final text = controller.positionText;
    final showError = parse.error != null;
    final showOk = parse.isValid && parse.fen != null;
    final hasFilter = controller.hasPositionFilter;

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
                controller: text,
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
              ),
            ),
            if (text.text.isNotEmpty)
              PositionPreviewIcon(inputGetter: () => text.text),
            if (hasFilter || text.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: controller.clearPosition,
                  tooltip: 'Clear position filter',
                ),
              ),
          ],
        ),
        if (showError)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              parse.error!,
              style: const TextStyle(fontSize: 11, color: Colors.red),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (currentFen != null) ...[
          const SizedBox(height: 4),
          // Always captures the current board position (never a toggle — a
          // toggle silently *cleared* a stale filter when the user meant to
          // re-capture, which produced wrong slices/exports).
          _BoardPositionChip(
            currentFen: currentFen!,
            isActive:
                hasFilter && controller.positionFen == normalizeFen(currentFen!),
            onTap: () => controller.setPositionFen(currentFen!),
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
              ? 'Filtering on the current board position'
              : 'Filter games through the current board position',
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
                'Use board position',
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
