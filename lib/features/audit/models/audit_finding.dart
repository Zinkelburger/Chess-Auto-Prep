/// Data model for a single repertoire audit finding.
library;

enum AuditFindingType {
  mistake,
  inaccuracy,
  missingResponse,
  weakPosition,
  deadEnd,
}

enum AuditSeverity {
  critical,
  warning,
  info,
}

/// Source that detected a missing opponent response.
enum MissingResponseSource {
  lichess,
  maia,
}

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
  final double? probability;

  /// For MissingResponse: which source flagged the gap.
  final MissingResponseSource? source;

  /// For DeadEnd: how many opponent continuations exist beyond the leaf.
  final int? continuationCount;

  /// For DeadEnd: the specific opponent moves not covered (SAN).
  final List<String>? uncoveredMoves;

  /// Probability of reaching this position from the repertoire root (0..1).
  /// Product of opponent move frequencies along the path.
  final double? cumulativeProbability;

  /// True when the missing move transposes into a position already covered
  /// elsewhere in the repertoire (the resulting FEN exists in the tree).
  final bool transposesIntoRepertoire;

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
    this.dismissed = false,
  });

  /// Stable key for dismissal persistence.
  String get dismissKey => '${type.name}|$fen|${ourMove ?? missingMove ?? ""}';

  String get movePathString {
    if (movePath.isEmpty) return '(root)';
    final buf = StringBuffer();
    for (int i = 0; i < movePath.length; i++) {
      if (i % 2 == 0) {
        buf.write('${(i ~/ 2) + 1}.');
      }
      buf.write(movePath[i]);
      if (i < movePath.length - 1) buf.write(' ');
    }
    return buf.toString();
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
  String _sanWithMoveNumber(String san, int plyIndex) {
    final moveNum = (plyIndex ~/ 2) + 1;
    return plyIndex.isEven ? '$moveNum. $san' : '$moveNum...$san';
  }

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
        return 'Missing: $numbered ($probLabel$transTag)';
      case AuditFindingType.weakPosition:
        return 'Weak position: eval ${positionEvalCp}cp';
      case AuditFindingType.deadEnd:
        final count = continuationCount ?? 0;
        final moves = uncoveredMoves;
        if (moves != null && moves.isNotEmpty) {
          return 'Dead end: $count uncovered (${moves.join(", ")})';
        }
        return 'Dead end: $count opponent continuations uncovered';
    }
  }

  String get _missingMoveLocalProbLabel {
    final p = probability ?? 0;
    final probStr = _formatProbability(p);
    if (source == MissingResponseSource.lichess) {
      return 'p=$probStr, ${gameCount ?? 0} games';
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
        cumulativeProbability:
            (j['cumulativeProbability'] as num?)?.toDouble(),
        transposesIntoRepertoire:
            j['transposesIntoRepertoire'] as bool? ?? false,
        dismissed: j['dismissed'] as bool? ?? false,
      );
}
