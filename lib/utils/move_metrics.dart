/// The reader for a generated repertoire's per-move `[%…]` tokens.
///
/// The writer is `generation/export/move_annotation.dart`; the two are halves
/// of one wire format, so every token the writer can emit is read here.
library;

import '../services/generation/export/move_annotation.dart'
    show MoveLikelihoodSource;
import 'pgn_comment_utils.dart' show parseEvalComment;

/// `[%name value]` — the shape every generated annotation token takes.
final _metricTokenRe = RegExp(r'\[%(\w+)\s*([^\]]*)\]');

/// What a generated repertoire says about one move, read back out of its
/// `[%...]` tokens.
///
/// Every viewer in the app strips those tokens as engine noise, which left an
/// annotated export looking like bare movetext.  [labels] turns whatever is
/// present into plain English for display — nothing invented, nothing implied
/// by a missing token.
class MoveMetrics {
  /// Engine eval after the move, in centipawns from the mover's own book
  /// perspective (the generator writes it from the repertoire owner's side).
  final int? evalCp;

  /// Mate distance, when the eval is a mate score instead of centipawns.
  final int? evalMate;

  /// Expectimax (practical) value after the move, in centipawns from the
  /// repertoire owner's side — the engine eval folded with how often
  /// opponents go wrong from here.  Written by the generator as
  /// `[%expectimax +0.45]`.
  final int? expectimaxCp;

  /// The move is far enough ahead of every alternative to be forced.
  final bool isOnlyMove;

  /// How naturally a human finds *our* move here, in [0, 1].
  final double? myEase;

  /// How easily the opponent finds a good move here, in [0, 1].
  final double? opponentEase;

  /// Score our side achieved from here in real games, in [0, 1].
  final double? practicalScore;

  final int? gameCount;
  final int? lastPlayedYear;

  /// Probability the opponent plays this move, in [0, 1], and where the
  /// number came from.
  final double? likelihood;
  final MoveLikelihoodSource? likelihoodSource;

  /// What a refuted alternative costs the side that plays it, in centipawns.
  final int? lossCp;

  const MoveMetrics({
    this.evalCp,
    this.evalMate,
    this.expectimaxCp,
    this.isOnlyMove = false,
    this.myEase,
    this.opponentEase,
    this.practicalScore,
    this.gameCount,
    this.lastPlayedYear,
    this.likelihood,
    this.likelihoodSource,
    this.lossCp,
  });

  static const none = MoveMetrics();

  bool get isEmpty => labels.isEmpty;

  /// Parse every recognised token in [comment]; unknown tokens and prose are
  /// ignored, so this is safe to run over any comment from any source.
  static MoveMetrics parse(String comment) {
    if (!comment.contains('[%')) return none;

    int? evalCp;
    int? evalMate;
    int? expectimaxCp;
    var isOnlyMove = false;
    double? myEase;
    double? opponentEase;
    double? practicalScore;
    int? gameCount;
    int? lastPlayedYear;
    double? likelihood;
    MoveLikelihoodSource? likelihoodSource;
    int? lossCp;

    void readLikelihood(String raw, MoveLikelihoodSource source) {
      likelihood = double.tryParse(raw);
      likelihoodSource = source;
    }

    for (final match in _metricTokenRe.allMatches(comment)) {
      final name = match.group(1)!;
      final raw = match.group(2)!.trim();
      switch (name) {
        case 'eval':
          final parsed = parseEvalComment('[%eval $raw]');
          evalCp = parsed?.cp;
          evalMate = parsed?.mate;
        case 'expectimax':
          expectimaxCp = _pawnsToCp(raw);
        case 'onlyMove':
          isOnlyMove = true;
        case 'myEase':
          myEase = double.tryParse(raw);
        case 'ease':
          opponentEase = double.tryParse(raw);
        case 'score':
          final percent = double.tryParse(raw.replaceAll('%', ''));
          if (percent != null) practicalScore = percent / 100.0;
        case 'games':
          gameCount = int.tryParse(raw);
        case 'lastPlayed':
          lastPlayedYear = int.tryParse(raw);
        case 'maiaProbability':
          readLikelihood(raw, MoveLikelihoodSource.maia);
        case 'humanFrequency':
          readLikelihood(raw, MoveLikelihoodSource.gameDatabase);
        case 'engineReply':
          readLikelihood(raw, MoveLikelihoodSource.engine);
        case 'chessDbMove':
          readLikelihood(raw, MoveLikelihoodSource.positionDatabase);
        case 'loss':
          lossCp = _pawnsToCp(raw);
      }
    }

    return MoveMetrics(
      evalCp: evalCp,
      evalMate: evalMate,
      expectimaxCp: expectimaxCp,
      isOnlyMove: isOnlyMove,
      myEase: myEase,
      opponentEase: opponentEase,
      practicalScore: practicalScore,
      gameCount: gameCount,
      lastPlayedYear: lastPlayedYear,
      likelihood: likelihood,
      likelihoodSource: likelihoodSource,
      lossCp: lossCp,
    );
  }

  /// One short phrase per fact present, in reading order: what the engine
  /// thinks, how likely the move is, how it has actually gone for humans.
  List<String> get labels {
    final evalMate = this.evalMate;
    final evalCp = this.evalCp;
    final expectimaxCp = this.expectimaxCp;
    final lossCp = this.lossCp;
    final likelihood = this.likelihood;
    final likelihoodSource = this.likelihoodSource;
    final gameCount = this.gameCount;
    final practicalScore = this.practicalScore;
    final myEase = this.myEase;
    final opponentEase = this.opponentEase;
    final lastPlayedYear = this.lastPlayedYear;
    return [
      if (evalMate != null) 'mate in ${evalMate.abs()}',
      if (evalMate == null && evalCp != null) 'eval ${_signedPawns(evalCp)}',
      if (expectimaxCp != null) 'expectimax ${_signedPawns(expectimaxCp)}',
      if (lossCp != null) 'costs ${(lossCp / 100).toStringAsFixed(2)}',
      if (isOnlyMove) 'only move',
      if (likelihood != null && likelihoodSource != null)
        switch (likelihoodSource) {
          MoveLikelihoodSource.maia => '${_percent(likelihood)} likely',
          MoveLikelihoodSource.gameDatabase => 'played ${_percent(likelihood)}',
          MoveLikelihoodSource.engine => 'engine reply',
          // No percentage: this is the database's choice of move, not a claim
          // about how often anyone plays it.
          MoveLikelihoodSource.positionDatabase => 'ChessDB move',
        },
      if (gameCount != null && gameCount > 0) '$gameCount games',
      if (practicalScore != null) 'you score ${_percent(practicalScore)}',
      if (myEase != null) 'natural for you ${_percent(myEase)}',
      if (opponentEase != null) 'easy for them ${_percent(opponentEase)}',
      if (lastPlayedYear != null && lastPlayedYear > 0)
        'last played $lastPlayedYear',
    ];
  }

  /// The whole thing on one line, or empty when the comment held no metrics.
  String get summary => labels.join(' · ');

  /// True when an engine score is the *only* thing here.
  ///
  /// This is what separates a game-analysis annotation, which a pass writes on
  /// every ply and which the viewer therefore hides, from a generated
  /// repertoire's per-move facts, which always carry more than a score
  /// (likelihood, expectimax, ease, game counts) and stay on the page.
  bool get isEvalOnly =>
      labels.length == 1 && (evalCp != null || evalMate != null);

  /// `+0.45` → 45; null when [raw] is not a number.
  static int? _pawnsToCp(String raw) {
    final pawns = double.tryParse(raw);
    return pawns == null ? null : (pawns * 100).round();
  }

  static String _percent(double fraction) => '${(fraction * 100).round()}%';

  static String _signedPawns(int centipawns) {
    final pawns = (centipawns / 100).toStringAsFixed(2);
    return centipawns > 0 ? '+$pawns' : pawns;
  }
}
