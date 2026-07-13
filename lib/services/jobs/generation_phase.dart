/// High-level pipeline phase for a repertoire generation job.
///
/// The pipeline reports its phase explicitly through this enum — phases are
/// never inferred from human-readable status strings, so progress displays
/// cannot drift out of sync with the actual work being done.
library;

enum GenerationPhase {
  parsingPgn,
  buildingTree,
  enrichingEvals,
  computingEase,
  computingExpectimax,
  selectingRepertoire,
  verifying,
  extractingLines,
  idle,
}

extension GenerationPhaseFlags on GenerationPhase {
  /// Whether the pipeline honors pause requests during this phase.
  /// The remaining phases are synchronous tree walks that finish quickly.
  bool get isPausable => switch (this) {
        GenerationPhase.buildingTree ||
        GenerationPhase.enrichingEvals ||
        GenerationPhase.verifying =>
          true,
        _ => false,
      };
}
