/// Phases of a single repertoire line training session.
enum TrainingPhase {
  /// User is being shown moves for the first time.
  learning,

  /// User is being quizzed on moves.
  drilling,

  /// User replays wrong moves after line completes.
  replaying,

  /// Line complete, awaiting rating or next line.
  finished,
}

/// Pause after a wrong answer before the expected move plays on the board.
const Duration wrongMoveCorrectionDelay = Duration(milliseconds: 1200);

/// How long the corrected move stays on the board before the learn
/// walkthrough rewinds it and asks again.
const Duration learnCorrectionRewindDelay = Duration(milliseconds: 800);

/// Pause between one replayed miss and the next.
const Duration replayStepDelay = Duration(milliseconds: 500);
