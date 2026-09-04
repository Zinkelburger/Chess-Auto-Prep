/// How a played game ended: the score, and the reason behind it.
///
/// Shared rather than owned by the engine tournament, because two features now
/// play games and tabulate them — `features/engine_tournament/` (Stockfish and
/// friends on one board) and `features/bughouse/` (Hivemind on two). The
/// vocabulary is the same in both, and a second copy of it would mean two
/// spellings of "checkmate" that a crosstable could not add up.
///
/// [GameResult] is written from White's side. In bughouse that means the team
/// holding White on board A, which is also how BPGN reads a `1-0` — see
/// `tools/bughouse_db/bpgn.py`.
library;

enum GameResult { whiteWins, blackWins, draw, unfinished }

extension GameResultPgn on GameResult {
  String get pgnToken => switch (this) {
    GameResult.whiteWins => '1-0',
    GameResult.blackWins => '0-1',
    GameResult.draw => '1/2-1/2',
    GameResult.unfinished => '*',
  };

  /// Points for White. Black's score is `1 - this` for a finished game.
  double get whitePoints => switch (this) {
    GameResult.whiteWins => 1,
    GameResult.blackWins => 0,
    GameResult.draw => 0.5,
    GameResult.unfinished => 0.5,
  };
}

/// Why the game stopped. Kept apart from [GameResult] so "0-1" can say
/// whether White was mated, flagged, or crashed.
///
/// Not every reason can happen in every game: bughouse has no fifty-move rule
/// and no insufficient material (a reserve refills), and only bughouse ends by
/// both teams sitting. An enum of endings is allowed to hold endings this
/// particular game could not have reached.
enum TerminationReason {
  checkmate,
  stalemate,
  insufficientMaterial,
  fiftyMoveRule,
  threefoldRepetition,
  drawAdjudication,
  resignAdjudication,
  maxMoves,
  timeForfeit,
  illegalMove,
  engineFailure,
  aborted,

  /// Both teams chose to sit, repeatedly. Bughouse only: passing is a legal
  /// move there, so a game can stop moving without either board being over.
  mutualSitting,
}

extension TerminationReasonLabel on TerminationReason {
  String get label => switch (this) {
    TerminationReason.checkmate => 'Checkmate',
    TerminationReason.stalemate => 'Stalemate',
    TerminationReason.insufficientMaterial => 'Insufficient material',
    TerminationReason.fiftyMoveRule => 'Fifty-move rule',
    TerminationReason.threefoldRepetition => 'Threefold repetition',
    TerminationReason.drawAdjudication => 'Adjudicated draw',
    TerminationReason.resignAdjudication => 'Adjudicated win',
    TerminationReason.maxMoves => 'Move limit',
    TerminationReason.timeForfeit => 'Time forfeit',
    TerminationReason.illegalMove => 'Illegal move',
    TerminationReason.engineFailure => 'Engine failure',
    TerminationReason.aborted => 'Aborted',
    TerminationReason.mutualSitting => 'Both teams sat',
  };

  /// Value for the PGN `Termination` tag (standard §9.8 vocabulary where one
  /// fits, the reason's own name where none does).
  String get pgnTag => switch (this) {
    TerminationReason.checkmate ||
    TerminationReason.stalemate ||
    TerminationReason.insufficientMaterial ||
    TerminationReason.fiftyMoveRule ||
    TerminationReason.threefoldRepetition => 'normal',
    TerminationReason.drawAdjudication ||
    TerminationReason.resignAdjudication ||
    TerminationReason.maxMoves ||
    TerminationReason.mutualSitting => 'adjudication',
    TerminationReason.timeForfeit => 'time forfeit',
    TerminationReason.illegalMove => 'rules infraction',
    TerminationReason.engineFailure => 'abandoned',
    TerminationReason.aborted => 'unterminated',
  };

  bool get isNaturalEnd => switch (this) {
    TerminationReason.checkmate ||
    TerminationReason.stalemate ||
    TerminationReason.insufficientMaterial ||
    TerminationReason.fiftyMoveRule ||
    TerminationReason.threefoldRepetition => true,
    _ => false,
  };
}
