/// App-wide gate for user-initiated Stockfish work during repertoire
/// generation.
///
/// Generation owns every engine worker while it actively runs, so any other
/// engine use would contend with the build. Pausing the build hands the
/// engine back ([EngineLifecycle.pauseGeneration]), which unlocks this gate.
/// Every surface that can start engine work goes through it:
/// - active triggers (buttons, toggles) call [EngineGate.ensureAvailable],
///   which refuses with the standard warning snackbar;
/// - passive panes (auto-analysis views) check [EngineGate.isLocked] and
///   render an [EngineBusyNotice] instead of analyzing.
library;

import 'package:flutter/material.dart';

import '../../services/engine/engine_lifecycle.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_messages.dart';

class EngineGate {
  EngineGate._();

  /// True while repertoire generation actively holds the engine. A paused
  /// build releases it, so this is false while paused.
  static bool get isLocked =>
      EngineLifecycle.instance.state == EngineState.generating;

  /// Notifies when [isLocked] may have changed.
  static Listenable get listenable => EngineLifecycle.instance;

  static const lockedMessage =
      'Stockfish is busy building your repertoire. Pause the build or wait '
      'for it to finish before using engine analysis.';

  /// Returns true when engine work may start. Otherwise shows the standard
  /// warning snackbar and returns false.
  static bool ensureAvailable(BuildContext context) {
    if (!isLocked) return true;
    showAppSnackBar(context, lockedMessage,
        duration: const Duration(seconds: 4));
    return false;
  }
}

/// Inline placeholder shown by engine panes while [EngineGate.isLocked].
///
/// [dense] renders a single-height row for compact bars; the default is a
/// centered card for full panes.
class EngineBusyNotice extends StatelessWidget {
  const EngineBusyNotice({super.key, this.dense = false});

  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (dense) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.hourglass_top, size: 16, color: AppColors.warning),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Engine busy — building your repertoire.',
                style: TextStyle(fontSize: 12.5, color: Colors.grey[400]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        constraints: const BoxConstraints(maxWidth: 340),
        decoration: BoxDecoration(
          color: AppColors.warningSurface.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.warning, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hourglass_top, size: 32, color: AppColors.warning),
            const SizedBox(height: 10),
            Text(
              'Engine Busy',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Stockfish is building your repertoire.\n'
              'Pause the build or let it finish to analyze again.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey[400], height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
