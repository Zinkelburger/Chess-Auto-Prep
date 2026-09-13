/// Shared position filter widget for PGN slice/search.
///
/// Renders a text field accepting FEN or SAN moves, with Apply/Clear controls
/// and an optional "Board position" chip. All state lives on the
/// [SliceFilterController] passed in by the host.
library;

import 'package:flutter/material.dart';

import '../../core/slice_filter_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/fen_utils.dart';
import '../position_preview_icon.dart';

class PositionFilter extends StatelessWidget {
  final SliceFilterController controller;

  /// Current board FEN (for the "Board position" chip).
  final String? currentFen;
  final bool showTitle;
  final TextEditingController? input;

  const PositionFilter({
    super.key,
    required this.controller,
    this.currentFen,
    this.showTitle = true,
    this.input,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        input ?? controller.positionText,
      ]),
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final text = input ?? controller.positionText;
    final parse = input == null
        ? controller.positionParse
        : parsePositionInput(text.text);
    final showError = parse.error != null;
    final hasFilter = parse.isValid && parse.fen != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTitle)
          Text(
            'Board position',
            style: AppTextStyles.forTheme(
              context,
              AppTextStyles.subtitle,
            ).copyWith(fontWeight: FontWeight.w600),
          ),
        if (showTitle) const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: PositionHoverPreview(
                inputGetter: () => parse.isValid ? text.text : '',
                child: TextField(
                  controller: text,
                  decoration: InputDecoration(
                    hintText: 'FEN or moves',
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    enabledBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: AppColors.divider),
                    ),
                    hintStyle: AppTextStyles.forTheme(
                      context,
                      AppTextStyles.hint,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 14,
                    ),
                    border: const OutlineInputBorder(),
                    suffixIcon: showError
                        ? const Icon(
                            Icons.error_outline,
                            size: 18,
                            color: AppColors.danger,
                          )
                        : null,
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 28,
                    ),
                  ),
                  style: const TextStyle(
                    fontSize: 14,
                    fontFamily: AppTextStyles.monoFamily,
                  ),
                ),
              ),
            ),
            if (hasFilter || text.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  onPressed: text.clear,
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
              style: const TextStyle(fontSize: 12, color: AppColors.danger),
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
                hasFilter &&
                controller.positionFen == normalizeFen(currentFen!),
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
      child: OutlinedButton.icon(
        onPressed: isStart ? null : onTap,
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.standard,
          minimumSize: const Size(0, 44),
          foregroundColor: isActive ? AppColors.chipActiveFg : null,
          backgroundColor: isActive ? AppColors.chipActiveBg : null,
        ),
        icon: const Icon(Icons.grid_on, size: 18),
        label: Text(isActive ? 'Using board position' : 'Use board position'),
      ),
    );
  }
}
