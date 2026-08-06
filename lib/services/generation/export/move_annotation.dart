/// What the exporter knows about a single move of a generated line.
///
/// The build pipeline computes far more per node than a repertoire PGN
/// historically carried — ease, naturalness, practical scores, how recently a
/// move was seen in real games.  This is the carrier that gets it out of the
/// tree and into the file, so a strong player reading the export can see *why*
/// a move is recommended rather than just that it was.
///
/// Every field is optional: a Maia-only build has no game statistics, an
/// unevaluated coverage leaf has no eval, and the renderer simply omits what
/// is absent instead of inventing a neutral value.
library;

/// Where a move-likelihood number came from.
enum MoveLikelihoodSource {
  /// Maia's predicted human policy.
  maia,

  /// Observed frequency in the user's game database.
  gameDatabase,

  /// Injected from the engine's principal variation because no human source
  /// offered the move.
  engine;

  /// PGN token used for this source's likelihood value.
  String get pgnTag => switch (this) {
    MoveLikelihoodSource.maia => 'maiaProbability',
    MoveLikelihoodSource.gameDatabase => 'humanFrequency',
    MoveLikelihoodSource.engine => 'engineReply',
  };
}

/// How much per-move detail an export carries.
enum MoveAnnotationDetail {
  /// Bare movetext.
  none,

  /// Opponent move likelihood only — the historical default.
  likelihood,

  /// Everything available: eval, ease, practical score, recency.
  full;

  bool get emitsAnything => this != MoveAnnotationDetail.none;
  bool get emitsMetrics => this == MoveAnnotationDetail.full;

  static MoveAnnotationDetail parse(String? name) =>
      MoveAnnotationDetail.values.firstWhere(
        (d) => d.name == name,
        orElse: () => MoveAnnotationDetail.likelihood,
      );

  /// Restore the setting from the two booleans that preceded this enum, so
  /// presets and paused builds saved before the change still load.
  static MoveAnnotationDetail fromLegacyFlags({required bool annotate}) =>
      annotate ? MoveAnnotationDetail.likelihood : MoveAnnotationDetail.none;
}

class MoveAnnotation {
  /// Probability the side to move plays this move, in [0, 1].  Only
  /// meaningful for opponent moves — we choose ours.
  final double? likelihood;

  final MoveLikelihoodSource? likelihoodSource;

  /// Games behind [likelihood] when it came from a database.
  final int? gameCount;

  /// Score our side achieved from here in real games, in [0, 1].  Null when
  /// no game at this move had a recorded result.
  final double? practicalScore;

  /// Engine evaluation after the move, in centipawns from *our* perspective.
  final int? evalCp;

  /// How easily the side to move finds a good move here, in [0, 1].  Low is
  /// good for us: the opponent is likely to go wrong.
  final double? opponentEase;

  /// How natural our move is for a human to find, in [0, 1].
  final double? myEase;

  /// Our move is far enough ahead of every alternative to be effectively
  /// forced — the moves worth extra memorisation effort.
  final bool isOnlyMove;

  /// Most recent year this move appears in the database.
  final int? lastPlayedYear;

  const MoveAnnotation({
    this.likelihood,
    this.likelihoodSource,
    this.gameCount,
    this.practicalScore,
    this.evalCp,
    this.opponentEase,
    this.myEase,
    this.isOnlyMove = false,
    this.lastPlayedYear,
  });

  static const none = MoveAnnotation();

  bool get isEmpty =>
      likelihood == null &&
      practicalScore == null &&
      evalCp == null &&
      opponentEase == null &&
      myEase == null &&
      lastPlayedYear == null &&
      !isOnlyMove;

  /// Render as a PGN comment body (without the surrounding braces), or null
  /// when nothing at this detail level applies.
  ///
  /// Tokens follow the `[%name value]` convention the rest of the app already
  /// parses and strips, so an annotated export stays readable in any viewer.
  String? toPgnComment(MoveAnnotationDetail detail) {
    if (!detail.emitsAnything || isEmpty) return null;

    final tokens = <String>[];
    if (likelihood != null && likelihoodSource != null) {
      tokens.add(
        '[%${likelihoodSource!.pgnTag} ${likelihood!.toStringAsFixed(3)}]',
      );
    }

    if (detail.emitsMetrics) {
      if (evalCp != null) tokens.add('[%eval ${_formatPawns(evalCp!)}]');
      if (isOnlyMove) tokens.add('[%onlyMove]');
      if (myEase != null) {
        tokens.add('[%myEase ${myEase!.toStringAsFixed(2)}]');
      }
      if (opponentEase != null) {
        tokens.add('[%ease ${opponentEase!.toStringAsFixed(2)}]');
      }
      if (practicalScore != null) {
        tokens.add('[%score ${(practicalScore! * 100).toStringAsFixed(1)}%]');
      }
      if (gameCount != null && gameCount! > 0) {
        tokens.add('[%games $gameCount]');
      }
      if (lastPlayedYear != null && lastPlayedYear! > 0) {
        tokens.add('[%lastPlayed $lastPlayedYear]');
      }
    }

    return tokens.isEmpty ? null : tokens.join(' ');
  }
}

/// `+0.31` / `-1.05` / `0.00` — pawns, always signed except at zero.
String _formatPawns(int centipawns) {
  final pawns = (centipawns / 100).toStringAsFixed(2);
  return centipawns > 0 ? '+$pawns' : pawns;
}
