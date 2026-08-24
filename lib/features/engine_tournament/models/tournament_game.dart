/// The record of one played game: who, how it ended, and where to find it.
///
/// The movetext itself is not stored here — every game is appended to the
/// tournament's `games.pgn`, which is the file the PGN Viewer opens. This
/// record carries [gameIndex] into that file so a row in the games table can
/// hand the viewer a game number.
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
    TerminationReason.maxMoves => 'adjudication',
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

class TournamentGameRecord {
  const TournamentGameRecord({
    required this.gameIndex,
    required this.round,
    required this.whiteIndex,
    required this.blackIndex,
    required this.whiteName,
    required this.blackName,
    required this.result,
    required this.termination,
    required this.plies,
    required this.startedAt,
    required this.durationMs,
    this.detail = '',
  });

  /// Position in the tournament's `games.pgn`, 0-based.
  final int gameIndex;

  final int round;

  /// Indices into [TournamentConfig.engines] — the identity the crosstable
  /// scores by, since two participants can share a display name.
  final int whiteIndex;
  final int blackIndex;

  final String whiteName;
  final String blackName;

  final GameResult result;
  final TerminationReason termination;

  /// Free text for the cases where the reason alone is not enough
  /// ("Stockfish played e2e5", "process exited (11)").
  final String detail;

  final int plies;
  final DateTime startedAt;
  final int durationMs;

  /// Game number as shown in the UI and in the viewer's counter (1-based).
  int get gameNumber => gameIndex + 1;

  /// One-line summary of how it ended, from White's point of view.
  String get outcomeLabel {
    if (detail.isNotEmpty) return '${termination.label} — $detail';
    return termination.label;
  }

  Map<String, dynamic> toJson() => {
    'gameIndex': gameIndex,
    'round': round,
    'whiteIndex': whiteIndex,
    'blackIndex': blackIndex,
    'whiteName': whiteName,
    'blackName': blackName,
    'result': result.name,
    'termination': termination.name,
    'detail': detail,
    'plies': plies,
    'startedAt': startedAt.toIso8601String(),
    'durationMs': durationMs,
  };

  factory TournamentGameRecord.fromJson(Map<String, dynamic> json) =>
      TournamentGameRecord(
        gameIndex: (json['gameIndex'] as num?)?.toInt() ?? 0,
        round: (json['round'] as num?)?.toInt() ?? 1,
        whiteIndex: (json['whiteIndex'] as num?)?.toInt() ?? 0,
        blackIndex: (json['blackIndex'] as num?)?.toInt() ?? 1,
        whiteName: json['whiteName'] as String? ?? 'White',
        blackName: json['blackName'] as String? ?? 'Black',
        result: GameResult.values.firstWhere(
          (r) => r.name == json['result'],
          orElse: () => GameResult.unfinished,
        ),
        termination: TerminationReason.values.firstWhere(
          (t) => t.name == json['termination'],
          orElse: () => TerminationReason.aborted,
        ),
        detail: json['detail'] as String? ?? '',
        plies: (json['plies'] as num?)?.toInt() ?? 0,
        startedAt:
            DateTime.tryParse(json['startedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      );
}
