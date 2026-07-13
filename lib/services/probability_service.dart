/// Probability Service — Lichess Explorer move statistics for the engine
/// pane and audit checks.
///
/// MOTHBALLED: Explorer API calls are disabled ([_fetchInternal] returns
/// null immediately), so every lookup misses and callers fall back to
/// their non-Explorer paths.  The service is kept because the engine pane
/// still listens to [currentPosition] and the audit/generation config
/// still exposes Explorer options; restore the fetch body to re-enable.
///
/// Note: opponent move-probability *modeling* does NOT live here — the
/// generation pipeline owns it (see `generation/opponent_prior.dart`).
/// The legacy cumulative-probability model this service used to carry was
/// removed so there is exactly one formula in the app.
library;

import 'package:flutter/foundation.dart';

import '../models/explorer_response.dart';

// Re-export so existing `import 'probability_service.dart'` callers can
// still resolve these types without an extra import.
export '../models/explorer_response.dart' show ExplorerMove, ExplorerResponse;

class ProbabilityService {
  /// Application-wide shared instance.
  static final ProbabilityService instance = ProbabilityService._internal();

  /// Create an independent instance (unit tests only).
  @visibleForTesting
  ProbabilityService.fresh() : this._internal();

  ProbabilityService._internal();

  /// Explorer stats for the position currently shown in the engine pane.
  /// Only ever non-null when the Explorer fetch is re-enabled.
  final ValueNotifier<ExplorerResponse?> currentPosition = ValueNotifier(null);

  /// Fetch probabilities for an arbitrary FEN without mutating UI state.
  ///
  /// Intended for background analysis (audit checks, generation, etc.).
  Future<ExplorerResponse?> getProbabilitiesForFen(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '1800,2000,2200,2500',
    bool useMasters = false,
  }) {
    return _fetchInternal(
      fen,
      variant: variant,
      speeds: speeds,
      ratings: ratings,
      useMasters: useMasters,
    );
  }

  /// Internal fetch.  When re-enabling, delegate HTTP + JSON parsing to
  /// [LichessApiClient.fetchExplorer] so there is exactly one parser, and
  /// reintroduce a keyed cache (db|variant|speeds|ratings|fen).
  ///
  /// MOTHBALLED: Lichess Explorer API calls are disabled. Returns null
  /// immediately.
  Future<ExplorerResponse?> _fetchInternal(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '1800,2000,2200,2500',
    bool useMasters = false,
  }) async {
    // Mothballed: no Lichess Explorer API calls.
    return null;
  }
}
