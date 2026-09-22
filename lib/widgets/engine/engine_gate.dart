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

import 'package:provider/provider.dart';

import 'package:flutter/material.dart';

import '../../services/engine/engine_lifecycle.dart';
import '../../design_system/theme/app_typography.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../utils/app_messages.dart';

class EngineGate {
  EngineGate._();

  /// True while repertoire generation actively holds the engine. A paused
  /// build releases it, so this is false while paused.
  static bool isLocked(BuildContext context) =>
      context.read<EngineLifecycle>().state == EngineState.generating;

  /// Returns true when engine work may start. Otherwise shows the standard
  /// warning snackbar and returns false.
  static bool ensureAvailable(BuildContext context) {
    if (!isLocked(context)) return true;
    showAppSnackBar(
      context,
      AppLocalizations.of(context).engineNoticeLocked,
      duration: const Duration(seconds: 4),
      requiresAttention: true,
    );
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
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    if (dense) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.hourglass_top, size: 16, color: colors.tertiary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l10n.engineNoticeBusyCompact,
                style: AppTypography.secondary(context),
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
          color: colors.tertiaryContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.onTertiaryContainer, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hourglass_top,
              size: 32,
              color: colors.onTertiaryContainer,
            ),
            const SizedBox(height: 10),
            Text(
              l10n.engineNoticeBusyTitle,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.onTertiaryContainer,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.engineNoticeBusyBody,
              textAlign: TextAlign.center,
              style: AppTypography.secondary(
                context,
              ).copyWith(color: colors.onTertiaryContainer, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
