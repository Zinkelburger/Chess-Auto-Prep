part of 'pgn_movetext_view.dart';

/// What one mainline move cost, read back out of the `[%eval]` series that a
/// game-analysis pass leaves on every ply.
///
/// A game the engine has been over carries a comment on *every* move, and
/// rendering each of them puts one move per row — a wall of `eval +0.31` that
/// buries the game it annotates. So the score itself is never shown inline.
/// What is shown is the handful of moves where the number is news: the ply
/// went from [before] to [after] and that swing crossed a mistake threshold.
class _EvalNote {
  const _EvalNote({
    required this.classification,
    required this.before,
    required this.after,
    required this.pv,
  });

  /// Inaccuracy, mistake or blunder — never [MoveClassification.normal], which
  /// is not worth a mark.
  final MoveClassification classification;

  /// The evaluation before and after the move, White-relative, formatted the
  /// way the graph and the analysis tab format it.
  final String before;
  final String after;

  /// The line the engine would have played instead, in SAN, from the position
  /// *before* this move. Empty when the pass stored no `[%pv]`.
  final List<String> pv;

  String get label => switch (classification) {
    MoveClassification.blunder => 'Blunder',
    MoveClassification.mistake => 'Mistake',
    MoveClassification.inaccuracy => 'Inaccuracy',
    MoveClassification.interesting => '',
    MoveClassification.normal => '',
  };
}

/// True when a comment is an engine measurement and nothing else — the shape a
/// game analysis pass writes: an `[%eval]`, optionally with the `[%pv]` and
/// `[%clk]` tokens that never render as prose anyway.
///
/// A generated repertoire's annotation always carries more than a score
/// (likelihood, expectimax, ease, game counts), so its per-move facts are not
/// caught by this and keep rendering as before.
bool _isEvalOnlyComment(String raw) =>
    MoveMetrics.parse(raw).isEvalOnly && stripPgnTokens(raw).trim().isEmpty;

/// Whether this game has been through an engine pass — nearly every ply
/// carrying an eval-only comment, the same "counts as analyzed" budget the
/// eval readers use.
///
/// The distinction matters: one `[%eval]` dropped on a single move by a human
/// annotator is a fact worth reading, and stays visible. Eighty of them are
/// noise, and get replaced by the mistake marks [_buildEvalNotes] derives.
bool _isMachineAnnotated(List<PgnNodeData> moveHistory) {
  if (moveHistory.length < 6) return false;
  var evalOnly = 0;
  for (final data in moveHistory) {
    for (final c in data.comments ?? const <String>[]) {
      if (_isEvalOnlyComment(c)) {
        evalOnly++;
        break;
      }
    }
  }
  return evalOnly >= moveHistory.length - kMaxUnevaluatedPlies;
}

/// The moves worth marking, by mainline index.
///
/// Deliberately the same arithmetic as `parseCachedEvals` — the winning-chance
/// curve, the delta, the thresholds — so the movetext and the analysis tab
/// never disagree about which move was the blunder.
Map<int, _EvalNote> _buildEvalNotes(PgnMovetextView view) {
  final history = view.moveHistory;
  final notes = <int, _EvalNote>{};

  var prevWinChance = initialWinChance();
  var prevText = formatEvalDisplay(scoreCp: 0);

  for (var i = 0; i < history.length; i++) {
    final data = history[i];
    if (isNullMoveSan(data.san)) continue;

    ({int? cp, int? mate, int? depth})? eval;
    var pv = const <String>[];
    for (final c in data.comments ?? const <String>[]) {
      eval ??= parseEvalComment(c);
      if (pv.isEmpty) pv = parsePvComment(c);
    }

    // Mate on the board is a fact of the position, not a score: a stored
    // mate-0 has no sign, so trusting it would read the mating move as a
    // catastrophe for the player who delivered it.
    final isWhiteMove = view.startingWhiteTurn ? i.isEven : i.isOdd;
    if (data.san.endsWith('#')) {
      prevWinChance = isWhiteMove ? 1.0 : -1.0;
      prevText = '#';
      continue;
    }
    // An unscored ply leaves the chain where it was, so the next scored move
    // is measured against the last number anyone actually has.
    if (eval == null) continue;

    final winChance = cpToWinningChance(eval.cp, eval.mate);
    final delta = isWhiteMove
        ? prevWinChance - winChance
        : winChance - prevWinChance;
    final classification = classifyMove(delta.clamp(0.0, 1.0));
    final text = formatEvalDisplay(scoreCp: eval.cp, scoreMate: eval.mate);

    if (classification != MoveClassification.normal &&
        classification != MoveClassification.interesting) {
      notes[i] = _EvalNote(
        classification: classification,
        before: prevText,
        after: text,
        pv: pv,
      );
    }

    prevWinChance = winChance;
    prevText = text;
  }
  return notes;
}

/// The inline mark on a move that cost something: `Blunder +0.3 → +2.1`, in
/// the quiet metrics ink, riding beside the move instead of breaking the line.
List<InlineSpan> _evalNoteSpans(_EvalNote note) => [
  TextSpan(
    text: '${note.label} ${note.before} → ${note.after}  ',
    style: PgnTextStyles.metricsAt(0),
  ),
];

/// The engine's line from before the marked move, as clickable moves that
/// preview on the board without touching the move tree — the same machinery
/// prose-embedded lines use, so clicking one behaves identically.
List<InlineSpan> _bestLineSpans(
  PgnMovetextView view,
  List<String> pv,
  int anchorPly,
) {
  if (pv.isEmpty) return const [];
  // Negative ids: parsed comment runs number themselves from zero, and these
  // synthesized runs must not collide with them.
  final runId = -(anchorPly + 1);
  final run = <CommentMove>[];
  for (var k = 0; k < pv.length; k++) {
    final coords = _coordsAtPly(view, anchorPly + k);
    final prefix = coords.isWhite
        ? '${coords.moveNumber}.'
        : (k == 0 ? '${coords.moveNumber}...' : '');
    run.add(
      CommentMove(
        san: pv[k],
        display: '$prefix${pv[k]}',
        moveNumber: coords.moveNumber,
        isWhite: coords.isWhite,
        runId: runId,
      ),
    );
  }
  return [
    TextSpan(text: 'Best: ', style: PgnTextStyles.metricsAt(0)),
    for (final move in run) _buildCommentMoveSpan(view, move, run),
  ];
}
