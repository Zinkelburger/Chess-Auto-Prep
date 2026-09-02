/// Data model for a single repertoire audit finding.
library;

import '../../../utils/movetext_builder.dart';

enum AuditFindingType {
  mistake,
  inaccuracy,
  missingResponse,
  weakPosition,
  deadEnd,

  // Hole-hunt (adversarial) finding types — emitted by HoleHuntService,
  // never by the defensive audit.
  uncoveredStrongMove,
  refutation,
  practicalTrap,

  // Trick-hunt finding type — emitted by TrickHuntService: a near-best (or
  // novelty) move that scores better in practice than the engine-best move.
  trickyMove,
}

enum AuditSeverity { critical, warning, info }

/// Source that detected a missing opponent response.
///
/// [chessDb] and [engine] are the odd ones out: the other three say the
/// move is *played*, these say it is *good* — a reply ChessDB or Stockfish's
/// MultiPV scores close to the opponent's best, whether or not anyone plays
/// it.
enum MissingResponseSource { lichess, maia, clash, chessDb, engine }

class AuditFinding {
  final AuditFindingType type;
  final AuditSeverity severity;

  /// SAN move path from root to the position where the finding occurs.
  final List<String> movePath;

  /// FEN of the position where the finding occurs.
  final String fen;

  /// For Mistake/Inaccuracy: the move we play that is suboptimal.
  final String? ourMove;

  /// For Mistake/Inaccuracy: the best move according to Stockfish.
  final String? bestMove;

  /// For Mistake/Inaccuracy: centipawn loss (positive = we lose eval).
  final int? evalLossCp;

  /// For Mistake/Inaccuracy/WeakPosition: absolute eval of our chosen position
  /// (white-normalized cp).
  final int? positionEvalCp;

  /// For Mistake/Inaccuracy: eval of the best alternative (white-normalized cp).
  final int? bestMoveEvalCp;

  /// For MissingResponse: the opponent move not covered.
  final String? missingMove;

  /// For MissingResponse: game count from Lichess Explorer.
  final int? gameCount;

  /// For MissingResponse: probability from Maia or play rate from Lichess.
  /// Null for a ChessDB or engine finding, which rank the move by score,
  /// not by use.
  final double? probability;

  /// For MissingResponse: which source flagged the gap.
  final MissingResponseSource? source;

  /// For DeadEnd: how many opponent continuations exist beyond the leaf.
  /// For a ChessDB MissingResponse: how many opponent moves score inside
  /// the reply window at this position, the flagged one included.
  final int? continuationCount;

  /// For DeadEnd: the specific opponent moves not covered (SAN).
  final List<String>? uncoveredMoves;

  /// Probability of reaching this position from the repertoire root (0..1).
  /// Product of opponent move frequencies along the path.
  final double? cumulativeProbability;

  /// True when the missing move transposes into a position already covered
  /// elsewhere in the repertoire (the resulting FEN exists in the tree).
  final bool transposesIntoRepertoire;

  /// For Refutation/PracticalTrap: the concrete line to play (SAN).
  final List<String>? exploitLine;

  /// For PracticalTrap: expectimax practical eval (attacker perspective, cp).
  final int? expectedEvalCp;

  /// For PracticalTrap: expectedEvalCp minus raw engine eval (cp) — how much
  /// harder the position plays than it "should".
  final int? practicalGapCp;

  /// For TrickyMove: probe practical eval minus the engine-best move's raw
  /// eval (cp, trickster perspective) — what playing the trick gains in
  /// expectation over just playing the best move.
  final int? netGainCp;

  /// For PracticalTrap/TrickyMove: the opponent's ease in the probed
  /// position (0..1, app-wide ease formula). Low = many plausible ways to
  /// go wrong.
  final double? oppEase;

  /// For TrickyMove: true when the candidate move is not in the source tree.
  final bool? isNovelty;

  /// Hole-hunt ranking score: cumulative reach probability × gain (cp).
  final double? exploitScore;

  /// Whether the user has dismissed this finding.
  bool dismissed;

  AuditFinding({
    required this.type,
    required this.severity,
    required this.movePath,
    required this.fen,
    this.ourMove,
    this.bestMove,
    this.evalLossCp,
    this.positionEvalCp,
    this.bestMoveEvalCp,
    this.missingMove,
    this.gameCount,
    this.probability,
    this.source,
    this.continuationCount,
    this.uncoveredMoves,
    this.cumulativeProbability,
    this.transposesIntoRepertoire = false,
    this.exploitLine,
    this.expectedEvalCp,
    this.practicalGapCp,
    this.netGainCp,
    this.oppEase,
    this.isNovelty,
    this.exploitScore,
    this.dismissed = false,
  });

  /// Stable key for dismissal persistence.
  String get dismissKey => '${type.name}|$fen|${ourMove ?? missingMove ?? ""}';

  String get movePathString {
    if (movePath.isEmpty) return '(root)';
    return buildNumberedMovetext(movePath, compact: true);
  }

  /// Cumulative probability formatted as a percentage string, or null.
  String? get reachProbLabel {
    if (cumulativeProbability == null) return null;
    final pct = cumulativeProbability! * 100;
    if (pct >= 10) return '${pct.toStringAsFixed(0)}%';
    if (pct >= 1) return '${pct.toStringAsFixed(1)}%';
    if (pct >= 0.1) return '${pct.toStringAsFixed(2)}%';
    return '${pct.toStringAsFixed(3)}%';
  }

  /// Format a SAN with its move number, e.g. "3. Nf3" or "3...Nd2".
  String _sanWithMoveNumber(String san, int plyIndex) =>
      formatMoveAtPly(plyIndex, san);

  String get summary {
    switch (type) {
      case AuditFindingType.mistake:
        final move = ourMove ?? '?';
        final numbered = movePath.isNotEmpty
            ? _sanWithMoveNumber(move, movePath.length - 1)
            : move;
        return 'Mistake: $numbered loses ${evalLossCp}cp '
            '(best: ${bestMove ?? "?"})';
      case AuditFindingType.inaccuracy:
        final move = ourMove ?? '?';
        final numbered = movePath.isNotEmpty
            ? _sanWithMoveNumber(move, movePath.length - 1)
            : move;
        return 'Inaccuracy: $numbered loses ${evalLossCp}cp '
            '(best: ${bestMove ?? "?"})';
      case AuditFindingType.missingResponse:
        final move = missingMove ?? '?';
        final numbered = _sanWithMoveNumber(move, movePath.length);
        final probLabel = _missingMoveLocalProbLabel;
        final transTag = transposesIntoRepertoire ? ' · transposes' : '';
        final prefix = switch (source) {
          MissingResponseSource.clash => 'Clash',
          MissingResponseSource.chessDb ||
          MissingResponseSource.engine => 'Strong reply',
          _ => 'Missing',
        };
        return '$prefix: $numbered ($probLabel$transTag)';
      case AuditFindingType.weakPosition:
        return 'Weak position: eval ${positionEvalCp}cp';
      case AuditFindingType.deadEnd:
        final count = continuationCount ?? 0;
        final moves = uncoveredMoves;
        if (moves != null && moves.isNotEmpty) {
          return 'Dead end: $count uncovered (${moves.join(", ")})';
        }
        return 'Dead end: $count opponent continuations uncovered';
      case AuditFindingType.uncoveredStrongMove:
        final move = missingMove ?? '?';
        final numbered = _sanWithMoveNumber(move, movePath.length);
        final transTag = transposesIntoRepertoire ? ' · transposes' : '';
        return 'Uncovered: $numbered is engine-strong, no reply in file'
            '$transTag';
      case AuditFindingType.refutation:
        final move = ourMove ?? '?';
        final numbered = movePath.isNotEmpty
            ? _sanWithMoveNumber(move, movePath.length - 1)
            : move;
        final line = exploitLine;
        final lineTag = line != null && line.isNotEmpty
            ? ' — ${line.join(" ")}'
            : '';
        return 'Refuted: $numbered loses ${evalLossCp}cp$lineTag';
      case AuditFindingType.practicalTrap:
        final line = exploitLine;
        final lineTag = line != null && line.isNotEmpty
            ? ' (${line.take(6).join(" ")})'
            : '';
        return 'Trap zone: practically +${practicalGapCp}cp over the raw eval'
            '$lineTag';
      case AuditFindingType.trickyMove:
        final move = ourMove ?? '?';
        final numbered = _sanWithMoveNumber(move, movePath.length);
        final noveltyTag = isNovelty == true ? ' · novelty' : '';
        return 'Trick: $numbered nets +${netGainCp}cp over best in practice'
            '$noveltyTag';
    }
  }

  String get _missingMoveLocalProbLabel {
    if (source == MissingResponseSource.chessDb ||
        source == MissingResponseSource.engine) {
      final who = source == MissingResponseSource.engine
          ? 'Stockfish'
          : 'ChessDB';
      final gap = evalLossCp ?? 0;
      final gapLabel = gap == 0
          ? '$who: equal to their best'
          : '$who: ${gap}cp behind their best';
      final count = continuationCount;
      if (count == null) return gapLabel;
      return '$gapLabel · $count good move${count == 1 ? '' : 's'} here';
    }
    final p = probability ?? 0;
    final probStr = _formatProbability(p);
    if (source == MissingResponseSource.lichess) {
      return 'p=$probStr, ${gameCount ?? 0} games';
    }
    if (source == MissingResponseSource.clash) {
      final count = gameCount ?? 0;
      return count > 1 ? 'p=$probStr, $count lines' : 'p=$probStr book';
    }
    return 'p=$probStr Maia';
  }

  static String _formatProbability(double p) {
    if (p >= 0.1) return '${(p * 100).toStringAsFixed(0)}%';
    if (p >= 0.01) return '${(p * 100).toStringAsFixed(1)}%';
    if (p >= 0.001) return p.toStringAsFixed(3);
    if (p > 0) return p.toStringAsExponential(1);
    return '0';
  }

  // ── JSON serialization ──────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'severity': severity.name,
    'movePath': movePath,
    'fen': fen,
    if (ourMove != null) 'ourMove': ourMove,
    if (bestMove != null) 'bestMove': bestMove,
    if (evalLossCp != null) 'evalLossCp': evalLossCp,
    if (positionEvalCp != null) 'positionEvalCp': positionEvalCp,
    if (bestMoveEvalCp != null) 'bestMoveEvalCp': bestMoveEvalCp,
    if (missingMove != null) 'missingMove': missingMove,
    if (gameCount != null) 'gameCount': gameCount,
    if (probability != null) 'probability': probability,
    if (source != null) 'source': source!.name,
    if (continuationCount != null) 'continuationCount': continuationCount,
    if (uncoveredMoves != null && uncoveredMoves!.isNotEmpty)
      'uncoveredMoves': uncoveredMoves,
    if (cumulativeProbability != null)
      'cumulativeProbability': cumulativeProbability,
    if (transposesIntoRepertoire) 'transposesIntoRepertoire': true,
    if (exploitLine != null && exploitLine!.isNotEmpty)
      'exploitLine': exploitLine,
    if (expectedEvalCp != null) 'expectedEvalCp': expectedEvalCp,
    if (practicalGapCp != null) 'practicalGapCp': practicalGapCp,
    if (netGainCp != null) 'netGainCp': netGainCp,
    if (oppEase != null) 'oppEase': oppEase,
    if (isNovelty != null) 'isNovelty': isNovelty,
    if (exploitScore != null) 'exploitScore': exploitScore,
    if (dismissed) 'dismissed': true,
  };

  factory AuditFinding.fromJson(Map<String, dynamic> j) => AuditFinding(
    type: AuditFindingType.values.byName(j['type'] as String),
    severity: AuditSeverity.values.byName(j['severity'] as String),
    movePath: (j['movePath'] as List).cast<String>(),
    fen: j['fen'] as String,
    ourMove: j['ourMove'] as String?,
    bestMove: j['bestMove'] as String?,
    evalLossCp: j['evalLossCp'] as int?,
    positionEvalCp: j['positionEvalCp'] as int?,
    bestMoveEvalCp: j['bestMoveEvalCp'] as int?,
    missingMove: j['missingMove'] as String?,
    gameCount: j['gameCount'] as int?,
    probability: (j['probability'] as num?)?.toDouble(),
    source: j['source'] != null
        ? MissingResponseSource.values.byName(j['source'] as String)
        : null,
    continuationCount: j['continuationCount'] as int?,
    uncoveredMoves: (j['uncoveredMoves'] as List?)?.cast<String>(),
    cumulativeProbability: (j['cumulativeProbability'] as num?)?.toDouble(),
    transposesIntoRepertoire: j['transposesIntoRepertoire'] as bool? ?? false,
    exploitLine: (j['exploitLine'] as List?)?.cast<String>(),
    expectedEvalCp: j['expectedEvalCp'] as int?,
    practicalGapCp: j['practicalGapCp'] as int?,
    netGainCp: j['netGainCp'] as int?,
    oppEase: (j['oppEase'] as num?)?.toDouble(),
    isNovelty: j['isNovelty'] as bool?,
    exploitScore: (j['exploitScore'] as num?)?.toDouble(),
    dismissed: j['dismissed'] as bool? ?? false,
  );
}
