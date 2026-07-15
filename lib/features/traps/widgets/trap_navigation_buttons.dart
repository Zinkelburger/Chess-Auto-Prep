import 'package:flutter/material.dart';

import '../../../widgets/shortcut_tooltip.dart';

import '../../../core/repertoire_controller.dart';
import '../../../models/repertoire_line.dart';
import '../../../theme/app_colors.dart';
import '../models/trap_line_info.dart';
import '../services/trap_index_service.dart';

/// Prev/next trap controls for the repertoire board toolbar.
///
/// Uses [TrapIndexService.trapsInLine] against the active line path
/// ([RepertoireController.moveHistory] when loaded, otherwise
/// [RepertoireController.currentMoveSequence]).
class TrapNavigationButtons extends StatelessWidget {
  const TrapNavigationButtons({
    super.key,
    required this.trapIndex,
    required this.controller,
    this.onStartTour,
    this.tourActive = false,
  });

  final TrapIndexService trapIndex;
  final RepertoireController controller;

  /// Shows a "Tour" pill that starts the trap tour when set.
  final VoidCallback? onStartTour;

  /// Highlights the pill while the tour bar is open.
  final bool tourActive;

  /// Move path used to resolve traps in the current line.
  ///
  /// Prefer the longest repertoire line that contains the current position so
  /// next/prev can reach traps beyond the current ply.
  static List<String> lineMovesForTraps(RepertoireController controller) {
    final selected = controller.selectedPgnLine;
    if (selected != null && selected.moves.isNotEmpty) {
      return selected.moves;
    }

    final path = controller.moveHistory.isNotEmpty
        ? controller.moveHistory
        : controller.currentMoveSequence;
    if (path.isEmpty) return path;

    RepertoireLine? bestMatch;
    for (final line in controller.repertoireLines) {
      if (line.moves.length >= path.length && _isPrefix(path, line.moves)) {
        if (bestMatch == null || line.moves.length > bestMatch.moves.length) {
          bestMatch = line;
        }
      }
    }
    return bestMatch?.moves ?? path;
  }

  static bool _isPrefix(List<String> prefix, List<String> line) {
    if (prefix.length > line.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i] != line[i]) return false;
    }
    return true;
  }

  /// Index of the trap at or before [currentPly], or -1 if before the first trap.
  static int findCurrentTrapIndex(List<TrapLineInfo> traps, int currentPly) {
    if (traps.isEmpty) return -1;

    var idx = -1;
    for (var i = 0; i < traps.length; i++) {
      final trapPly = traps[i].movesSan.length - 1;
      if (trapPly <= currentPly) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  static List<TrapLineInfo> trapsInCurrentLine(
    TrapIndexService trapIndex,
    RepertoireController controller,
  ) {
    return trapIndex.trapsInLine(lineMovesForTraps(controller));
  }

  static void jumpToTrap(RepertoireController controller, TrapLineInfo trap) {
    final lineMoves = lineMovesForTraps(controller);
    if (lineMoves.length >= trap.movesSan.length &&
        _isPrefix(trap.movesSan, lineMoves)) {
      if (!_isPrefix(lineMoves, controller.moveHistory) ||
          controller.moveHistory.length != lineMoves.length) {
        controller.loadMoveHistory(lineMoves);
      }
      controller.jumpToMoveIndex(trap.movesSan.length - 1);
      return;
    }
    controller.loadMoveSequence(trap.movesSan);
  }

  static bool goToPreviousTrap({
    required TrapIndexService? trapIndex,
    required RepertoireController controller,
  }) {
    if (trapIndex == null) return false;

    final traps = trapsInCurrentLine(trapIndex, controller);
    if (traps.isEmpty) return false;

    final currentTrapIdx = findCurrentTrapIndex(
      traps,
      controller.currentMoveIndex,
    );
    if (currentTrapIdx <= 0) return false;

    jumpToTrap(controller, traps[currentTrapIdx - 1]);
    return true;
  }

  static bool goToNextTrap({
    required TrapIndexService? trapIndex,
    required RepertoireController controller,
  }) {
    if (trapIndex == null) return false;

    final traps = trapsInCurrentLine(trapIndex, controller);
    if (traps.isEmpty) return false;

    final currentTrapIdx = findCurrentTrapIndex(
      traps,
      controller.currentMoveIndex,
    );
    final nextIdx = currentTrapIdx + 1;
    if (nextIdx >= traps.length) return false;

    jumpToTrap(controller, traps[nextIdx]);
    return true;
  }

  Widget _buildTourButton() {
    if (onStartTour == null) return const SizedBox.shrink();
    return ShortcutTooltip(
      description: tourActive
          ? 'Trap tour is open'
          : 'Tour every trap on the board',
      shortcut: 'T',
      child: FilledButton.icon(
        onPressed: onStartTour,
        icon: const Icon(Icons.tour, size: 16),
        label: const Text('Tour'),
        style: FilledButton.styleFrom(
          foregroundColor: tourActive ? Colors.black : AppColors.warning,
          backgroundColor: tourActive
              ? AppColors.warning
              : AppColors.warning.withValues(alpha: 0.15),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final traps = trapsInCurrentLine(trapIndex, controller);
        final currentTrapIdx = findCurrentTrapIndex(
          traps,
          controller.currentMoveIndex,
        );

        if (traps.isEmpty) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '0 traps in line',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ),
              _buildTourButton(),
            ],
          );
        }

        final displayIdx = currentTrapIdx >= 0 ? currentTrapIdx + 1 : 0;
        final canGoPrev = currentTrapIdx > 0;
        final canGoNext = currentTrapIdx < traps.length - 1;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTourButton(),
            const SizedBox(width: 4),
            ShortcutIconButton(
              description: 'Previous trap',
              shortcut: 'Shift+←',
              icon: const Icon(Icons.skip_previous, size: 20),
              color: AppColors.warning,
              onPressed: canGoPrev
                  ? () => jumpToTrap(controller, traps[currentTrapIdx - 1])
                  : null,
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$displayIdx/${traps.length}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            ShortcutIconButton(
              description: 'Next trap',
              shortcut: 'Shift+→',
              icon: const Icon(Icons.skip_next, size: 20),
              color: AppColors.warning,
              onPressed: canGoNext
                  ? () => jumpToTrap(controller, traps[currentTrapIdx + 1])
                  : null,
            ),
          ],
        );
      },
    );
  }
}
