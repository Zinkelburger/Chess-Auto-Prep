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
