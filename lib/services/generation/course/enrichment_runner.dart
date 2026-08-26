/// Shared plumbing for the best-effort passes that decorate extracted lines
/// after the build: refutations, engine tails, alternatives, and improvements
/// on master practice.
///
/// Each of those passes is the same six steps — check the config switch, build
/// a prober, stop when it has nothing to work on, make sure the engine pool is
/// warm, probe while reporting progress, record how much it produced. Only two
/// of the six differ between passes, so the rest lives here once instead of
/// four near-identical copies in [GenerationSessionController].
library;

import 'package:flutter/foundation.dart';

import '../generation_config.dart';

/// One post-build pass over the extracted lines.
///
/// The label is what a failure is logged under, so it reads the way the old
/// hand-written messages did (`Refutation pass failed: ...`).
enum EnrichmentPass {
  refutations('Refutation'),
  engineTails('Engine tail'),
  alternatives('Alternatives'),
  improvements('Improvements');

  const EnrichmentPass(this.label);

  /// Human-readable name used in progress and failure messages.
  final String label;
}

/// Runs one pass's probe, reporting `(done, total)` as it goes and stopping
/// when `isCancelled` turns true.
///
/// Returns findings keyed by whatever that pass keys on — usually the FEN of
/// the position the finding attaches to.
typedef EnrichmentProbe<T> =
    Future<Map<String, T>> Function({
      required bool Function() isCancelled,
      required void Function(int done, int total) onProgress,
    });

/// Executes [EnrichmentPass]es, and remembers how much each one produced.
///
/// **Every pass is best-effort.** No engine, a cancelled run, or a failed
/// search costs that pass its own output and nothing else — the export always
/// goes ahead. That is the whole reason [run] catches rather than rethrows,
/// and why a switched-off, work-free, cancelled, and failed pass are all
/// indistinguishable to the caller: an empty map.
///
/// The counts live here rather than in four fields on the controller. They
/// used to be written as a side effect of each phase and read ~150 lines later
/// by the run-summary builder, which meant a pass could be added without its
/// count ever being wired up. Now recording the count is part of running the
/// pass, and [countOf] is the only way to read one.
///
/// State the owner reassigns arrives by callback rather than as a cached
/// reference: the controller swaps `activeConfig` between runs, so a snapshot
/// taken at construction would go stale (CLAUDE.md's supplier-callback rule).
class EnrichmentRunner {
  EnrichmentRunner({
    required this._config,
    required this._isCancelled,
    required this._onStatus,
    required this._ensureEngine,
  });

  final TreeBuildConfig? Function() _config;
  final bool Function() _isCancelled;
  final void Function(String message) _onStatus;
  final Future<void> Function() _ensureEngine;

  final Map<EnrichmentPass, int> _counts = {};

  /// How many findings [pass] produced on the current run.
  ///
  /// Zero when it was switched off, had nothing to work on, was cancelled, or
  /// failed — the run summary treats all four the same way.
  int countOf(EnrichmentPass pass) => _counts[pass] ?? 0;

  /// Whether any pass produced anything, so a caller can skip a summary
  /// clause without naming each pass.
  bool get anyFindings => _counts.values.any((c) => c > 0);

  /// Forget every count. Call as a run starts.
  void reset() => _counts.clear();

  /// Run [pass], returning its findings — or an empty map for any of the four
  /// reasons above.
  ///
  /// [enabled] is the pass's own config switch; the engine requirement and the
  /// cancellation check are applied here for every pass. [prepare] builds the
  /// prober and returns null when there is nothing to probe, so a pass that is
  /// off never pays for constructing one. [status] renders the progress line.
  Future<Map<String, T>> run<T>(
    EnrichmentPass pass, {
    required bool enabled,
    required String Function(int done, int total) status,
    required EnrichmentProbe<T>? Function() prepare,
  }) async {
    _counts[pass] = 0;
    final config = _config();
    if (!enabled ||
        config == null ||
        !config.needsStockfish ||
        _isCancelled()) {
      return const {};
    }

    final probe = prepare();
    if (probe == null) return const {};

    try {
      await _ensureEngine();
      final findings = await probe(
        isCancelled: _isCancelled,
        onProgress: (done, total) => _onStatus(status(done, total)),
      );
      _counts[pass] = findings.length;
      return findings;
    } catch (e) {
      debugPrint('${pass.label} pass failed: $e');
      return const {};
    }
  }
}
