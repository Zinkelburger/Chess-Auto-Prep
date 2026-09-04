/// The record of one played game: who, how it ended, and where to find it.
///
/// The movetext itself is not stored here — every game is appended to the
/// tournament's `games.pgn`, which is the file the PGN Viewer opens. This
/// record carries [gameIndex] into that file so a row in the games table can
/// hand the viewer a game number.
library;

import '../../../models/crosstable.dart';
import '../../../models/game_outcome.dart';

class TournamentGameRecord implements CrosstableGame {
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
  @override
  final int whiteIndex;
  @override
  final int blackIndex;

  final String whiteName;
  final String blackName;

  @override
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
